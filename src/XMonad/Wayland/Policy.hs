module XMonad.Wayland.Policy
  ( Policy(..), WindowSet, WindowMetadata(..), PointerOperation(..), initialPolicy, handleEvent, renderPolicy, renderPointerPositions, focusedWindow, focusedOutput
  ) where

import qualified Data.Map.Strict as Map
import Data.List (partition, sortOn, elemIndex, nub)
import Data.Maybe (mapMaybe, listToMaybe)
import Data.Int (Int32)
import Data.Word (Word32)
import Data.Bits ((.&.), (.|.))
import qualified XMonad.StackSet as S
import XMonad.Wayland.Types

type WindowSet = S.StackSet WorkspaceId LayoutState WindowId (Maybe OutputId) Rect
data WindowMetadata = WindowMetadata
  { windowParent :: !(Maybe WindowId)
  , windowHints :: !(Int, Int, Int, Int)
  , windowFloating :: !Bool
  , windowFullscreen :: !Bool
  , windowFloatRect :: !(Maybe Rect)
  , windowWidthWeight :: !Rational
  , windowHeightWeight :: !Rational
  , windowAppId :: !(Maybe String)
  , windowTitle :: !(Maybe String)
  } deriving (Eq, Show)

defaultMetadata :: WindowMetadata
defaultMetadata = WindowMetadata Nothing (0, 0, 0, 0) False False Nothing 1 1 Nothing Nothing

-- Geometry is captured once: River reports cumulative logical displacement.
data PointerOperation = PointerOperation
  { pointerSeat :: !SeatId
  , pointerWindow :: !WindowId
  , pointerEdges :: !Word32
  , pointerInitialRect :: !Rect
  , pointerOutput :: !OutputId
  , pointerOutputRect :: !Rect
  , pointerArea :: !Rect
  , pointerWorkspace :: !WorkspaceId
  , pointerHints :: !(Int, Int, Int, Int)
  } deriving (Eq, Show)

-- Keep this after release: a client may acknowledge a quantized size later.
data PointerAnchor = PointerAnchor
  { anchorEdges :: !Word32
  , anchorInitialRect :: !Rect
  , anchorOutput :: !OutputId
  , anchorOutputRect :: !Rect
  , anchorArea :: !Rect
  , anchorWorkspace :: !WorkspaceId
  } deriving (Eq, Show)

data Policy = Policy
  { windowSet :: !WindowSet
  , outputs :: !(Map.Map OutputId Rect)
  , workAreas :: !(Map.Map OutputId Rect)
  , sessionLocked :: !Bool
  , windowMetadata :: !(Map.Map WindowId WindowMetadata)
  , activeMode :: !BindingMode
  , pointerOperation :: !(Maybe PointerOperation)
  , pointerActualSizes :: !(Map.Map WindowId (Int, Int))
  , pointerAnchors :: !(Map.Map WindowId PointerAnchor)
  } deriving (Eq, Show)

initialPolicy :: Config -> Policy
initialPolicy cfg = Policy
  (S.StackSet (S.Screen (ws first) Nothing (Rect 0 0 1 1)) [] (map ws rest) Map.empty)
  Map.empty Map.empty False Map.empty NormalMode Nothing Map.empty Map.empty
  where
    (first, rest) = case nub (workspaceIds cfg) of [] -> (1, []); x:xs -> (x, xs)
    ws i = S.Workspace i (LayoutState (initialLayout cfg) (clampRatio (initialMasterRatio cfg))) Nothing

handleEvent :: Config -> Event -> Policy -> (Policy, [Effect])
handleEvent cfg ev original =
  let prepared = preparePointerEvent ev original
      (next, effects) = handleOrdinaryEvent cfg ev prepared
      -- Visibility/topology changes can invalidate an anchor. Preserve the
      -- last displayed float rectangle before dropping that bookkeeping.
      settled = foldr (preserveInvalidAnchor prepared) next (Map.keys (pointerAnchors prepared))
  in (validatePointerState settled, effects)

