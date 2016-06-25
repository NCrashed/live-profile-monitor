module Profile.Live(
  -- * Options
    LiveProfileOpts
  , defaultLiveProfileOpts
  -- * Basic API
  , LiveProfiler
  , initLiveProfile
  , stopLiveProfile
  , pauseLiveProfile
  ) where 

import Control.Concurrent
import Control.Monad.IO.Class
import Data.IORef 
import System.Log.FastLogger

import Profile.Live.Options 
import Profile.Live.Parser 
import Profile.Live.Server
import Profile.Live.State 

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: MonadIO m => LiveProfileOpts -> LoggerSet -> m LiveProfiler
initLiveProfile opts eventLogger = liftIO $ do
  eventLogPause <- newIORef False
  eventLogTerminate <- newEmptyMVar
  eventLogPipeThreadTerm <- newEmptyMVar
  eventLogPipeThread <- redirectEventlog eventLogger opts eventLogTerminate eventLogPipeThreadTerm eventLogPause
  eventLogServerThreadTerm <- newEmptyMVar
  eventLogServerThread <- startLiveServer eventLogger opts eventLogTerminate eventLogServerThreadTerm 
  return LiveProfiler {..}

-- | Destroy live profiler.
--
-- The function closes all sockets, stops all related threads and
-- restores eventlog sink. 
stopLiveProfile :: MonadIO m => LiveProfiler -> m ()
stopLiveProfile LiveProfiler{..} = liftIO $ do 
  logProf eventLogger "Terminating"
  putMVar eventLogTerminate ()
  _ <- takeMVar eventLogPipeThreadTerm
  _ <- takeMVar eventLogServerThreadTerm
  logProf eventLogger "Terminated"

-- | Pause live profiler. Temporally disables event sending to
-- remote host, but still maintains internal state of the eventlog.
pauseLiveProfile :: MonadIO m => LiveProfiler -> Bool -> m ()
pauseLiveProfile LiveProfiler{..} flag = liftIO $ do
  if flag then logProf eventLogger "Paused"
    else logProf eventLogger "Unpaused"
  atomicWriteIORef eventLogPause flag