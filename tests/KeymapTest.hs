module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Keymap
import XMonad.Wayland.Types

assert :: String -> Bool -> IO ()
assert name result = unless result (error name)

main :: IO ()
main = do
  let custom = [key keyReturn super (RunCommand (Command "terminal" ["a b"]))
               , modeKey ResizeMode keyReturn 0 (EnterMode NormalMode)]
  assert "custom commands retain literal arguments through indexed dispatch"
    (bindingAt custom NormalMode 0 == Just (RunCommand (Command "terminal" ["a b"])))
  assert "events from inactive modes cannot invoke actions"
    (bindingAt custom NormalMode 1 == Nothing
      && bindingAt custom ResizeMode 0 == Nothing
      && bindingAt custom ResizeMode 1 == Just (EnterMode NormalMode))
  assert "out-of-range binding indices are ignored"
    (bindingAt custom NormalMode 2 == Nothing
      && bindingAt custom NormalMode maxBound == Nothing)
  assert "duplicate keys fail validation before connecting to River"
    (isLeft (validateKeyBindings [key 97 super Close, key 97 super Terminal]))
  assert "one chord can have different meanings in separate modes"
    (validateKeyBindings [key 97 super Close, modeKey ResizeMode 97 super Terminal] == Right ())
  assert "invalid keys and undefined modifier bits are rejected"
    (isLeft (validateKeyBindings [key 0 super Close])
      && isLeft (validateKeyBindings [key 97 256 Close]))
  assert "portable default keymap validates"
    (validateKeyBindings defaultKeyBindings == Right ())
  assert "workspace targets must exist before bindings are installed"
    (isLeft (validateConfig defaultConfig {keyBindings = [key 48 (super + shift) (Shift 10)]})
      && validateConfig defaultConfig {workspaceIds = [1..10], keyBindings = [key 48 (super + shift) (Shift 10)]} == Right ())
  assert "workspace lists must be positive unique and nonempty"
    (all (isLeft . validateConfig) [defaultConfig {workspaceIds = []}
      , defaultConfig {workspaceIds = [1,1]}, defaultConfig {workspaceIds = [0,1]}])
  putStrLn "Keymap validation, configurable dispatch and mode isolation tests passed."