handleOrdinaryEvent :: Config -> Event -> Policy -> (Policy, [Effect])
handleOrdinaryEvent cfg ev p = case ev of
  PointerStarted sid wid edges x y
    | activeMode p == PickerMode -> cancelPicker p
    | otherwise -> done (startPointer sid wid edges x y p)
  PointerMoved sid dx dy -> done (movePointer sid dx dy p)
  PointerReleased sid -> done (endPointer sid p)
  PointerCancelled sid -> done (endPointer sid p)
  WindowActualSize wid width height
    | S.member wid ws && width > 0 && height > 0 -> done p
        { pointerActualSizes = Map.insert wid (abiExtent width, abiExtent height) (pointerActualSizes p) }
    | otherwise -> done p
  OutputUpsert oid rect -> done (reconcile (Map.insert oid (positive rect) (outputs p)) p)
  OutputRemoved oid -> done (reconcile (Map.delete oid (outputs p))
    p { workAreas = Map.delete oid (workAreas p) })
  OutputWorkArea oid rect -> done p { workAreas = Map.insert oid rect (workAreas p) }
  WindowAdded wid
    | wid == 0 || S.member wid ws -> done p
    | otherwise -> done p { windowSet = S.insertUp wid ws
        , windowMetadata = Map.insert wid defaultMetadata (windowMetadata p) }
  WindowRemoved wid -> done p { windowSet = S.delete wid ws
    , pointerActualSizes = Map.delete wid (pointerActualSizes p)
    , windowMetadata = Map.map (\m -> if windowParent m == Just wid
        then m { windowParent = Nothing } else m) (Map.delete wid (windowMetadata p)) }
  WindowParent wid parent
    | not (S.member wid ws) || maybe False (\i -> i == wid || i `elem` descendants p wid) parent -> done p
    | otherwise ->
        let liveParent = parent >>= \i -> if S.member i ws then Just i else Nothing
            next = alterMetadata wid (\m -> m { windowParent = liveParent
              , windowFloating = maybe False (const True) liveParent }) p
            moved = case liveParent >>= (`S.findTag` ws) of
              Just tag -> shiftFamily wid tag next
              Nothing -> next
        in done moved
  WindowSizeHints wid minW minH maxW maxH ->
    let hints = (max 0 minW, max 0 minH, max 0 maxW, max 0 maxH)
    in done (alterMetadata wid (\m -> m { windowHints = hints
      -- Some dialogs have no mapped parent. Float a newly fixed-size window,
      -- but do not undo a user's tiling override on repeated hint events.
      , windowFloating = windowFloating m || (fixedSize hints && not (fixedSize (windowHints m))) }) p)
  WindowFullscreen wid enabled ->
    let next = alterMetadata wid (\m -> m { windowFullscreen = enabled }) p
    in done (if enabled && not (sessionLocked p) && wid `elem` visibleWindows p
      then next { windowSet = S.focusWindow wid ws } else next)
  WindowAppId wid text
    | Map.member wid (windowMetadata p) ->
        done (alterMetadata wid (\m -> m { windowAppId = Just (sanitizeMeta text) }) p)
    | otherwise -> done p
  WindowTitle wid text
    | Map.member wid (windowMetadata p) ->
        done (alterMetadata wid (\m -> m { windowTitle = Just (sanitizeMeta text) }) p)
    | otherwise -> done p
  FocusRequested wid
    | not (sessionLocked p) && wid `elem` visibleWindows p -> change (S.focusWindow wid)
    | otherwise -> done p
  Locked -> (p { sessionLocked = True, activeMode = NormalMode }, [HidePicker])
  Unlocked -> done p { sessionLocked = False }
  ActionRequested action
    | sessionLocked p -> done p
    | otherwise -> case action of
        Pick -> startPicker p
        PickCandidate index -> finishPicker index p
        PickCancel -> cancelPicker p
        _ | activeMode p == PickerMode -> done p
        FocusNext -> change S.focusDown
        FocusPrevious -> change S.focusUp
        SwapMaster -> change S.swapMaster
        SwapNext -> change S.swapDown
        SwapPrevious -> change S.swapUp
        View tag -> change (S.view tag)
        Shift tag -> done (maybe p (\wid -> shiftFamily wid tag p) (S.peek ws))
        FocusNextOutput -> change (focusOutput 1)
        FocusPreviousOutput -> change (focusOutput (-1))
        ToggleFloat -> modifyFocused (\m -> m { windowFloating = not (windowFloating m) })
        Sink -> modifyFocused (\m -> m { windowFloating = False })
        FocusModeToggle -> done (focusOtherMode p)
        FocusDirection direction -> done (focusDirection direction p)
        MoveDirection direction -> done (moveDirection direction p)
        Resize axis amount -> done (resizeWindow axis amount p)
        SetLayout kind -> changeLayout (\l -> l { layoutKind = kind })
        ToggleSplit -> changeLayout (\l -> l { layoutKind = if layoutKind l == Columns then Rows else Columns })
        CycleSwayLayout -> changeLayout (\l -> l { layoutKind = case layoutKind l of
          Tabbed -> Stacking
          Stacking -> Columns
          _ -> Tabbed })
        EnterMode mode -> done p { activeMode = mode }
        RunCommand command -> (p, [Spawn command])
        Reload -> (p, [ReloadConfig])
        ConfirmExit command -> (p, [ConfirmSessionExit command])
        ToggleFullscreen -> modifyFocused (\m -> m { windowFullscreen = not (windowFullscreen m) })
        NextLayout -> changeLayout $ \l ->
          let choices = layoutCycle cfg
              remaining = dropWhile (/= layoutKind l) (choices ++ choices)
          in l { layoutKind = case remaining of
                 (_:kind:_) -> kind
                 _ -> layoutKind l }
        Shrink -> resize negate
        Expand -> resize id
        Close -> (p, maybe [] (pure . CloseWindow) (focusedWindow p))
        Terminal -> (p, [Spawn (terminalCommand cfg)])
        Launcher -> (p, [Spawn (launcherCommand cfg)])
        Stop -> (p, [StopRuntime])
        Restart -> (p, [RestartRuntime])
        SwapToWindow wid -> change (swapToWindow wid)
  where
    ws = windowSet p
    done p' = (p', [])
    change f = done p { windowSet = f ws }
    modifyFocused f = done (maybe p (\wid -> alterMetadata wid f p) (S.peek ws))
    focusOutput direction stackSet = case elemIndex (S.screen (S.current stackSet)) screenIds of
      Just index | not (null screens) -> S.view
        (S.tag (S.workspace (screens !! ((index + direction) `mod` length screens)))) stackSet
      _ -> stackSet
      where
        screens = sortOn S.screen (filter ((/= Nothing) . S.screen) (S.screens stackSet))
        screenIds = map S.screen screens
    changeLayout f = change (S.mapWorkspace (\w ->
      if S.tag w == S.currentTag ws then w { S.layout = f (S.layout w) } else w))
    resize direction = changeLayout $ \l -> l
      { masterRatio = clampRatio (masterRatio l + direction (max 0 (resizeIncrement cfg))) }

