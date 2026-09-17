module Main (main) where
import Control.Monad (unless, forM_)
import Data.Int (Int32)
import Data.Bits ((.&.))
import qualified Data.Map.Strict as Map
import qualified XMonad.StackSet as S
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Policy
import XMonad.Wayland.Protocol (decodeEvent)
import XMonad.Wayland.Types

assert :: String -> Bool -> IO ()
assert label ok = unless ok (fail label)
step :: Event -> Policy -> Policy
step ev = fst . handleEvent defaultConfig ev
act :: Action -> Policy -> Policy
act = step . ActionRequested
base :: Policy
base = foldl (flip step) (initialPolicy defaultConfig)
  [OutputUpsert 7 (Rect 0 0 800 600), WindowAdded 10, ActionRequested ToggleFloat,
   WindowActualSize 10 400 300]
rect :: Policy -> Rect
rect p = case [placementRect q | q <- renderPolicy p, placementWindow q == 10] of
  value:_ -> value
  [] -> error "test fixture lost window 10"
start :: Word -> Policy -> Policy
start edges = step (PointerStarted 3 10 (fromIntegral edges) 210 160)
position :: Policy -> (Int,Int)
position p = case [(x,y) | (10,x,y) <- renderPointerPositions p] of
  xy:_ -> xy
  [] -> let r = rect p in (rectX r,rectY r)

stress :: IO ()
stress = forM_ [17,1729,8675309] $ \seed -> do
  let randoms = drop 1 (iterate (\n -> (1664525*n+1013904223) `mod` 4294967296) seed)
      event n =
        let delta = fromInteger (n-2147483648)
            edges = [0,1,2,4,8,5,6,9,10,16] !! fromInteger ((n `div` 31) `mod` 10)
        in case n `mod` 23 of
          0 -> WindowRemoved 10
          1 -> WindowAdded 10
          2 -> ActionRequested ToggleFloat
          3 -> WindowActualSize 10 (1+fromInteger (n `mod` 700)) (1+fromInteger (n `mod` 500))
          4 -> PointerStarted 3 10 edges (fromInteger (n `mod` 800)) (fromInteger (n `mod` 600))
          5 -> PointerReleased 3
          6 -> PointerCancelled 3
          7 -> Locked
          8 -> Unlocked
          9 -> ActionRequested (View (1+fromInteger (n `mod` 2)))
          10 -> ActionRequested (Resize Width (fromInteger (n `mod` 60)-30))
          11 -> WindowSizeHints 10 0 0 (fromInteger (n `mod` 700)) (fromInteger (n `mod` 500))
          12 -> WindowFullscreen 10 (even (n `div` 31))
          13 -> OutputWorkArea 7 (Rect 0 (fromInteger (n `mod` 100)) 800 500)
          _ -> PointerMoved 3 delta (negate delta)
      states = scanl (flip step) base (map event (take 2500 randoms))
  forM_ (zip [0 :: Int ..] states) $ \(index,p) -> do
    let inside q = case placementOutput q >>= (`Map.lookup` outputs p) of
          Nothing -> False
          Just a -> let r = placementRect q in rectWidth r > 0 && rectHeight r > 0
            && rectX r >= rectX a && rectY r >= rectY a
            && toInteger (rectX r)+toInteger (rectWidth r) <= toInteger (rectX a)+toInteger (rectWidth a)
            && toInteger (rectY r)+toInteger (rectHeight r) <= toInteger (rectY a)+toInteger (rectHeight a)
        liveOperation = case pointerOperation p of
          Nothing -> True
          Just operation -> not (sessionLocked p) && focusedWindow p == Just (pointerWindow operation)
            && any (\q -> placementWindow q == pointerWindow operation && placementVisible q
                  && placementFloating q && not (placementFullscreen q)) (renderPolicy p)
        validPosition (wid,x,y) = S.member wid (windowSet p)
          && all (\n -> toInteger n >= toInteger (minBound :: Int32) && toInteger n <= toInteger (maxBound :: Int32)) [x,y]
    assert ("mixed pointer invariants " ++ show (seed,index))
      (liveOperation && all inside (filter placementVisible (renderPolicy p))
        && all validPosition (renderPointerPositions p)
        && all (`Map.member` windowMetadata p) (Map.keys (pointerActualSizes p)))
