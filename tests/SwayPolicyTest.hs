module Main (main) where

import Control.Monad (unless, forM_)
import Data.List (sort, nub)
import qualified Data.Map.Strict as Map
import qualified XMonad.StackSet as S
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Policy
import XMonad.Wayland.Types

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

cfg :: Config
cfg = defaultConfig { workspaceIds = [1..10] }

step :: Event -> Policy -> Policy
step event = fst . handleEvent cfg event

act :: Action -> Policy -> Policy
act = step . ActionRequested

base :: Policy
base = foldl (flip step) (initialPolicy cfg)
  [OutputUpsert 7 (Rect 0 0 800 600), WindowAdded 10, WindowAdded 20, WindowAdded 30]

rect :: WindowId -> Policy -> Maybe Rect
rect wid p = case [placementRect q | q <- renderPolicy p, placementWindow q == wid, placementVisible q] of
  r:_ -> Just r
  [] -> Nothing

shown :: Policy -> [WindowId]
shown = sort . map placementWindow . filter placementVisible . renderPolicy

stress :: IO ()
stress = forM_ [73, 1729, 8675309] $ \seed -> do
  let numbers = drop 1 (iterate (\n -> (1664525*n + 1013904223) `mod` 4294967296) seed)
      event n =
        let wid = fromInteger (10 + n `mod` 15)
            oid = fromInteger (1 + n `mod` 4)
            tag = fromInteger (1 + n `mod` 10)
            direction = [GoLeft, GoDown, GoUp, GoRight] !! fromInteger ((n `div` 41) `mod` 4)
            action = case n `mod` 17 of
              0 -> FocusDirection direction
              1 -> MoveDirection direction
              2 -> Resize Width (if even (n `div` 41) then 10 else -10)
              3 -> Resize Height (if even (n `div` 41) then 10 else -10)
              4 -> SetLayout ([Tall, Mirror, Full, Tabbed, Stacking, Rows, Columns] !! fromInteger ((n `div` 41) `mod` 7))
              5 -> ToggleSplit
              6 -> CycleSwayLayout
              7 -> ToggleFullscreen
              8 -> ToggleFloat
              9 -> Sink
              10 -> FocusModeToggle
              11 -> EnterMode ResizeMode
              12 -> EnterMode NormalMode
              13 -> View tag
              14 -> Shift tag
              15 -> FocusNext
              _ -> FocusPrevious
        in case n `mod` 41 of
          0 -> OutputUpsert oid (Rect (fromInteger (n `mod` 1600) - 800) (-100)
            (fromInteger (n `mod` 800) + 1) (fromInteger (n `mod` 600) + 1))
          1 -> OutputRemoved oid
          2 -> OutputWorkArea oid (Rect (-50) 30 (fromInteger (n `mod` 1200)) (fromInteger (n `mod` 600)))
          3 -> WindowAdded wid
          4 -> WindowAdded wid
          5 -> WindowRemoved wid
          6 -> WindowParent wid (Just (fromInteger (10 + (n `div` 17) `mod` 15)))
          7 -> WindowSizeHints wid 0 0 (fromInteger (n `mod` 500)) (fromInteger (n `mod` 300))
          8 -> Locked
          9 -> Unlocked
          _ -> ActionRequested action
      states = scanl (flip step) base (map event (take 4000 numbers))
  forM_ (zip [0 :: Int ..] states) $ \(index,p) -> do
    let windows = S.allWindows (windowSet p)
        placements = renderPolicy p
        inside q = case placementOutput q >>= (`Map.lookup` outputs p) of
          Nothing -> False
          Just (Rect x y w h) -> let Rect px py pw ph = placementRect q in
            pw > 0 && ph > 0 && px >= x && py >= y && px+pw <= x+w && py+ph <= y+h
    assert ("Sway lifecycle invariants, seed " ++ show seed ++ ", step " ++ show index)
      (sort (map S.tag (S.workspaces (windowSet p))) == [1..10]
        && length windows == length (nub windows)
        && sort windows == Map.keys (windowMetadata p)
        && all inside (filter placementVisible placements)
        && map placementWindow (filter placementFocused placements) == maybe [] pure (focusedWindow p))