abiExtent :: Int -> Int
abiExtent = fromInteger . max 1 . min (toInteger (maxBound :: Int32)) . toInteger

abiCoordinate :: Integer -> Int
abiCoordinate = fromInteger . max (toInteger (minBound :: Int32)) . min (toInteger (maxBound :: Int32))

windowPlacement :: WindowId -> Policy -> Maybe Placement
windowPlacement wid = listToMaybe . filter
  (\q -> placementWindow q == wid && placementVisible q) . renderPolicy

areaFor :: OutputId -> Policy -> Maybe Rect
areaFor oid p = do
  output <- Map.lookup oid (outputs p)
  pure (maybe output (clipArea output) (Map.lookup oid (workAreas p)))

-- Unlike a proposal, this rectangle describes what was actually rendered.
displayedRect :: WindowId -> Policy -> Maybe Rect
displayedRect wid p = do
  placement <- windowPlacement wid p
  let proposed = placementRect placement
      (width,height) = Map.findWithDefault (rectWidth proposed,rectHeight proposed) wid (pointerActualSizes p)
      sized = proposed { rectWidth = width, rectHeight = height }
  pure $ case Map.lookup wid (pointerAnchors p) of
    Nothing -> sized
    Just anchor -> anchoredRect anchor sized

anchoredRect :: PointerAnchor -> Rect -> Rect
anchoredRect anchor actual = actual { rectX = position True, rectY = position False }
  where
    initial = anchorInitialRect anchor
    area = anchorArea anchor
    position horizontal = abiCoordinate (max lower (min upper desired))
      where
        origin = if horizontal then rectX else rectY
        extent = if horizontal then rectWidth else rectHeight
        lower = toInteger (origin area)
        upper = max lower (lower + toInteger (extent area) - toInteger (extent actual))
        leadingEdge = if horizontal then 4 else 1
        desired | anchorEdges anchor .&. leadingEdge /= 0 =
                    toInteger (origin initial) + toInteger (extent initial) - toInteger (extent actual)
                | otherwise = toInteger (origin actual)

-- Runtime applies these only in render, after the actual-size callbacks.
renderPointerPositions :: Policy -> [(WindowId, Int, Int)]
renderPointerPositions p =
  [(wid,rectX rect,rectY rect) | wid <- Map.keys (pointerAnchors p)
    , anchorValid wid p, Just rect <- [displayedRect wid p]]

materializeAnchor :: WindowId -> Policy -> Policy
materializeAnchor wid p = case Map.lookup wid (pointerAnchors p) of
  Nothing -> p
  Just _ -> let next = case displayedRect wid p of
                  Nothing -> p
                  Just rect -> alterMetadata wid (\m -> m { windowFloatRect = Just rect }) p
            in next { pointerAnchors = Map.delete wid (pointerAnchors next) }

materializeAnchors :: Policy -> Policy
materializeAnchors p = foldr materializeAnchor p (Map.keys (pointerAnchors p))

preserveInvalidAnchor :: Policy -> WindowId -> Policy -> Policy
preserveInvalidAnchor previous wid next
  | anchorValid wid next = next
  | otherwise = case displayedRect wid previous of
      Just rect -> alterMetadata wid (\m -> m { windowFloatRect = Just rect }) next
      Nothing -> next

cancelPointer :: Policy -> Policy
cancelPointer p = p { pointerOperation = Nothing }

endPointer :: SeatId -> Policy -> Policy
endPointer sid p = case pointerOperation p of
  Just operation | pointerSeat operation == sid -> cancelPointer p
  _ -> p

