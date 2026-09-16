{-# LANGUAGE ForeignFunctionInterface #-}

-- | The C bridge owns Wayland handles; this module owns policy and subprocesses.
module XMonad.Wayland.Runtime (run, xw_event) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Exception (IOException, SomeException, bracket_, catch, displayException, mask_)
import Control.Monad (forM_, unless, void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Word (Word32)
import Foreign.C.Types (CInt(..))
import System.Exit (ExitCode(..), exitWith)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (CreateProcess(..), createProcess, proc, waitForProcess)
import XMonad.Wayland.Policy
import XMonad.Wayland.Protocol (decodeEvent)
import XMonad.Wayland.Types

-- xw_run invokes the foreign-exported Haskell callback. It MUST be safe.
foreign import ccall safe "xw_run" c_run :: IO CInt
foreign import ccall unsafe "xw_set_window" c_setWindow
  :: Word32 -> CInt -> CInt -> CInt -> CInt -> CInt -> CInt -> IO ()
foreign import ccall unsafe "xw_focus" c_focus :: Word32 -> IO ()
foreign import ccall unsafe "xw_close" c_close :: Word32 -> IO ()
foreign import ccall unsafe "xw_stop" c_stop :: IO ()
foreign export ccall xw_event :: Int32 -> Word32 -> Int32 -> Int32 -> Int32 -> Int32 -> IO ()

data Runtime = Runtime
  { runtimeConfig :: !Config
  , runtimePolicy :: !Policy
  , pendingEffects :: ![Effect]
  , callbackFailure :: !(Maybe String)
  }

-- One compositor event thread and one runtime are supported. Child-reaper
-- threads never touch this reference or call into Wayland.
{-# NOINLINE runtimeRef #-}
runtimeRef :: IORef (Maybe Runtime)
runtimeRef = unsafePerformIO (newIORef Nothing)

run :: Config -> IO ()
run cfg = do
  existing <- readIORef runtimeRef
  case existing of
    Just _ -> ioError (userError "xmonad-wayland runtime is already running")
    Nothing -> bracket_
      (writeIORef runtimeRef (Just (Runtime cfg (initialPolicy cfg) [] Nothing)))
      (writeIORef runtimeRef Nothing)
      (do
        result <- c_run
        finalState <- readIORef runtimeRef
        case finalState >>= callbackFailure of
          Just message -> ioError (userError ("Wayland callback failed: " ++ message))
          Nothing -> unless (result == 0) (exitWith (ExitFailure (fromIntegral result))))

-- | No Haskell exception may unwind through a C listener. Log the failure,
-- remember it for the executable's exit status, and stop the bridge cleanly.
xw_event :: Int32 -> Word32 -> Int32 -> Int32 -> Int32 -> Int32 -> IO ()
xw_event kind ident a b c d = dispatch `catch` containFailure
  where
    dispatch = do
      state <- readIORef runtimeRef
      case state of
        Just rt | callbackFailure rt == Nothing ->
          if kind == 7 then manage rt
          else case decodeEvent kind ident a b c d of
            Nothing -> pure ()
            Just ev -> do
              let (p, effects) = handleEvent (runtimeConfig rt) ev (runtimePolicy rt)
              writeIORef runtimeRef (Just rt
                { runtimePolicy = p, pendingEffects = reverse effects ++ pendingEffects rt })
        _ -> pure ()

containFailure :: SomeException -> IO ()
containFailure exception = do
  let message = displayException exception
  modifyIORef' runtimeRef (fmap (\rt -> rt { callbackFailure = Just message }))
  report ("callback failed; stopping: " ++ message)
  c_stop

-- Manage-only requests are emitted exclusively in event 7. Event 8 belongs to
-- C's render phase, which applies saved coordinates and borders.
manage :: Runtime -> IO ()
manage rt = do
  writeIORef runtimeRef (Just rt { pendingEffects = [] })
  forM_ (renderPolicy (runtimePolicy rt)) $ \placement -> do
    let Rect x y w h = placementRect placement
    c_setWindow (placementWindow placement) (boolean (placementVisible placement))
      (bounded x) (bounded y) (bounded w) (bounded h) (boolean (placementFocused placement))
  c_focus (maybe 0 id (focusedWindow (runtimePolicy rt)))
  mapM_ execute (reverse (pendingEffects rt))
  where
    boolean value = if value then 1 else 0
    bounded value = fromIntegral (max (fromIntegral (minBound :: CInt))
      (min (fromIntegral (maxBound :: CInt)) value))

execute :: Effect -> IO ()
execute (CloseWindow wid) = c_close wid
execute StopRuntime = c_stop
execute (Spawn (Command executable arguments)) = spawn `catch` spawnFailure
  where
    spawn = mask_ $ do
      (_, _, _, child) <- createProcess (proc executable arguments)
        { close_fds = True, create_group = True }
      void (forkIOWithUnmask (\unmask -> unmask (void (waitForProcess child)) `catch` spawnFailure))
    spawnFailure :: IOException -> IO ()
    spawnFailure e = report ("cannot run/reap " ++ show executable ++ ": " ++ displayException e)

report :: String -> IO ()
report message = hPutStrLn stderr ("xmonad-wayland: " ++ message) `catch` ignore
  where
    ignore :: SomeException -> IO ()
    ignore _ = pure ()
