-- Build from the source tree with: make MAIN=examples/Main.hs
-- This API is separate from XMonad's X11 configuration API.
module Main (main) where

import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Runtime (run)
import XMonad.Wayland.Types

main :: IO ()
main = run defaultConfig
  { terminalCommand = Command "foot" ["--app-id=xmonad-terminal"]
  , launcherCommand = Command "fuzzel" []
  , initialLayout = Tall
  , initialMasterRatio = 3 / 5
  , resizeIncrement = 3 / 100
  }