preparePointerEvent :: Event -> Policy -> Policy
preparePointerEvent ev p = case ev of
  ActionRequested action -> case action of
    Terminal -> p
    Launcher -> p
    RunCommand _ -> p
    Reload -> p
    ConfirmExit _ -> p
    FocusNext -> cancelPointer p
    FocusPrevious -> cancelPointer p
    FocusDirection _ -> cancelPointer p
    FocusModeToggle -> cancelPointer p
    FocusNextOutput -> cancelPointer p
    FocusPreviousOutput -> cancelPointer p
    EnterMode _ -> cancelPointer p
    Close -> cancelPointer p
    Stop -> cancelPointer p
    MoveDirection _ -> focusedGeometry
    Resize _ _ -> focusedGeometry
    ToggleFloat -> focusedGeometry
    Sink -> focusedGeometry
    ToggleFullscreen -> focusedGeometry
    _ -> cancelPointer p
  WindowAdded wid | not (S.member wid (windowSet p)) && wid /= 0 -> cancelPointer p
  FocusRequested wid | wid `elem` visibleWindows p && Just wid /= focusedWindow p -> cancelPointer p
  Locked -> cancelPointer p
  WindowSizeHints wid a b c d
    | windowHints (metadataFor p wid) /= (max 0 a,max 0 b,max 0 c,max 0 d) -> cancelWindow wid
  WindowFullscreen wid enabled
    | windowFullscreen (metadataFor p wid) /= enabled -> cancelWindow wid
  WindowParent wid parent
    | windowParent (metadataFor p wid) /= parent -> materializeAnchors (cancelPointer p)
  OutputUpsert oid rect | Map.lookup oid (outputs p) /= Just (positive rect) -> cancelOutput oid
  OutputRemoved oid -> cancelOutput oid
  OutputWorkArea oid rect | Map.lookup oid (workAreas p) /= Just rect -> cancelOutput oid
  _ -> p
  where
    focusedGeometry = maybe id materializeAnchor (focusedWindow p) (cancelPointer p)
    cancelWindow wid = materializeAnchor wid $ case pointerOperation p of
      Just operation | pointerWindow operation == wid -> cancelPointer p
      _ -> p
    cancelOutput oid = foldr materializeAnchor next
      [wid | (wid,anchor) <- Map.toList (pointerAnchors p), anchorOutput anchor == oid]
      where next = case pointerOperation p of
              Just operation | pointerOutput operation == oid -> cancelPointer p
              _ -> p

anchorValid :: WindowId -> Policy -> Bool
anchorValid wid p = case (Map.lookup wid (pointerAnchors p), windowPlacement wid p) of
  (Just anchor, Just placement) -> placementFloating placement && not (placementFullscreen placement)
    && not (windowFullscreen (metadataFor p wid))
    && placementOutput placement == Just (anchorOutput anchor)
    && S.findTag wid (windowSet p) == Just (anchorWorkspace anchor)
    && Map.lookup (anchorOutput anchor) (outputs p) == Just (anchorOutputRect anchor)
    && areaFor (anchorOutput anchor) p == Just (anchorArea anchor)
  _ -> False

operationValid :: PointerOperation -> Policy -> Bool
operationValid operation p = not (sessionLocked p)
  && focusedWindow p == Just (pointerWindow operation)
  && anchorValid (pointerWindow operation) p
  && windowHints (metadataFor p (pointerWindow operation)) == pointerHints operation

validatePointerState :: Policy -> Policy
validatePointerState p = p
  { pointerOperation = case pointerOperation p of
      Just operation | operationValid operation p -> Just operation
      _ -> Nothing
  , pointerAnchors = Map.filterWithKey (\wid _ -> anchorValid wid p) (pointerAnchors p)
  }

startPointer :: SeatId -> WindowId -> Word32 -> Int -> Int -> Policy -> Policy
startPointer sid wid requestedEdges px py p
  | sid == 0 || sessionLocked p || pointerOperation p /= Nothing = p
  | otherwise = case (windowPlacement wid p, Map.lookup wid (pointerActualSizes p), displayedRect wid p) of
      (Just placement, Just _, Just initial)
        | placementFloating placement && not (placementFullscreen placement)
        , not (windowFullscreen (metadataFor p wid))
        , Just oid <- placementOutput placement
        , Just output <- Map.lookup oid (outputs p)
        , Just area <- areaFor oid p
        , Just tag <- S.findTag wid (windowSet p)
        , rectWidth initial <= rectWidth area && rectHeight initial <= rectHeight area
        , insideArea initial area
        , Just edges <- selectedEdges initial ->
          let ready = materializeAnchor wid p
              anchor = PointerAnchor edges initial oid output area tag
              operation = PointerOperation sid wid edges initial oid output area tag
                (windowHints (metadataFor p wid))
          in (alterMetadata wid (\m -> m { windowFloatRect = Just initial }) ready)
            { pointerOperation = Just operation
            , pointerAnchors = Map.insert wid anchor (pointerAnchors ready)
            , windowSet = S.focusWindow wid (windowSet ready) }
      _ -> p
  where
    insideArea rect area = all id
      [rectX rect >= rectX area, rectY rect >= rectY area
      , toInteger (rectX rect)+toInteger (rectWidth rect) <= toInteger (rectX area)+toInteger (rectWidth area)
      , toInteger (rectY rect)+toInteger (rectHeight rect) <= toInteger (rectY area)+toInteger (rectHeight area)]
    selectedEdges initial
      | requestedEdges == 16 = Just
          ((if 2 * toInteger px < 2 * toInteger (rectX initial) + toInteger (rectWidth initial) then 4 else 8)
          .|. (if 2 * toInteger py < 2 * toInteger (rectY initial) + toInteger (rectHeight initial) then 1 else 2))
      | requestedEdges `elem` [0,1,2,4,8,5,6,9,10] = Just requestedEdges
      | otherwise = Nothing

