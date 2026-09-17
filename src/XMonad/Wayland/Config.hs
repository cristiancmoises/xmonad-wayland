-- | Defaults are separate from the executable; a custom Main can override them.
module XMonad.Wayland.Config (defaultConfig) where

import XMonad.Wayland.Types
import XMonad.Wayland.Keymap (defaultKeyBindings)

defaultConfig :: Config
defaultConfig = Config
  { terminalCommand = Command "foot" []
  , launcherCommand = Command "fuzzel" []
  , initialLayout = Tall
  , initialMasterRatio = 1 / 2
  , resizeIncrement = 3 / 100
  , workspaceIds = [1..9]
  , keyBindings = defaultKeyBindings
  , cursorTheme = Nothing
  , cursorSize = 24
  }
