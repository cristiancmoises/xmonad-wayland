-- | Sample xmonad.hs for X11 users migrating to Wayland.  Compile it with
-- @xmonad-wayland --recompile@; the manager runs the result automatically.
module Main (main) where

import Data.Bits ((.|.))

import XMonad.Wayland.XConfig

main :: IO ()
main = xmonad $ def
  { modMask    = mod4Mask
  , terminal   = "kitty"
  , workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
  , layoutHook = tall ||| mirror ||| full
  , keys       = [ ((mod4Mask, xK_Return), spawn "kitty")
                 , ((mod4Mask .|. shiftMask, xK_Return), spawn "kitty --hold top")
                 , ((mod4Mask, xK_j), focusNext)
                 , ((mod4Mask, xK_k), focusPrevious)
                 , ((mod4Mask .|. shiftMask, xK_j), swapNext)
                 , ((mod4Mask .|. shiftMask, xK_k), swapPrevious)
                 , ((mod4Mask .|. shiftMask, xK_c), close)
                 , ((mod4Mask, xK_space), nextLayout)
                 , ((mod4Mask, xK_h), shrink)
                 , ((mod4Mask, xK_l), expand)
                 , ((mod4Mask, xK_1), viewWS "1")
                 , ((mod4Mask, xK_2), viewWS "2")
                 , ((mod4Mask .|. shiftMask, xK_q), stop)
                 ]
  , startupHook = [startup "swaybg -i ~/wallpaper.png"]
  }
