module XMonad.Wayland.Policy
  ( Policy(..), WindowSet, initialPolicy, handleEvent, renderPolicy, focusedWindow
  ) where

import qualified Data.Map.Strict as Map
import Data.List (partition)
import Data.Maybe (mapMaybe)
import Data.Int (Int32)
import qualified XMonad.StackSet as S
import XMonad.Wayland.Types

type WindowSet = S.StackSet WorkspaceId LayoutState WindowId (Maybe OutputId) Rect
data Policy = Policy
  { windowSet :: !WindowSet
  , outputs :: !(Map.Map OutputId Rect)
  , sessionLocked :: !Bool
  } deriving (Eq, Show)

initialPolicy :: Config -> Policy
initialPolicy cfg = Policy
  (S.StackSet (S.Screen (ws 1) Nothing (Rect 0 0 1 1)) [] (map ws [2..9]) Map.empty)
  Map.empty False
  where ws i = S.Workspace i (LayoutState (initialLayout cfg) (clampRatio (initialMasterRatio cfg))) Nothing

handleEvent :: Config -> Event -> Policy -> (Policy, [Effect])
handleEvent cfg ev p = case ev of
  OutputUpsert oid rect -> done (reconcile (Map.insert oid (positive rect) (outputs p)) p)
  OutputRemoved oid -> done (reconcile (Map.delete oid (outputs p)) p)
  WindowAdded wid
    | wid == 0 || S.member wid ws -> done p
    | otherwise -> change (S.insertUp wid)
  WindowRemoved wid -> change (S.delete wid)
  FocusRequested wid
    | not (sessionLocked p) && wid `elem` visibleWindows p -> change (S.focusWindow wid)
    | otherwise -> done p
  Locked -> done p { sessionLocked = True }
  Unlocked -> done p { sessionLocked = False }
  ActionRequested action
    | sessionLocked p -> done p
    | otherwise -> case action of
        FocusNext -> change S.focusDown
        FocusPrevious -> change S.focusUp
        SwapMaster -> change S.swapMaster
        SwapNext -> change S.swapDown
        SwapPrevious -> change S.swapUp
        View tag -> change (S.view tag)
        Shift tag -> change (S.shift tag)
        NextLayout -> changeLayout $ \l -> l { layoutKind = case layoutKind l of
          Tall -> Mirror
          Mirror -> Full
          Full -> Tall }
        Shrink -> resize negate
        Expand -> resize id
        Close -> (p, maybe [] (pure . CloseWindow) (focusedWindow p))
        Terminal -> (p, [Spawn (terminalCommand cfg)])
        Launcher -> (p, [Spawn (launcherCommand cfg)])
        Stop -> (p, [StopRuntime])
  where
    ws = windowSet p
    done p' = (p', [])
    change f = done p { windowSet = f ws }
    changeLayout f = change (S.mapWorkspace (\w ->
      if S.tag w == S.currentTag ws then w { S.layout = f (S.layout w) } else w))
    resize direction = changeLayout $ \l -> l
      { masterRatio = clampRatio (masterRatio l + direction (max 0 (resizeIncrement cfg))) }

-- | Keep workspace stacks intact while outputs come and go. A virtual screen
-- preserves StackSet's nonempty-current invariant when the last output leaves.
-- At most nine outputs receive workspaces; extra outputs remain unassigned until
-- a workspace becomes available. They stay in the output map for later hotplug.
reconcile :: Map.Map OutputId Rect -> Policy -> Policy
reconcile newOutputs p = p { outputs = newOutputs, windowSet = rebuilt }
  where
    old = windowSet p
    oldScreens = S.screens old
    oldCurrent = S.current old
    alive s = maybe False (`Map.member` newOutputs) (S.screen s)
    (retained, removed) = partition alive oldScreens
    refresh s = case S.screen s >>= (`Map.lookup` newOutputs) of
      Just r -> s { S.screenDetail = r }
      Nothing -> s
    assemble cur vis unseen = S.StackSet cur vis unseen (S.floating old)
    rebuilt
      | Map.null newOutputs = assemble
          (S.Screen (S.workspace oldCurrent) Nothing (Rect 0 0 1 1)) []
          (map S.workspace (S.visible old) ++ S.hidden old)
      | otherwise = case retained of
          [] -> case Map.toAscList newOutputs of
            (oid,rect):rest ->
              let pool = map S.workspace (S.visible old) ++ S.hidden old
                  added = zipWith (\(i,r) w -> S.Screen w (Just i) r) rest pool
              in assemble (S.Screen (S.workspace oldCurrent) (Just oid) rect)
                   added (drop (length added) pool)
            [] -> old -- covered by the Map.null guard
          cur:vis ->
            let assigned = mapMaybe S.screen retained
                available = filter ((`notElem` assigned) . fst) (Map.toAscList newOutputs)
                pool = S.hidden old ++ map S.workspace removed
                added = zipWith (\(i,r) w -> S.Screen w (Just i) r) available pool
            in assemble (refresh cur) (map refresh vis ++ added) (drop (length added) pool)

