-- | Pure tests for the xmonad.hs compatibility surface.
module Main (main) where

import Control.Monad (unless)
import System.Exit (exitFailure)
import XMonad.Wayland.Keymap (validateConfig)
import XMonad.Wayland.Types
import XMonad.Wayland.XConfig

main :: IO ()
main = do
  check "def converts to a valid internal config" $
    either (const False) (const True) (toConfig def)
  check "def keeps nine numeric workspaces" $
    either (const False) ((== map show [1..9]) . map show . workspaceIds) (toConfig def)
  check "def defaults to mod4Mask" $
    modMask def == mod4Mask
  check "def cycles Tall, Mirror, Full" $
    either (const False) ((== [Tall, Mirror, Full]) . layoutCycle) (toConfig def)
  check "custom terminal is honored" $
    case toConfig def { terminal = "kitty" } of
      Left _ -> False
      Right cfg -> terminalCommand cfg == Command "kitty" []
  check "custom workspace labels map to ids in order" $
    case toConfig def { workspaces = ["1", "2", "3"] } of
      Left _ -> False
      Right cfg -> workspaceIds cfg == [1, 2, 3]
  check "layout chain tall ||| full is preserved" $
    case toConfig def { layoutHook = tall ||| full } of
      Left _ -> False
      Right cfg -> initialLayout cfg == Tall && layoutCycle cfg == [Tall, Full]
  check "viewWS maps numeric tags" $
    viewWS "3" == View 3
  check "shiftWS maps numeric tags" $
    shiftWS "2" == Shift 2
  check "spawn wraps commands in /bin/sh -c" $
    spawn "kitty -e tmux" == RunCommand (Command "/bin/sh" ["-c", "kitty -e tmux"])
  check "custom keys appear as normal-mode bindings" $
    case toConfig def { keys = [((mod4Mask, xK_Return), spawn "kitty")] } of
      Left _ -> False
      Right cfg -> keyBindings cfg ==
        [KeyBinding xK_Return mod4Mask NormalMode (spawn "kitty")]
  check "restart, reload and stop actions exist" $
    restart == Restart && reload == Reload && stop == Stop
  check "def passes validation including chord uniqueness" $
    either (const False) (const True) (toConfig def >>= validateConfig)
  check "non-numeric workspace tags are rejected" $
    case toConfig def { workspaces = ["web", "2"] } of
      Left _ -> True
      Right _ -> False
  check "duplicate workspace tags are rejected" $
    case toConfig def { workspaces = ["1", "1"] } of
      Left _ -> True
      Right _ -> False
  check "bindings to unknown workspaces are rejected" $
    case toConfig def { workspaces = ["1", "2"]
                      , keys = [((mod4Mask, xK_1), viewWS "7")] } of
      Left _ -> False
      Right cfg -> case validateConfig cfg of
        Left _ -> True
        Right () -> False
  putStrLn "XConfigTest: all checks passed"

check :: String -> Bool -> IO ()
check label condition =
  unless condition $ do
    putStrLn ("XConfigTest FAILED: " ++ label)
    exitFailure
