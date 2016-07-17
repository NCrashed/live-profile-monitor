module Profile.Live(
  -- * Options
  -- ** Server side
    LiveProfileOpts
  , defaultLiveProfileOpts
  , eventLogChunkSize
  , eventLogListenPort
  , eventChannelMaximumSize
  , eventMessageMaxSize
  -- ** Client side
  , LiveProfileClientOpts
  , defaultLiveProfileClientOpts
  , clientTargetAddr
  , clientMessageTimeout
  -- * Basic API
  , LiveProfiler
  , initLiveProfile
  , stopLiveProfile
  , pauseLiveProfile
  ) where 

import Control.Concurrent
import Control.Concurrent.STM.TBMChan
import Control.Monad.IO.Class
import Data.IORef 
import System.Log.FastLogger

import Profile.Live.Hidden 
import Profile.Live.Options 
import Profile.Live.Parser 
import Profile.Live.Server
import Profile.Live.State 
import Profile.Live.Termination 

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: MonadIO m => LiveProfileOpts -> LoggerSet -> m LiveProfiler
initLiveProfile opts eventLogger = liftIO $ do
  eventLogPause <- newIORef False
  eventLogTerminate <- newEmptyMVar
  let maxSize = maybe maxBound fromIntegral $ eventChannelMaximumSize opts
  eventTypeChan <- newTBMChanIO maxSize
  eventChan <- newTBMChanIO maxSize
  eventLogPipeThreadTerm <- newEmptyMVar
  eventLogPipeThread <- redirectEventlog eventLogger opts (eventLogTerminate, eventLogPipeThreadTerm)
    eventTypeChan eventChan

  let hiddenSet = if eventHideMonitorActivity opts
        then eventLogPipeThread `addToHiddenSet` emptyHiddenSet
        else emptyHiddenSet
  eventLogServerThreadTerm <- newEmptyMVar
  eventLogServerThread <- startLiveServer eventLogger opts (eventLogTerminate, eventLogServerThreadTerm)
    eventLogPause eventTypeChan eventChan hiddenSet
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