movePointer :: SeatId -> Int -> Int -> Policy -> Policy
movePointer sid dx dy p = case pointerOperation p of
  Just operation | pointerSeat operation == sid && operationValid operation p ->
    alterMetadata (pointerWindow operation) (\m -> m { windowFloatRect = Just (geometry operation) }) p
  _ -> p
  where
    geometry operation = Rect (abiCoordinate x) (abiCoordinate y) (fromInteger width) (fromInteger height)
      where
        initial = pointerInitialRect operation
        area = pointerArea operation
        edges = pointerEdges operation
        border = 0 -- windows are drawn without a frame
        (minW,minH,maxW,maxH) = pointerHints operation
        (x,width) = axis edges 4 8 (rectX initial) (rectWidth initial)
          (rectX area) (rectWidth area) dx minW maxW border
        (y,height) = axis edges 1 2 (rectY initial) (rectHeight initial)
          (rectY area) (rectHeight area) dy minH maxH border
    axis edges leading trailing oldOrigin oldSize areaOrigin areaSize delta lowerHint upperHint border
      | edges == 0 = (bound lower (max lower (upper-size)) (origin+motion),size)
      | otherwise = (if leadingActive then origin+size-requested else origin,requested)
      where
        origin = toInteger oldOrigin; size = toInteger oldSize
        lower = toInteger areaOrigin; upper = lower+toInteger areaSize
        motion = toInteger delta
        leadingActive = edges .&. leading /= 0
        trailingActive = edges .&. trailing /= 0
        desired | leadingActive = size-motion
                | trailingActive = size+motion
                | otherwise = size
        available | leadingActive = origin+size-lower
                  | otherwise = upper-origin
        maximumSize = max 1 (min (toInteger (maxBound :: Int32)) available)
        minimumSize = max 1 (toInteger lowerHint+border)
        hintMaximum = if upperHint > 0 then toInteger upperHint+border else maximumSize
        requested | not leadingActive && not trailingActive = size
                  | otherwise = max 1 (min maximumSize (max minimumSize (min hintMaximum desired)))
    bound lower upper = max lower . min upper

alterMetadata :: WindowId -> (WindowMetadata -> WindowMetadata) -> Policy -> Policy
alterMetadata wid f p = p { windowMetadata = Map.adjust f wid (windowMetadata p) }

metadataFor :: Policy -> WindowId -> WindowMetadata
metadataFor p wid = Map.findWithDefault defaultMetadata wid (windowMetadata p)

fixedSize :: (Int, Int, Int, Int) -> Bool
fixedSize (minW, minH, maxW, maxH) = minW > 0 && minH > 0 && minW == maxW && minH == maxH

-- | Protocol strings are untrusted: bound their length and drop control
-- characters before they reach picker labels or any command line.
sanitizeMeta :: String -> String
sanitizeMeta = take 255 . filter (\c -> c >= ' ' && c /= '\DEL')

-- | Letter, screen rectangle and window id for every visible window of the
-- current workspace, in focus order, like XMonad's EasyMotion candidates.
pickerChoices :: Policy -> [(Char, Rect, WindowId)]
pickerChoices p = take 35
  [ (letter, rect, wid)
  | (letter, wid) <- zip letters (S.index (windowSet p))
  , Just rect <- [Map.lookup wid placements] ]
  where
    letters = ['a'..'z'] ++ ['1'..'9']
    placements = Map.fromList [ (placementWindow pl, placementRect pl)
                              | pl <- renderPolicy p, placementVisible pl ]

-- | Show the letter overlay and arm the picker mode.
startPicker :: Policy -> (Policy, [Effect])
startPicker p = case pickerChoices p of
  [] -> (p, [])
  candidates -> (p { activeMode = PickerMode }, [ShowPicker [(c, r) | (c, r, _) <- candidates]])

-- | Swap the candidate into the focused position and hide the overlay.
finishPicker :: Int -> Policy -> (Policy, [Effect])
finishPicker index p = case drop index (pickerChoices p) of
  ((_, _, wid):_) -> (p { activeMode = NormalMode
                        , windowSet = swapToWindow wid (windowSet p) }, [HidePicker])
  [] -> cancelPicker p

cancelPicker :: Policy -> (Policy, [Effect])
cancelPicker p = (p { activeMode = NormalMode }, [HidePicker])

-- | Swap the selected window with the focused one and focus it, mirroring
-- XMonad's swapNth flow: the old focused window takes the selected window's
-- former position and everything else keeps its place.
swapToWindow :: WindowId -> WindowSet -> WindowSet
swapToWindow wid stackSet = case S.index stackSet of
  (focused : rest) | focused /= wid -> case elemIndex wid rest of
    Just idx -> S.modify' (\_ -> S.Stack wid (take idx rest)
      (focused : drop (idx + 1) rest)) stackSet
    Nothing -> stackSet
  _ -> stackSet

data Navigation = ToWindow WindowId | ToWorkspace WorkspaceId

