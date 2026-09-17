module Main (main) where

import Data.Maybe (fromMaybe)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Keymap (key, keyReturn, keySym, super)
import XMonad.Wayland.Runtime (run, runWithReload)
import XMonad.Wayland.Types

-- The C fixture calls into the real Runtime through its exported ABI. The
-- Python subprocess records argv so shell parsing and child-reaping regressions
-- are observable rather than inferred from the Haskell source.
main :: IO ()
main = do
  arguments <- getArgs
  python <- fromMaybe "python3" <$> lookupEnv "PYTHON"
  case arguments of
    [mode, resultPath, injectedPath] | mode `elem`
      ["normal", "reload", "reload-invalid", "confirm-exit", "confirm-cancel", "confirm-empty", "confirm-fail", "confirm-garbage", "confirm-block", "confirm-ignore-term"] -> do
      marker <- fromMaybe "/nonexistent" <$> lookupEnv "XW_CONFIRM_MARKER"
      let command = Command python
            [ "-c"
            , "import json,sys; open(sys.argv[1],'w').write(json.dumps(sys.argv[2:]))"
            , resultPath
            , "space arg"
            , "$(touch " ++ injectedPath ++ ")"
            , "semi;colon"
            ]
          cfg = defaultConfig {keyBindings =
            [key keyReturn super (RunCommand command), key (keySym 'r') super Reload
            , key (keySym 'e') super (ConfirmExit (Command python
              ["-c", "import os,signal,sys,time; assert sys.stdin.read() == 'Cancel\\nExit\\n'; signal.signal(signal.SIGTERM, signal.SIG_IGN) if sys.argv[2]=='confirm-ignore-term' else None; open(sys.argv[1],'a').write(str(os.getpid())+'\\n'); time.sleep(100 if sys.argv[2] in ['confirm-block','confirm-ignore-term'] else 0.1); sys.stdout.write({'confirm-exit':'Exit\\n','confirm-cancel':'Cancel\\n','confirm-empty':'','confirm-fail':'Exit\\n','confirm-garbage':'Exit\\nextra'}.get(sys.argv[2],'')); sys.exit(1 if sys.argv[2]=='confirm-fail' else 0)", marker, mode]))]}
          next = if mode == "reload-invalid" then cfg {workspaceIds = [1..10]}
            else cfg {keyBindings = [key keyReturn super Close]}
      runWithReload cfg (pure next)
    ["fail"] -> run defaultConfig
      { terminalCommand = Command (error "intentional callback test failure") [] }
    _ -> die "Usage: runtime-test normal RESULT INJECTED | runtime-test fail"
