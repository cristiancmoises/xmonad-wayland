module Main (main) where

import BuildInfo (bridgeLibs, bridgeObjects, ghcPath, srcDir)
import Control.Monad (unless)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.Posix.Process (executeFile)
import System.Process (callProcess)
import XMonad.Wayland.Config (defaultConfig)
import XMonad.Wayland.Runtime (run)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> runCompiledOrDefault
    ["--version"] -> putStrLn "xmonad-wayland 0.5.0 (XMonad StackSet policy for River Wayland)"
    ["--recompile"] -> recompile
    ["--help"] -> putStrLn $ unlines
      [ "Usage: xmonad-wayland [--version | --recompile | --help]"
      , "Run inside River >= 0.4. River classic/0.3 is incompatible."
      , "Configuration: compile ~/.xmonad/xmonad.hs with --recompile;"
      , "the manager executes the result automatically on start and restart."
      , "Window picker: mod+v labels windows with letters (a-z, 1-9); press a"
      , "letter to swap it with the focused window. Escape or a click cancels."
      , "Advanced: compile a custom Main using XMonad.Wayland.Config and Runtime."
      ]
    _ -> die "Usage: xmonad-wayland [--version | --recompile | --help]"

-- | Path of the compiled xmonad.hs result, mirroring XMonad's layout.
compiledBinary :: IO FilePath
compiledBinary = do
  home <- lookupEnv "HOME"
  pure (maybe "/nonexistent" (++ "/.xmonad/xmonad-wayland-bin") home)

-- | Like XMonad: if a compiled configuration exists, run it; otherwise run
-- the built-in defaults.
runCompiledOrDefault :: IO ()
runCompiledOrDefault = do
  compiled <- compiledBinary
  exists <- doesFileExist compiled
  if exists
    then do
      arguments <- getArgs
      executeFile compiled True (compiled : arguments) Nothing
    else run defaultConfig

-- | Compile ~/.xmonad/xmonad.hs against the installed sources and write the
-- result to ~/.xmonad/xmonad-wayland-bin.  GHC is taken from $GHC, then from
-- PATH, then from the executable recorded in the package; some store GHCs
-- panic outside their build environment, so a profile GHC wins when present.
recompile :: IO ()
recompile = do
  home <- lookupEnv "HOME"
  let directory = maybe "/nonexistent" (++ "/.xmonad") home
      input = directory ++ "/xmonad.hs"
      output = directory ++ "/xmonad-wayland-bin"
  exists <- doesFileExist input
  unless exists (die ("configuration not found: " ++ input))
  createDirectoryIfMissing True directory
  compiler <- findCompiler
  callProcess compiler $
    [ "--make", input, "-i" ++ srcDir, "-threaded", "-rtsopts"
    , "-outputdir", directory ++ "/xmonad-wayland-build"
    , "-o", output ] ++ bridgeObjects ++ bridgeLibs
  putStrLn ("configuration compiled: " ++ output)
  putStrLn "Restart the manager to run it: mod+Shift+q (session exit) or the restart action."

findCompiler :: IO FilePath
findCompiler = do
  explicit <- lookupEnv "GHC"
  pathOne <- findExecutable "ghc"
  pure $ case explicit of
    Just compiler -> compiler
    Nothing -> maybe ghcPath id pathOne