main :: IO ()
main = do
  let ten = act (Shift 10) base
  assert "workspace 10 accepts shifted windows" (S.findTag 30 (windowSet ten) == Just 10)
  assert "workspace 10 can be viewed" (focusedWindow (act (View 10) ten) == Just 30)
  assert "workspace identifiers remain unique" (sort (map S.tag (S.workspaces (windowSet base))) == [1..10])
  let emptyCfg = cfg { workspaceIds = [] }
      duplicateCfg = cfg { workspaceIds = [3,3,7] }
  assert "empty workspace configuration preserves a usable current workspace"
    (map S.tag (S.workspaces (windowSet (initialPolicy emptyCfg))) == [1])
  assert "custom workspace identifiers retain order without duplicates"
    (map S.tag (S.workspaces (windowSet (initialPolicy duplicateCfg))) == [3,7])
  assert "directional focus uses geometry"
    (focusedWindow (act (FocusDirection GoRight) base) == Just 20
      && focusedWindow (act (FocusDirection GoDown) (act (FocusDirection GoRight) base)) == Just 10)
  assert "directional focus does not wrap at the output boundary"
    (focusedWindow (act (FocusDirection GoLeft) base) == Just 30)
  let swapped = act (MoveDirection GoRight) base
  assert "directional move swaps tiles while preserving focused window"
    (focusedWindow swapped == Just 30 && rect 30 swapped == Just (Rect 400 0 400 300)
      && rect 20 swapped == Just (Rect 0 0 400 600))
  let dual = step (OutputUpsert 9 (Rect 800 0 800 600)) base
      otherOutput = act (FocusDirection GoRight) (act (FocusDirection GoRight) dual)
  assert "directional focus reaches an empty neighboring output"
    (focusedOutput otherOutput == Just 9 && focusedWindow otherOutput == Nothing)
  assert "directional focus returns from an empty output"
    (focusedOutput (act (FocusDirection GoLeft) otherOutput) == Just 7)
  let edgeFocused = step (FocusRequested 20) dual
      movedOutput = act (MoveDirection GoRight) edgeFocused
  assert "directional move at the edge transfers the window to its neighboring output"
    (focusedOutput movedOutput == Just 9 && S.findTag 20 (windowSet movedOutput) == Just 2
      && focusedWindow movedOutput == Just 20)
  let floating = act ToggleFloat base
      floatResized = act (Resize Width 10) (act (Resize Height 10) floating)
      floatMoved = act (MoveDirection GoRight) floatResized
  assert "floating resize changes each requested axis by ten pixels"
    (fmap rectWidth (rect 30 floatResized) == Just 410 && fmap rectHeight (rect 30 floatResized) == Just 310)
  assert "directional floating move translates its rectangle"
    (fmap rectX (rect 30 floatMoved) == ((+10) <$> fmap rectX (rect 30 floatResized)))
  assert "sink returns a floating window to its tile"
    (renderPolicy (act Sink floating) == renderPolicy base)
  let tiledFocus = act FocusModeToggle floating
      floatFocus = act FocusModeToggle tiledFocus
  assert "focus mode toggles tiled and floating windows"
    (focusedWindow tiledFocus /= Just 30 && focusedWindow floatFocus == Just 30)
  assert "focus mode toggle is unchanged when no opposite mode exists"
    (focusedWindow (act FocusModeToggle base) == Just 30)
  let columns = act (SetLayout Columns) base
      rows = act (SetLayout Rows) base
  assert "columns and rows split the whole workspace"
    (rect 30 columns == Just (Rect 0 0 266 600) && rect 10 columns == Just (Rect 533 0 267 600)
      && rect 30 rows == Just (Rect 0 0 800 200) && rect 10 rows == Just (Rect 0 400 800 200))
  assert "split toggle switches horizontal and vertical arrangements"
    (renderPolicy (act ToggleSplit columns) == renderPolicy rows
      && renderPolicy (act ToggleSplit rows) == renderPolicy columns)
  let resizedColumns = act (Resize Width 10) columns
      resizedRows = act (Resize Height (-10)) rows
  assert "column resize exchanges ten pixels with a neighbor"
    (fmap rectWidth (rect 30 resizedColumns) == Just 276 && fmap rectWidth (rect 20 resizedColumns) == Just 257)
  assert "row resize exchanges ten pixels with a neighbor"
    (fmap rectHeight (rect 30 resizedRows) == Just 190 && fmap rectHeight (rect 20 resizedRows) == Just 210)
  assert "orthogonal resize leaves a flat split unchanged"
    (renderPolicy (act (Resize Height 10) columns) == renderPolicy columns)
  assert "master resize uses pixels with the correct direction"
    (fmap rectWidth (rect 30 (act (Resize Width (-10)) base)) == Just 390
      && fmap rectWidth (rect 20 (act (Resize Width 10) (step (FocusRequested 20) base))) == Just 410)
  assert "slave resize changes stack height independently"
    (fmap rectHeight (rect 20 (act (Resize Height 10) (step (FocusRequested 20) base))) == Just 310)
  let tabbed = act (SetLayout Tabbed) base
      stacked = act (SetLayout Stacking) base
  assert "tabbed and stacking select one tile"
    (shown tabbed == [30] && shown stacked == [30])
  assert "directional focus can select hidden tab and stack members"
    (shown (act (FocusDirection GoRight) tabbed) == [20]
      && shown (act (FocusDirection GoDown) stacked) == [20])
  assert "Sway layout cycle traverses split tabbed stacking"
    (renderPolicy (act CycleSwayLayout columns) == renderPolicy tabbed
      && renderPolicy (act CycleSwayLayout tabbed) == renderPolicy stacked
      && renderPolicy (act CycleSwayLayout stacked) == renderPolicy columns)
  let fullscreen = act ToggleFullscreen base
  assert "fullscreen keeps physical output dimensions during resize"
    (renderPolicy (act (Resize Width 10) fullscreen) == renderPolicy fullscreen)
  assert "directional focus can leave fullscreen without losing its state"
    (focusedWindow (act (FocusDirection GoRight) fullscreen) == Just 20
      && shown (act (FocusDirection GoLeft) (act (FocusDirection GoRight) fullscreen)) == [30])
  let locked = step Locked base
  assert "new actions preserve state while locked"
    (all (== locked) [act a locked | a <- [FocusDirection GoRight, MoveDirection GoRight,
       Sink, FocusModeToggle, SetLayout Rows, ToggleSplit, CycleSwayLayout, Resize Width 10, EnterMode ResizeMode]])
  assert "resize mode changes only mode state"
    (act (EnterMode ResizeMode) base /= base
      && renderPolicy (act (EnterMode ResizeMode) base) == renderPolicy base)
  assert "commands retain literal arguments"
    (snd (handleEvent cfg (ActionRequested (RunCommand (Command "printf" ["a b", "$(false)"]))) base)
      == [Spawn (Command "printf" ["a b", "$(false)"])])
  assert "reload produces its runtime effect" (snd (handleEvent cfg (ActionRequested Reload) base) == [ReloadConfig])
  let confirmation = Command "confirm-session-exit" ["literal argument"]
  assert "confirmed session exit keeps windows intact while requesting confirmation"
    (handleEvent cfg (ActionRequested (ConfirmExit confirmation)) base == (base, [ConfirmSessionExit confirmation]))
  let enormous = iterate (act (Resize Width 100000)) floating !! 3
  assert "floating resize stays inside its output"
    (case rect 30 enormous of Just (Rect x y w h) -> x >= 0 && y >= 0 && x+w <= 800 && y+h <= 600; _ -> False)
  assert "metadata remains attached after move and output changes"
    (Map.keys (windowMetadata movedOutput) == [10,20,30])
  stress
  putStrLn "All Sway policy tests passed (including 12,000 mixed lifecycle events)."
