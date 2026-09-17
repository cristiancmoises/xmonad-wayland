-- | Decode the bridge's fixed-width C ABI into pure policy events.
module XMonad.Wayland.Protocol (decodeAction, decodeEvent) where

import Data.Int (Int32)
import Data.Word (Word32)
import XMonad.Wayland.Types

decodeAction :: Word32 -> Int32 -> Maybe Action
decodeAction kind argument = case kind of
  1 -> Just FocusNext
  2 -> Just FocusPrevious
  3 -> Just SwapMaster
  4 -> Just NextLayout
  5 -> Just Shrink
  6 -> Just Expand
  7 -> workspace View
  8 -> workspace Shift
  9 -> Just Close
  10 -> Just Terminal
  11 -> Just Launcher
  12 -> Just Stop
  13 -> Just SwapNext
  14 -> Just SwapPrevious
  15 -> Just FocusNextOutput
  16 -> Just FocusPreviousOutput
  17 -> Just ToggleFloat
  18 -> Just ToggleFullscreen
  _ -> Nothing
  where
    workspace constructor
      | argument >= 1 && argument <= 9 = Just (constructor (fromIntegral argument))
      | otherwise = Nothing

decodeEvent :: Int32 -> Word32 -> Int32 -> Int32 -> Int32 -> Int32 -> Maybe Event
decodeEvent kind ident a b c d = case kind of
  1 -> Just (OutputUpsert ident (Rect (fromIntegral a) (fromIntegral b) (fromIntegral c) (fromIntegral d)))
  2 -> Just (OutputRemoved ident)
  3 -> Just (WindowAdded ident)
  4 -> Just (WindowRemoved ident)
  5 -> Just (FocusRequested ident)
  6 -> ActionRequested <$> decodeAction ident a
  9 -> Just Locked
  10 -> Just Unlocked
  11 -> Just (WindowParent ident (if a == 0 then Nothing else Just (fromIntegral a)))
  12 -> Just (WindowSizeHints ident (fromIntegral a) (fromIntegral b) (fromIntegral c) (fromIntegral d))
  13 -> Just (WindowFullscreen ident (a /= 0))
  14 -> Just (OutputWorkArea ident (Rect (fromIntegral a) (fromIntegral b) (fromIntegral c) (fromIntegral d)))
  21 -> Just (PointerStarted (fromIntegral a) ident (fromIntegral b) (fromIntegral c) (fromIntegral d))
  22 -> Just (PointerMoved ident (fromIntegral a) (fromIntegral b))
  23 -> Just (PointerReleased ident)
  24 -> Just (PointerCancelled ident)
  25 -> Just (WindowActualSize ident (fromIntegral a) (fromIntegral b))
  _ -> Nothing