positive :: Rect -> Rect
positive (Rect x y w h) = Rect (fromInteger x') (fromInteger y') (extent x' w) (extent y' h)
  where
    minimumCoordinate = toInteger (minBound :: Int32)
    maximumCoordinate = toInteger (maxBound :: Int32)
    coordinate = max minimumCoordinate . min maximumCoordinate . toInteger
    x' = coordinate x
    y' = coordinate y
    -- Rectangles may end one pixel beyond maxBound, but their last pixel and
    -- every emitted origin must remain representable by the signed C ABI.
    extent origin size = fromInteger (max 1 (minimum
      [toInteger size, maximumCoordinate, maximumCoordinate - origin + 1]))

clampRatio :: Rational -> Rational
clampRatio = max (1 / 10) . min (9 / 10)

visibleWindows :: Policy -> [WindowId]
visibleWindows = map placementWindow . filter placementVisible . renderPolicy

renderPolicy :: Policy -> [Placement]
renderPolicy p = map placement (S.allWindows (windowSet p))
  where
    rectangles = Map.fromList $ concatMap screenRects (S.screens (windowSet p))
    screenRects s = case (S.screen s >>= (`Map.lookup` outputs p), S.stack (S.workspace s)) of
      (Just rect, Just stack) -> layoutRects (S.layout (S.workspace s)) rect stack
      _ -> []
    focused = focusedWindow p
    placement wid = case Map.lookup wid rectangles of
      Just rect -> Placement wid rect True (Just wid == focused)
      Nothing -> Placement wid (Rect 0 0 1 1) False False

focusedWindow :: Policy -> Maybe WindowId
focusedWindow p
  | sessionLocked p || Map.null (outputs p) = Nothing
  | otherwise = S.peek (windowSet p)

layoutRects :: LayoutState -> Rect -> S.Stack WindowId -> [(WindowId, Rect)]
layoutRects l rect stack = case layoutKind l of
  Full -> [(S.focus stack, rect)]
  Tall -> tall (masterRatio l) rect (S.integrate stack)
  Mirror -> map (\(w,r) -> (w, transpose r))
    (tall (masterRatio l) (transpose rect) (S.integrate stack))
  where transpose (Rect x y w h) = Rect y x h w

tall :: Rational -> Rect -> [WindowId] -> [(WindowId, Rect)]
tall _ _ [] = []
tall _ rect [wid] = [(wid, rect)]
tall ratio (Rect x y w h) (master:rest) =
  (master, Rect x y cut h) : zipWith slave [0..] rest
  where
    cut = if w <= 1 then 1 else max 1 (min (w - 1) (floor (fromIntegral w * ratio)))
    slaveX = if w <= 1 then x else x + cut
    slaveWidth = if w <= 1 then 1 else w - cut
    count = length rest
    -- More windows than pixels necessarily overlap. Reuse boundary pixels
    -- instead of emitting zero dimensions or escaping the output rectangle.
    slave :: Int -> WindowId -> (WindowId, Rect)
    slave i wid =
      let boundary n = fromInteger (toInteger n * toInteger h `div` toInteger count)
          start = min (h - 1) (boundary i)
          end = min h (max (start + 1) (boundary (i + 1)))
      in (wid, Rect slaveX (y + start) slaveWidth (end - start))