windowRect :: WindowId -> Policy -> Maybe Rect
windowRect wid = listToMaybe . map placementRect . filter
  (\q -> placementWindow q == wid && placementVisible q) . renderPolicy

currentArea :: Policy -> Maybe Rect
currentArea p = do
  oid <- focusedOutput p
  area <- Map.lookup oid (outputs p)
  pure (maybe area (clipArea area) (Map.lookup oid (workAreas p)))

focusOtherMode :: Policy -> Policy
focusOtherMode p = case S.stack (S.workspace (S.current (windowSet p))) of
  Nothing -> p
  Just stack -> case filter opposite (S.up stack ++ S.down stack) of
    wid:_ -> p { windowSet = S.focusWindow wid (windowSet p) }
    [] -> p
    where opposite wid = windowFloating (metadataFor p wid) /= windowFloating (metadataFor p (S.focus stack))

-- Prefer windows whose perpendicular spans overlap, then the closest edge.
-- Global rectangles make this work for outputs above, below or left of origin.
directionScore :: Direction -> Rect -> Rect -> Maybe (Int, Integer, Integer)
directionScore direction origin target
  | forward <= 0 = Nothing
  | otherwise = Just (if overlap then 0 else 1, max 0 gap, abs sideways)
  where
    geometry (Rect x y w h) = (toInteger x, toInteger y, toInteger w, toInteger h)
    (ox,oy,ow,oh) = geometry origin
    (tx,ty,tw,th) = geometry target
    horizontal = direction == GoLeft || direction == GoRight
    positiveDirection = direction == GoRight || direction == GoDown
    delta = if horizontal then 2*tx+tw-2*ox-ow else 2*ty+th-2*oy-oh
    forward = if positiveDirection then delta else negate delta
    sideways = if horizontal then 2*ty+th-2*oy-oh else 2*tx+tw-2*ox-ow
    overlap = if horizontal then ty < oy+oh && oy < ty+th else tx < ox+ow && ox < tx+tw
    gap = case direction of
      GoLeft -> ox-tx-tw
      GoRight -> tx-ox-ow
      GoUp -> oy-ty-th
      GoDown -> ty-oy-oh

