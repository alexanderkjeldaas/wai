module Network.Wai.Handler.Warp.Timeout (
    Manager
  , Handle
  , initialize
  , register
  , registerKillThread
  , tickle
  , pause
  , resume
  , cancel
  , withManager
  , dummyHandle
  ) where

import Control.Concurrent (forkIO, threadDelay, myThreadId, killThread)
import qualified Control.Exception as E
import Control.Monad (forever, void)
import qualified Data.IORef as I
import System.IO.Unsafe (unsafePerformIO)

-- FIXME implement stopManager

-- | A timeout manager
newtype Manager = Manager (I.IORef [Handle])

-- | A handle used by 'Manager'
--
-- First field is action to be performed on timeout.
data Handle = Handle (IO ()) (I.IORef State)

-- | A dummy @Handle@.
dummyHandle :: Handle
dummyHandle = Handle (return ()) (unsafePerformIO $ I.newIORef Active)

data State = Active | Inactive | Paused | Canceled

initialize :: Int -> IO Manager
initialize timeout = do
    ref <- I.newIORef []
    void . forkIO $ forever $ do
        threadDelay timeout
        ms <- I.atomicModifyIORef ref (\x -> ([], x))
        ms' <- go ms id
        I.atomicModifyIORef ref (\x -> (ms' x, ()))
    return $ Manager ref
  where
    go [] front = return front
    go (m@(Handle onTimeout iactive):rest) front = do
        state <- I.atomicModifyIORef iactive (\x -> (go' x, x))
        case state of
            Inactive -> do
                onTimeout `E.catch` ignoreAll
                go rest front
            Canceled -> go rest front
            _ -> go rest (front . (:) m)
    go' Active = Inactive
    go' x = x

ignoreAll :: E.SomeException -> IO ()
ignoreAll _ = return ()

register :: Manager -> IO () -> IO Handle
register (Manager ref) onTimeout = do
    iactive <- I.newIORef Active
    let h = Handle onTimeout iactive
    I.atomicModifyIORef ref (\x -> (h : x, ()))
    return h

registerKillThread :: Manager -> IO Handle
registerKillThread m = do
    tid <- myThreadId
    register m $ killThread tid

tickle, pause, resume, cancel :: Handle -> IO ()
tickle (Handle _ iactive) = I.writeIORef iactive Active
pause (Handle _ iactive) = I.writeIORef iactive Paused
resume = tickle
cancel (Handle _ iactive) = I.writeIORef iactive Canceled

-- | Call the inner function with a timeout manager.
withManager :: Int -- ^ timeout in microseconds
            -> (Manager -> IO a)
            -> IO a
withManager timeout f = do
    -- FIXME when stopManager is available, use it
    man <- initialize timeout
    f man
