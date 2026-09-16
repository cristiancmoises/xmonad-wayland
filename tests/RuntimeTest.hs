module Main (main) where

import Data.Maybe (fromMaybe)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Runtime (run)
import XMonad.Wayland.Types

-- The C fixture calls into the real Runtime through its exported ABI. The
-- Python subprocess records argv so shell parsing and child-reaping regressions
-- are observable rather than inferred from the Haskell source.
main :: IO ()
main = do
  arguments <- getArgs
  python <- fromMaybe "python3" <$> lookupEnv "PYTHON"
  case arguments of
    ["normal", resultPath, injectedPath] -> run defaultConfig
      { terminalCommand = Command python
        [ "-c"
        , "import json,sys; open(sys.argv[1],'w').write(json.dumps(sys.argv[2:]))"
        , resultPath
        , "space arg"
        , "$(touch " ++ injectedPath ++ ")"
        , "semi;colon"
        ] }
    ["fail"] -> run defaultConfig
      { terminalCommand = Command (error "intentional callback test failure") [] }
    _ -> die "Usage: runtime-test normal RESULT INJECTED | runtime-test fail"
