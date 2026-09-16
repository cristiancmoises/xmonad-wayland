module Main (main) where

import Control.Monad (forM_, unless)
import Data.List (nub, sort)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import qualified XMonad.StackSet as S
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Policy
import XMonad.Wayland.Protocol (decodeAction, decodeEvent)
import XMonad.Wayland.Types

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)

step :: Event -> Policy -> Policy
step ev = fst . handleEvent defaultConfig ev

act :: Action -> Policy -> Policy
act = step . ActionRequested

events :: [Event] -> Policy
events = foldl (flip step) (initialPolicy defaultConfig)

base :: Policy
base = events [OutputUpsert 7 (Rect 0 0 800 600), WindowAdded 10, WindowAdded 20, WindowAdded 30]

shown :: Policy -> [WindowId]
shown = sort . map placementWindow . filter placementVisible . renderPolicy

main :: IO ()
main = do
  assert "new windows appear on the first output" (shown base == [10,20,30])
  assert "insertion focuses the new window" (focusedWindow base == Just 30)
  let next = act FocusNext base
  assert "focus cycles without rearranging the master" (focusedWindow next == Just 20 && S.index (windowSet next) == [30,20,10])
  assert "previous focus wraps" (focusedWindow (act FocusPrevious base) == Just 10)
  assert "swap master moves focused window to the front" (S.index (windowSet (act SwapMaster next)) == [20,30,10])
  assert "swap next reorders windows" (S.index (windowSet (act SwapNext base)) == [20,30,10])
  assert "swap previous wraps the focused window" (S.index (windowSet (act SwapPrevious base)) == [20,10,30])
  let shifted = act (Shift 2) base
  assert "shift preserves other windows and hides the shifted one" (shown shifted == [10,20] && sort (S.allWindows (windowSet shifted)) == [10,20,30])
  assert "view restores the target workspace and its focus" (shown (act (View 2) shifted) == [30] && focusedWindow (act (View 2) shifted) == Just 30)
  assert "unknown workspaces do not lose the focused window" (act (Shift 99) base == base && act (View 99) base == base)
  let dual = step (OutputUpsert 9 (Rect 800 0 640 480)) shifted
      viewed = act (View 2) dual
  assert "viewing an already visible workspace changes the active output" (S.screen (S.current (windowSet viewed)) == Just 9 && shown viewed == [10,20,30])
  let clicked = step (FocusRequested 10) viewed
  assert "click focus selects another output without moving workspaces" (focusedWindow clicked == Just 10 && S.screen (S.current (windowSet clicked)) == Just 7)
  assert "hidden window focus requests cannot change workspaces" (step (FocusRequested 30) shifted == shifted)
  let disconnected = step (OutputRemoved 9) viewed
      none = step (OutputRemoved 7) disconnected
      restored = step (OutputUpsert 17 (Rect (-100) 20 1024 768)) none
  assert "removing the current output preserves every window" (sort (S.allWindows (windowSet disconnected)) == [10,20,30])
  assert "disconnecting all outputs preserves windows but clears keyboard focus" (sort (S.allWindows (windowSet none)) == [10,20,30] && null (shown none) && focusedWindow none == Nothing)
  assert "reconnecting restores a usable workspace" (not (null (shown restored)) && sort (S.allWindows (windowSet restored)) == [10,20,30])
  let tall = renderPolicy base
      rectFor w ps = [placementRect p | p <- ps, placementWindow p == w, placementVisible p]
  assert "Tall partitions master and stack" (rectFor 30 tall == [Rect 0 0 400 600] && rectFor 20 tall == [Rect 400 0 400 300] && rectFor 10 tall == [Rect 400 300 400 300])
  let mirror = act NextLayout base
  assert "Mirror rotates the split axis" (rectFor 30 (renderPolicy mirror) == [Rect 0 0 800 300] && rectFor 20 (renderPolicy mirror) == [Rect 0 300 400 300])
  let full = act NextLayout mirror
  assert "Full displays only the focused window" (shown full == [30] && rectFor 30 (renderPolicy full) == [Rect 0 0 800 600])
  assert "Full updates the visible window when focus changes" (shown (act FocusNext full) == [20])
  assert "layout cycle returns to Tall" (renderPolicy (act NextLayout full) == tall)
  let smaller = act Shrink base
      otherWorkspace = act (View 2) smaller
  assert "resize affects the current workspace geometry" (rectFor 30 (renderPolicy smaller) == [Rect 0 0 376 600])
  assert "workspace ratio survives switching away and back" (renderPolicy (act (View 1) otherWorkspace) == renderPolicy smaller)
  assert "other workspaces retain their own ratio" (masterRatio (S.layout (S.workspace (S.current (windowSet otherWorkspace)))) == 1 / 2)
  let locked = step Locked base
  assert "locked session has no focus and ignores bindings" (focusedWindow locked == Nothing && act FocusNext locked == locked)
  assert "unlock restores logical focus" (focusedWindow (step Unlocked locked) == Just 30)
  assert "close requests target the focused window without deleting it early" (handleEvent defaultConfig (ActionRequested Close) base == (base, [CloseWindow 30]))
  assert "spawn effects preserve literal argv" (snd (handleEvent defaultConfig (ActionRequested Terminal) base) == [Spawn (terminalCommand defaultConfig)])
  assert "duplicate create and unknown remove events are harmless" (step (WindowAdded 20) base == base && step (WindowRemoved 999) base == base)
  assert "removal deletes the window from every workspace" (sort (S.allWindows (windowSet (step (WindowRemoved 30) shifted))) == [10,20])
  forM_ [Tall,Mirror,Full] $ \layout -> forM_ [(1,1),(1,2),(2,1),(2,2),(7,3)] $ \(w,h) -> do
    let cfg = defaultConfig {initialLayout = layout}
        p = foldl (\s e -> fst (handleEvent cfg e s)) (initialPolicy cfg)
            (OutputUpsert 1 (Rect (-13) 21 w h) : map WindowAdded [1..30])
        valid r = rectWidth r > 0 && rectHeight r > 0 && rectX r >= -13 && rectY r >= 21
          && rectX r + rectWidth r <= -13 + w && rectY r + rectHeight r <= 21 + h
    assert "tiny output geometry stays positive and within output bounds" (all (valid . placementRect) (filter placementVisible (renderPolicy p)))
  let many = foldl (flip step) base [OutputUpsert n (Rect 0 0 10 10) | n <- [1..15]]
      removed = foldl (flip step) many [OutputRemoved n | n <- [1..15]]
  assert "more outputs than workspaces preserve workspace uniqueness" (sort (map S.tag (S.workspaces (windowSet many))) == [1..9])
  assert "repeated hotplug cannot duplicate or discard windows" (sort (S.allWindows (windowSet removed)) == [10,20,30] && length (nub (S.allWindows (windowSet removed))) == 3)
  let edge = events [OutputUpsert 1 (Rect 2147483640 2147483640 100 100), WindowAdded 1, WindowAdded 2, WindowAdded 3]
      boundedPlacement r = all (<= toInteger (maxBound :: Int32))
        [toInteger (rectX r), toInteger (rectY r), toInteger (rectWidth r), toInteger (rectHeight r)]
        && toInteger (rectX r) + toInteger (rectWidth r) <= 2147483648
        && toInteger (rectY r) + toInteger (rectHeight r) <= 2147483648
  assert "output extents near Int32 max are normalized before layout"
    (Map.lookup 1 (outputs edge) == Just (Rect 2147483640 2147483640 8 8))
  assert "edge layouts never produce out-of-range coordinates"
    (all (boundedPlacement . placementRect) (renderPolicy edge))
  let large = events (OutputUpsert 1 (Rect 0 0 2147483647 2147483647) : map WindowAdded [1..30])
  assert "large layouts avoid intermediate multiplication overflow"
    (all (\p -> let r = placementRect p in rectHeight r > 0 && rectY r >= 0
      && toInteger (rectY r) + toInteger (rectHeight r) <= 2147483647) (renderPolicy large))
  assert "protocol action IDs preserve direction and workspace argument"
    (map (\n -> decodeAction n 4) [1..14] == map Just
      [FocusNext,FocusPrevious,SwapMaster,NextLayout,Shrink,Expand,View 4,Shift 4,Close,Terminal,Launcher,Stop,SwapNext,SwapPrevious])
  assert "protocol ignores unknown or out-of-range bindings"
    (decodeAction 99 0 == Nothing && decodeAction 7 0 == Nothing && decodeAction 8 10 == Nothing)
  assert "protocol preserves signed output positions"
    (decodeEvent 1 42 (-1200) (-10) 1200 800 == Just (OutputUpsert 42 (Rect (-1200) (-10) 1200 800)))
  assert "manage and render markers are not policy events"
    (decodeEvent 7 0 0 0 0 0 == Nothing && decodeEvent 8 0 0 0 0 0 == Nothing)
  putStrLn "All policy tests passed."
