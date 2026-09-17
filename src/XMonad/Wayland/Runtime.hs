{-# LANGUAGE ForeignFunctionInterface #-}

-- | The C bridge owns Wayland handles; this module owns policy and subprocesses.
module XMonad.Wayland.Runtime (run, runWithReload, readConfig, xw_event, xw_configure_bindings) where

import Control.Concurrent (MVar, ThreadId, forkIOWithUnmask, killThread, newMVar, putMVar, readMVar, threadDelay, tryTakeMVar)
import Control.Exception (IOException, SomeException, bracket, bracket_, catch, displayException, evaluate, finally, mask_, uninterruptibleMask_)
import Control.Monad (forM_, unless, void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Word (Word32)
import Foreign.C.Types (CInt(..))
import Foreign.C.String (CString, withCString)
import System.Exit (ExitCode(..), exitWith)
import System.IO (hClose, hGetContents, hPutStr, hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Process (CreateProcess(..), ProcessHandle, StdStream(..), createProcess, getPid, getProcessExitCode, proc, waitForProcess)
import Text.Read (readEither)
import XMonad.Wayland.Keymap (bindingAt, validateConfig)
import XMonad.Wayland.Policy
import XMonad.Wayland.Protocol (decodeEvent)
import XMonad.Wayland.Types

-- xw_run invokes the foreign-exported Haskell callback. It MUST be safe.
foreign import ccall safe "xw_run" c_run :: IO CInt
foreign import ccall unsafe "xw_set_output" c_setOutput :: Word32 -> IO ()
foreign import ccall unsafe "xw_set_mode" c_setMode
  :: Word32 -> Word32 -> CInt -> CInt -> IO ()
foreign import ccall unsafe "xw_set_window" c_setWindow
  :: Word32 -> CInt -> CInt -> CInt -> CInt -> CInt -> CInt -> IO ()
foreign import ccall unsafe "xw_focus" c_focus :: Word32 -> IO ()
foreign import ccall unsafe "xw_close" c_close :: Word32 -> IO ()
foreign import ccall unsafe "xw_stop" c_stop :: IO ()
foreign import ccall unsafe "xw_add_binding" c_addBinding
  :: Word32 -> Word32 -> Word32 -> Word32 -> IO ()
foreign import ccall unsafe "xw_set_binding_mode" c_setBindingMode :: Word32 -> IO ()
foreign import ccall unsafe "xw_set_pointer_operation" c_setPointerOperation
  :: Word32 -> Word32 -> Word32 -> IO ()
foreign import ccall unsafe "xw_set_render_position" c_setRenderPosition
  :: Word32 -> CInt -> CInt -> IO ()
-- Reset invokes xw_configure_bindings and therefore must be a safe call.
foreign import ccall safe "xw_reset_bindings" c_resetBindings :: IO ()
foreign import ccall unsafe "xw_set_cursor_theme" c_setCursorTheme :: CString -> Word32 -> IO ()
-- This call only writes an atomic flag. The Wayland thread sends the request.
foreign import ccall unsafe "xw_request_exit_session" c_requestExitSession :: IO ()
foreign export ccall xw_event :: Int32 -> Word32 -> Int32 -> Int32 -> Int32 -> Int32 -> IO ()
foreign export ccall xw_configure_bindings :: IO ()

data Runtime = Runtime
  { runtimeConfig :: !Config
  , runtimePolicy :: !Policy
  , pendingEffects :: ![Effect]
  , callbackFailure :: !(Maybe String)
  , reloadConfig :: !(IO Config)
  , confirmationLock :: !(MVar ())
  , confirmationWorker :: !(IORef (Maybe ThreadId))
  }

-- One compositor event thread and one runtime are supported. Child-reaper
-- threads never touch this reference or call into Wayland.
{-# NOINLINE runtimeRef #-}
runtimeRef :: IORef (Maybe Runtime)
runtimeRef = unsafePerformIO (newIORef Nothing)

run :: Config -> IO ()
run cfg = runWithReload cfg (pure cfg)

-- | A declarative Read/Show configuration supports reloading without losing
-- workspace, layout or window state. Invalid replacements retain the old map.
readConfig :: FilePath -> IO Config
readConfig path = do
  contents <- readFile path
  cfg <- either (ioError . userError . ("invalid configuration: " ++)) pure (readEither contents)
  either (ioError . userError) pure (validateConfig cfg)
  pure cfg

runWithReload :: Config -> IO Config -> IO ()
runWithReload cfg loader = do
  either (ioError . userError) pure (validateConfig cfg)
  confirmationGate <- newMVar ()
  worker <- newIORef Nothing
  existing <- readIORef runtimeRef
  case existing of
    Just _ -> ioError (userError "xmonad-wayland runtime is already running")
    Nothing -> bracket_
      (writeIORef runtimeRef (Just (Runtime cfg (initialPolicy cfg) [] Nothing loader confirmationGate worker)))
      (do
        readIORef worker >>= mapM_ killThread
        readMVar confirmationGate
        writeIORef runtimeRef Nothing)
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
          else if kind == 8 then render rt
          else case if kind == 20
              then ActionRequested <$> bindingAt (keyBindings (runtimeConfig rt))
                (activeMode (runtimePolicy rt)) ident
              else decodeEvent kind ident a b c d of
            Nothing -> pure ()
            Just ev -> do
              let (p, effects) = handleEvent (runtimeConfig rt) ev (runtimePolicy rt)
              writeIORef runtimeRef (Just rt
                { runtimePolicy = p, pendingEffects = reverse effects ++ pendingEffects rt })
        _ -> pure ()

xw_configure_bindings :: IO ()
xw_configure_bindings = configure `catch` containFailure
  where
    configure = do
      state <- readIORef runtimeRef
      case state of
        Just rt | callbackFailure rt == Nothing -> do
          let cfg = runtimeConfig rt
          forM_ (cursorTheme cfg) $ \theme ->
            withCString theme (\name -> c_setCursorTheme name (cursorSize cfg))
          forM_ (zip [0..] (keyBindings (runtimeConfig rt))) $ \(index, binding) ->
            c_addBinding (bindingKeysym binding) (bindingModifiers binding) index
              (fromIntegral (fromEnum (bindingMode binding)))
        _ -> pure ()

containFailure :: SomeException -> IO ()
containFailure exception = do
  let message = displayException exception
  modifyIORef' runtimeRef (fmap (\rt -> rt { callbackFailure = Just message }))
  report ("callback failed; stopping: " ++ message)
  c_stop

-- Event 8 may only correct anchored positions using acknowledged client sizes.
render :: Runtime -> IO ()
render rt = forM_ (renderPointerPositions (runtimePolicy rt)) $ \(wid, x, y) ->
  c_setRenderPosition wid (boundedCoordinate x) (boundedCoordinate y)

boundedCoordinate :: Int -> CInt
boundedCoordinate value = fromIntegral (max (fromIntegral (minBound :: CInt))
  (min (fromIntegral (maxBound :: CInt)) value))

-- Manage-only requests are emitted exclusively in event 7.
manage :: Runtime -> IO ()
manage rt = do
  writeIORef runtimeRef (Just rt { pendingEffects = [] })
  c_setBindingMode (fromIntegral (fromEnum (activeMode (runtimePolicy rt))))
  case pointerOperation (runtimePolicy rt) of
    Nothing -> c_setPointerOperation 0 0 0
    Just operation -> c_setPointerOperation (pointerSeat operation)
      (pointerWindow operation) (pointerEdges operation)
  c_setOutput (maybe 0 id (focusedOutput (runtimePolicy rt)))
  forM_ (renderPolicy (runtimePolicy rt)) $ \placement -> do
    let Rect x y w h = placementRect placement
    c_setMode (placementWindow placement) (maybe 0 id (placementOutput placement))
      (boolean (placementFloating placement)) (boolean (placementFullscreen placement))
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
execute (ConfirmSessionExit (Command executable arguments)) = mask_ $ do
  state <- readIORef runtimeRef
  case state of
    Nothing -> pure ()
    Just rt -> do
      acquired <- tryTakeMVar (confirmationLock rt)
      forM_ acquired $ \() -> do
        worker <- forkIOWithUnmask $ \unmask ->
          unmask (confirm `catch` confirmationFailure)
            `finally` putMVar (confirmationLock rt) ()
        writeIORef (confirmationWorker rt) (Just worker)
  where
    confirm = bracket
      (createProcess (proc executable arguments)
        { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit
        , close_fds = True, create_group = True })
      (\(input, output, _, child) -> stopConfirmation child `finally` do
        mapM_ (\handle -> hClose handle `catch` ignoreClose) input
        mapM_ (\handle -> hClose handle `catch` ignoreClose) output)
      (\(input, output, _, child) -> case (input, output) of
        (Just writeHandle, Just readHandle) -> do
          hPutStr writeHandle "Cancel\nExit\n"
          hClose writeHandle
          answer <- hGetContents readHandle
          void (evaluate (length answer))
          status <- waitForProcess child
          if status == ExitSuccess && answer == "Exit\n" then c_requestExitSession else pure ()
        _ -> ioError (userError "confirmation process has no pipes"))
    ignoreClose :: IOException -> IO ()
    ignoreClose _ = pure ()
    confirmationFailure :: IOException -> IO ()
    confirmationFailure e = report ("session exit confirmation failed: " ++ displayException e)
execute ReloadConfig = reload `catch` reloadFailure
  where
    reload = do
      state <- readIORef runtimeRef
      case state of
        Nothing -> pure ()
        Just rt -> do
          cfg <- reloadConfig rt
          either (ioError . userError) pure (validateConfig cfg)
          unless (workspaceIds cfg == workspaceIds (runtimeConfig rt))
            (ioError (userError "workspaceIds cannot change during reload"))
          writeIORef runtimeRef (Just rt {runtimeConfig = cfg})
          c_resetBindings
          c_setBindingMode (fromIntegral (fromEnum (activeMode (runtimePolicy rt))))
          report "configuration reloaded"
    reloadFailure :: SomeException -> IO ()
    reloadFailure e = report ("configuration reload rejected: " ++ displayException e)
execute (Spawn (Command executable arguments)) = spawn `catch` spawnFailure
  where
    spawn = mask_ $ do
      (_, _, _, child) <- createProcess (proc executable arguments)
        { close_fds = True, create_group = True }
      void (forkIOWithUnmask (\unmask -> unmask (void (waitForProcess child)) `catch` spawnFailure))
    spawnFailure :: IOException -> IO ()
    spawnFailure e = report ("cannot run/reap " ++ show executable ++ ": " ++ displayException e)

-- Confirmation children own a process group. Keep the leader unreaped until
-- escalation so its PID cannot be reused while signaling that group, including
-- descendants that outlive a leader which accepts SIGTERM. Normal completed
-- confirmations have already been reaped and must not receive more signals.
stopConfirmation :: ProcessHandle -> IO ()
stopConfirmation child = do
  reaped <- uninterruptibleMask_ $ do
    processId <- getPid child
    forM_ processId $ \group -> do
      signalProcessGroup sigTERM group `catch` ignoreSignal
      threadDelay 250000
      signalProcessGroup sigKILL group `catch` ignoreSignal
    pollExit 100
  unless reaped $ do
    -- A task stuck in the kernel can delay even SIGKILL. Keep shutdown bounded
    -- while retaining a waiter that never accesses runtime or Wayland state.
    void (forkIOWithUnmask (\unmask -> unmask (void (waitForProcess child))
      `catch` ignoreSignal))
    report "confirmation child did not exit after SIGKILL; reaping asynchronously"
  where
    ignoreSignal :: IOException -> IO ()
    ignoreSignal _ = pure ()
    pollExit :: Int -> IO Bool
    pollExit remaining = do
      status <- getProcessExitCode child
      case status of
        Just _ -> pure True
        Nothing | remaining <= 0 -> pure False
        Nothing -> threadDelay 10000 >> pollExit (remaining - 1)

report :: String -> IO ()
report message = hPutStrLn stderr ("xmonad-wayland: " ++ message) `catch` ignore
  where
    ignore :: SomeException -> IO ()
    ignore _ = pure ()