directionTarget :: Direction -> Policy -> Maybe Navigation
directionTarget direction p = case hiddenNeighbor of
  Just wid -> Just (ToWindow wid)
  Nothing -> do
    origin <- case focused of
      Just wid -> windowRect wid p
      Nothing -> currentArea p
    listToMaybe (map snd (sortOn fst (windowTargets origin ++ emptyTargets origin)))
  where
    ws = windowSet p
    focused = S.peek ws
    sameMode wid = maybe True (\selected -> windowFloating (metadataFor p wid) == windowFloating (metadataFor p selected)) focused
    current = S.workspace (S.current ws)
    singleTile = layoutKind (S.layout current) `elem` [Full, Tabbed, Stacking]
      || maybe False (windowFullscreen . metadataFor p) focused
    members = filter sameMode (S.integrate' (S.stack current))
    hiddenNeighbor = do
      wid <- focused
      index <- elemIndex wid members
      let next = index + if direction `elem` [GoRight, GoDown] then 1 else -1
      if singleTile && not (windowFloating (metadataFor p wid)) && next >= 0 && next < length members
        then Just (members !! next) else Nothing
    windowTargets origin =
      [(score, ToWindow wid) | q <- renderPolicy p, let wid = placementWindow q
       , placementVisible q, Just wid /= focused, sameMode wid
       , Just score <- [directionScore direction origin (placementRect q)]]
    emptyTargets origin =
      [(score, ToWorkspace (S.tag (S.workspace screen))) | screen <- S.screens ws
       , S.screen screen /= S.screen (S.current ws), S.stack (S.workspace screen) == Nothing
       , Just oid <- [S.screen screen], Just rect <- [Map.lookup oid (outputs p)]
       , Just score <- [directionScore direction origin rect]]

focusDirection :: Direction -> Policy -> Policy
focusDirection direction p = case directionTarget direction p of
  Just (ToWindow wid) -> p { windowSet = S.focusWindow wid (windowSet p) }
  Just (ToWorkspace tag) -> p { windowSet = S.view tag (windowSet p) }
  Nothing -> p

moveDirection :: Direction -> Policy -> Policy
moveDirection direction p = case S.peek (windowSet p) of
  Nothing -> p
  Just wid
    | windowFullscreen (metadataFor p wid) -> p
    | windowFloating (metadataFor p wid) -> case windowRect wid p of
        Nothing -> p
        Just (Rect x y w h) -> alterMetadata wid (\m -> m { windowFloatRect = Just
          (Rect (x + dx) (y + dy) w h) }) p
      where
        (dx,dy) = case direction of GoLeft -> (-10,0); GoRight -> (10,0); GoUp -> (0,-10); GoDown -> (0,10)
  Just wid -> case directionTarget direction p of
    Just (ToWindow other)
      | S.findTag other (windowSet p) == S.findTag wid (windowSet p) ->
          let replace i | i == wid = other | i == other = wid | otherwise = i
              swap stack = S.Stack (replace (S.focus stack)) (map replace (S.up stack)) (map replace (S.down stack))
          in p { windowSet = S.focusWindow wid (S.modify' swap (windowSet p)) }
      | Just tag <- S.findTag other (windowSet p) -> transfer wid tag
    Just (ToWorkspace tag) -> transfer wid tag
    _ -> p
  where
    transfer wid tag = let moved = shiftFamily wid tag p
      in moved { windowSet = S.focusWindow wid (S.view tag (windowSet moved)) }

resizeWindow :: Axis -> Int -> Policy -> Policy
resizeWindow axis amount p = case (S.peek ws, currentArea p) of
  (Just wid, Just area)
    | windowFullscreen (metadataFor p wid) -> p
    | windowFloating (metadataFor p wid), Just old <- windowRect wid p ->
        let grow size = fromInteger (max 1 (min (toInteger (maxBound :: Int32)) (toInteger size + toInteger amount)))
            width = if axis == Width then grow (rectWidth old) else rectWidth old
            height = if axis == Height then grow (rectHeight old) else rectHeight old
            next = Rect (rectX old + (rectWidth old-width) `div` 2)
              (rectY old + (rectHeight old-height) `div` 2) width height
        in alterMetadata wid (\m -> m { windowFloatRect = Just (floatRect area m { windowFloatRect = Just next }) }) p
    | otherwise -> resizeTile wid area
  _ -> p
  where
    ws = windowSet p
    workspace = S.workspace (S.current ws)
    layout = S.layout workspace
    tiles = filter (not . windowFloating . metadataFor p) (S.integrate' (S.stack workspace))
    resizeTile wid area = case (layoutKind layout, axis, tiles) of
      (Columns, Width, _) -> weights wid area tiles
      (Rows, Height, _) -> weights wid area tiles
      (Tall, Width, master:_:_) -> split wid master (rectWidth area)
      (Mirror, Height, master:_:_) -> split wid master (rectHeight area)
      (Tall, Height, _:slaves) | wid `elem` slaves -> weights wid area slaves
      (Mirror, Width, _:slaves) | wid `elem` slaves -> weights wid area slaves
      _ -> p
    split wid master available = p { windowSet = S.mapWorkspace update ws }
      where
        delta = fromIntegral amount / fromIntegral available * if wid == master then 1 else -1
        update w | S.tag w == S.currentTag ws = w { S.layout = layout
                     { masterRatio = clampRatio (masterRatio layout + delta) } }
                 | otherwise = w
    weights wid area group = case elemIndex wid group of
      Just index | length group > 1 && available >= length group ->
        let other = group !! (if index + 1 < length group then index + 1 else index - 1)
            extent i = maybe 1 (if axis == Width then rectWidth else rectHeight) (windowRect i p)
            delta = max (1 - extent wid) (min (extent other - 1) amount)
            size i = extent i + (if i == wid then delta else if i == other then -delta else 0)
            update i = alterMetadata i (\m -> if axis == Width
              then m { windowWidthWeight = fromIntegral (size i) }
              else m { windowHeightWeight = fromIntegral (size i) })
        in foldr (\i next -> update i next) p group
      _ -> p
      where available = if axis == Width then rectWidth area else rectHeight area

-- A parent and its transient descendants move as a family. The visited list
-- also bounds traversal if a custom configuration supplies cyclic metadata.
descendants :: Policy -> WindowId -> [WindowId]
descendants p root = grow [root]
  where
    grow seen = let next = [wid | (wid,m) <- Map.toList (windowMetadata p)
                              , maybe False (`elem` seen) (windowParent m), wid `notElem` seen]
                in if null next then filter (/= root) seen else grow (seen ++ next)

shiftFamily :: WindowId -> WorkspaceId -> Policy -> Policy
shiftFamily wid tag p = p { windowSet = foldr (S.shiftWin tag) (windowSet p) (wid : descendants p wid) }

-- | Keep workspace stacks intact while outputs come and go. A virtual screen
-- preserves StackSet's nonempty-current invariant when the last output leaves.
-- At most one output per workspace is assigned; extras remain unassigned until
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
      (Just rect, Just stack)
        | windowFullscreen (metadataFor p (S.focus stack)) ->
            [(S.focus stack, (rect, S.screen s, False, True))]
        | otherwise ->
            let area = maybe rect (clipArea rect) (S.screen s >>= (`Map.lookup` workAreas p))
                isFloat wid = windowFloating (metadataFor p wid)
                tiled = maybe [] (layoutRects p (S.layout (S.workspace s)) area) (S.filter (not . isFloat) stack)
                floats = [(wid, pointerFloatRect wid area)
                         | wid <- S.integrate stack, isFloat wid]
            in [(wid, (r, S.screen s, isFloat wid, False)) | (wid,r) <- tiled ++ floats]
      _ -> []
    focused = focusedWindow p
    pointerFloatRect wid area = case (Map.lookup wid (pointerAnchors p), windowFloatRect (metadataFor p wid)) of
      -- Pointer geometry has already resolved hint/workarea conflicts while
      -- preserving the fixed edge. Applying minimum hints again here would
      -- enlarge the rectangle past that edge when the minimum is impossible.
      (Just _, Just rect) -> confineRect area rect
      _ -> floatRect area (metadataFor p wid)
    placement wid = case Map.lookup wid rectangles of
      Just (rect, output, floating, fullscreen) ->
        Placement wid rect True (Just wid == focused) output floating fullscreen
      Nothing -> Placement wid (Rect 0 0 1 1) False False Nothing False False

-- A stale or oversized panel hint must never place windows outside the output.
-- An exhausted workarea retains one pixel so the window protocol stays valid.
clipArea :: Rect -> Rect -> Rect
clipArea (Rect ox oy ow oh) (Rect x y w h) = Rect left top width height
  where
    (left, width) = clip ox ow x w
    (top, height) = clip oy oh y h
    clip origin extent start size = (fromInteger first, fromInteger (lastPixel - first))
      where
        lower = toInteger origin
        upper = lower + toInteger extent
        first = max lower (min (upper - 1) (toInteger start))
        lastPixel = min upper (max (first + 1) (toInteger start + toInteger size))

confineRect :: Rect -> Rect -> Rect
confineRect (Rect ax ay aw ah) (Rect x y w h) = Rect (position ax aw width x)
  (position ay ah height y) width height
  where
    width = max 1 (min aw w)
    height = max 1 (min ah h)
    position origin available size requested = abiCoordinate (max lower (min upper (toInteger requested)))
      where lower = toInteger origin
            upper = lower+toInteger available-toInteger size

-- Size hints describe content, while policy rectangles include the border.
-- Large hints are bounded to the output and all arithmetic stays in Integer.
floatingRect :: Rect -> (Int, Int, Int, Int) -> Rect
floatingRect (Rect x y w h) (minW, minH, maxW, maxH) =
  Rect (x + (w - width) `div` 2) (y + (h - height) `div` 2) width height
  where
    extent available lower upper = fromInteger $ max 1 $ min (toInteger available) $
      max (toInteger lower + border) (min preferred ceilingSize)
      where
        border = 0 -- windows are drawn without a frame
        preferred = toInteger available `div` 2
        ceilingSize = if upper > 0 then toInteger upper + border else toInteger available
    width = extent w minW maxW
    height = extent h minH maxH

floatRect :: Rect -> WindowMetadata -> Rect
floatRect area@(Rect ax ay aw ah) metadata = case windowFloatRect metadata of
  Nothing -> floatingRect area (windowHints metadata)
  Just (Rect x y w h) -> Rect (max ax (min (ax + aw - width) x))
    (max ay (min (ay + ah - height) y)) width height
    where
      (minW, minH, maxW, maxH) = windowHints metadata
      border = 0 -- windows are drawn without a frame
      bounded available lower upper requested = max 1 (min available
        (max (lower + border) (min requested (if upper > 0 then upper + border else available))))
      width = bounded aw minW maxW w
      height = bounded ah minH maxH h

focusedWindow :: Policy -> Maybe WindowId
focusedWindow p
  | sessionLocked p || Map.null (outputs p) = Nothing
  | otherwise = S.peek (windowSet p)

focusedOutput :: Policy -> Maybe OutputId
focusedOutput = S.screen . S.current . windowSet

layoutRects :: Policy -> LayoutState -> Rect -> S.Stack WindowId -> [(WindowId, Rect)]
layoutRects p l rect stack = case layoutKind l of
  Full -> [(S.focus stack, rect)]
  Tabbed -> [(S.focus stack, rect)]
  Stacking -> [(S.focus stack, rect)]
  Columns -> weighted Width rect (S.integrate stack)
  Rows -> weighted Height rect (S.integrate stack)
  Tall -> tallWeighted Width rect
  Mirror -> map (\(w,r) -> (w, transpose r))
    (tallWeighted Height (transpose rect))
  where
    transpose (Rect x y w h) = Rect y x h w
    weight axis wid = (if axis == Width then windowWidthWeight else windowHeightWeight) (metadataFor p wid)
    weighted axis area = weightedRects axis (weight axis) area
    tallWeighted axis area = case tall (masterRatio l) area (S.integrate stack) of
      [] -> []
      [single] -> [single]
      master:slaves@((_, Rect sx sy sw _):_) ->
        master : weightedRects Height (weight (if axis == Width then Height else Width))
          (Rect sx sy sw (rectHeight area)) (map fst slaves)

weightedRects :: Axis -> (WindowId -> Rational) -> Rect -> [WindowId] -> [(WindowId, Rect)]
weightedRects _ _ _ [] = []
weightedRects axis weight (Rect x y w h) windows = zipWith place windows boundaries
  where
    weights = map (max (1 / 1000000) . weight) windows
    total = sum weights
    available = if axis == Width then w else h
    edges = map (floor . (* fromIntegral available) . (/ total)) (scanl (+) 0 weights)
    boundaries = zip edges (drop 1 edges)
    place wid (first, lastPixel) =
      let start = min (available - 1) first
          extent = max 1 (min available lastPixel - start)
      in (wid, if axis == Width then Rect (x + start) y extent h else Rect x (y + start) w extent)

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
