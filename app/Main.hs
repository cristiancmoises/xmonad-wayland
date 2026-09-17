module Main (main) where

import System.Environment (getArgs)
import System.Exit (die)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Runtime (run)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> run defaultConfig
    ["--version"] -> putStrLn "xmonad-wayland 0.2.0-dev (experimental River window manager)"
    ["--help"] -> putStrLn $ unlines
      [ "Usage: xmonad-wayland [--version | --help]"
      , "Run inside River >= 0.4. River classic/0.3 is incompatible."
      , "Configuration: compile a custom Main using XMonad.Wayland.Config and Runtime."
      ]
    _ -> die "Usage: xmonad-wayland [--version | --help]"