main :: IO ()
main = do
  assert "pointer ABI" (decodeEvent 21 10 3 5 210 160 == Just (PointerStarted 3 10 5 210 160)
    && decodeEvent 22 3 (-20) 30 0 0 == Just (PointerMoved 3 (-20) 30)
    && decodeEvent 23 3 0 0 0 0 == Just (PointerReleased 3)
    && decodeEvent 24 3 0 0 0 0 == Just (PointerCancelled 3)
    && decodeEvent 25 10 400 300 0 0 == Just (WindowActualSize 10 400 300))
  let moved = step (PointerMoved 3 30 (-20)) (step (PointerMoved 3 10 (-10)) (start 0 base))
  assert "motion is cumulative" (rect moved == Rect 230 130 400 300)
  assert "wrong-seat motion ignored" (step (PointerMoved 9 99 99) moved == moved)
  assert "second start cannot replace operation" (start 10 moved == moved)
  assert "release retains last geometry" (pointerOperation (step (PointerReleased 3) moved) == Nothing
    && rect (step (PointerMoved 3 99 99) (step (PointerReleased 3) moved)) == rect moved)
  assert "bounds use workarea" (rect (step (PointerMoved 3 maxBound minBound) (start 0 base)) == Rect 400 0 400 300)
  forM_ [1,2,4,8,5,6,9,10] $ \edges -> do
    let q = step (PointerMoved 3 40 30) (start edges base)
        left = edges .&. 4 /= 0; right = edges .&. 8 /= 0
        top = edges .&. 1 /= 0; bottom = edges .&. 2 /= 0
        expected = Rect (if left then 240 else 200) (if top then 180 else 150)
          (400 + if left then -40 else if right then 40 else 0)
          (300 + if top then -30 else if bottom then 30 else 0)
    assert ("edge geometry " ++ show edges) (rect q == expected)
  forM_ [3,7,12,15,17,maxBound :: Word] $ \edges ->
    assert "invalid edges rejected" (pointerOperation (start edges base) == Nothing)
  assert "nearest corner" (fmap pointerEdges (pointerOperation (start 16 base)) == Just 5)
  forM_ [(210,160,5),(590,160,9),(210,440,6),(590,440,10)] $ \(x,y,edge) ->
    assert "nearest corner quadrants" (fmap pointerEdges (pointerOperation (step (PointerStarted 3 10 16 x y) base)) == Just edge)
  let resized = step (PointerMoved 3 43 37) (start 5 base)
      acknowledged = step (WindowActualSize 10 352 256) resized
      released = step (PointerReleased 3) acknowledged
      late = step (WindowActualSize 10 344 248) released
  assert "actual dimensions preserve opposite corner" (position acknowledged == (248,194))
  assert "late actual dimensions settle after release" (position late == (256,202))
  assert "next pointer move starts at displayed geometry"
    (rect (step (PointerMoved 3 10 10) (start 0 late)) == Rect 266 212 344 248)
  assert "keyboard movement starts at displayed geometry"
    (rect (act (MoveDirection GoRight) late) == Rect 266 202 344 248)
  assert "keyboard resize starts at displayed geometry"
    (rect (act (Resize Width 10) late) == Rect 251 202 354 248)
  let other = step (WindowActualSize 20 400 300) (act ToggleFloat (step (WindowAdded 20) late))
      otherMoved = act (MoveDirection GoRight) other
      lateOther = step (WindowActualSize 10 336 240) otherMoved
  assert "unrelated window geometry retains pending anchor" (position lateOther == (264,210))
  let hidden = act (View 2) late
      visible = act (View 1) hidden
  assert "hidden target retains last displayed rectangle" (rect visible == Rect 256 202 344 248)
  let fixed = step (WindowActualSize 10 204 104) (step (WindowSizeHints 10 200 100 200 100) base)
  assert "fixed-size hints" (let r = rect (step (PointerMoved 3 100 100) (start 10 fixed)) in rectWidth r == 204 && rectHeight r == 104)
  let impossibleHints = step (WindowSizeHints 10 (fromIntegral (maxBound :: Int32)) (fromIntegral (maxBound :: Int32)) 0 0) base
      boundedHints = step (PointerMoved 3 20 20) (start 5 impossibleHints)
  assert "impossible minima cannot displace the fixed opposite edge" (rect boundedHints == Rect 0 0 400 300)
  assert "unknown actual dimensions rejected" (pointerOperation (start 0 (act ToggleFloat (step (WindowAdded 10) (step (OutputUpsert 7 (Rect 0 0 800 600)) (initialPolicy defaultConfig))))) == Nothing)
  forM_ [act Sink base, act ToggleFullscreen base, act (View 2) base, step Locked base] $ \p ->
    assert "ineligible target rejected" (pointerOperation (start 0 p) == Nothing)
  forM_ [WindowRemoved 10, OutputRemoved 7, OutputUpsert 7 (Rect 0 0 900 600),
    OutputWorkArea 7 (Rect 0 30 800 570), Locked, WindowFullscreen 10 True,
    WindowSizeHints 10 10 10 500 500, WindowAdded 20,
    ActionRequested Sink, ActionRequested (View 2), ActionRequested (Shift 2),
    ActionRequested FocusNext, ActionRequested (Resize Width 10), PointerCancelled 3] $ \event ->
      assert ("operation cancellation " ++ show event) (pointerOperation (step event (start 0 base)) == Nothing)
  let running = start 0 base; command = Command "echo" ["pointer-safe"]
      (spawned,effects) = handleEvent defaultConfig (ActionRequested (RunCommand command)) running
  assert "ordinary commands preserve operation" (pointerOperation spawned == pointerOperation running && effects == [Spawn command])
  assert "unchanged output geometry preserves operation" (pointerOperation (step (OutputUpsert 7 (Rect 0 0 800 600)) running) == pointerOperation running)
  let extreme = step (PointerMoved 3 minBound maxBound) (start 5 base)
  assert "extreme input remains signed-ABI-safe" (all (\n -> toInteger n >= toInteger (minBound :: Int32) && toInteger n <= toInteger (maxBound :: Int32))
    [rectX (rect extreme), rectY (rect extreme), rectWidth (rect extreme), rectHeight (rect extreme)])
  assert "removed windows discard actual dimensions" (Map.null (pointerActualSizes (step (WindowRemoved 10) base)))
  assert "actual size from removed window is ignored"
    (Map.null (pointerActualSizes (step (WindowActualSize 10 400 300) (step (WindowRemoved 10) base))))
  let panel = step (WindowActualSize 10 300 200) (step (OutputWorkArea 7 (Rect 100 50 600 500)) base)
  assert "offset workarea bounds" (rect (step (PointerMoved 3 maxBound minBound) (start 0 panel)) == Rect 400 50 300 200)
  let negativeOutput = step (WindowActualSize 10 400 300) (step (OutputUpsert 7 (Rect (-800) (-600) 800 600)) base)
  assert "negative output coordinates" (rect (step (PointerMoved 3 (-20) 30) (start 0 negativeOutput)) == Rect (-620) (-420) 400 300)
  stress
  putStrLn "Pointer policy: ABI, cumulative motion, edges, actual-size anchoring, hints, bounds and lifecycle tests passed."
