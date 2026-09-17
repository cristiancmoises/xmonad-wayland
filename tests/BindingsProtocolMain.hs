module Main (main) where

import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Keymap
import XMonad.Wayland.Runtime (runWithReload)
import XMonad.Wayland.Types

main :: IO ()
main = do
  python <- fromMaybe "python3" <$> lookupEnv "PYTHON"
  scenario <- fromMaybe "bindings" <$> lookupEnv "XW_PROTOCOL_CASE"
  let cfg = defaultConfig
        { cursorTheme = if scenario == "unsupported-exit" then Nothing else Just "fixture-theme"
        , cursorSize = 42
        , keyBindings = defaultKeyBindings ++
            [ key (keySym 'r') super (EnterMode ResizeMode)
            , modeKey ResizeMode keyLeft 0 FocusNext
            , modeKey ResizeMode keyReturn 0 (EnterMode NormalMode)
            , key (keySym 'c') super Reload
            , key (keySym 'e') super (ConfirmExit (Command python
                ["-c", "import sys; assert sys.stdin.read() == 'Cancel\\nExit\\n'; print('Exit')"]))
            ] }
      updated = cfg {keyBindings = keyBindings cfg ++ [key (keySym 'x') super FocusPrevious]}
  runWithReload cfg (pure updated)
