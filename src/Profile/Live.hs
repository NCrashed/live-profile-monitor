{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}
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

import Profile.Live.Options 
import Profile.Live.Parser 
import Profile.Live.State 

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: MonadIO m => LiveProfileOpts -> m LiveProfiler
initLiveProfile opts = liftIO $ do
  eventLogPause <- newIORef False
  eventLogTerminate <- newEmptyMVar
  eventLogPipeThreadTerm <- newEmptyMVar
  eventLogPipeThread <- redirectEventlog opts eventLogTerminate eventLogPipeThreadTerm eventLogPause
  return LiveProfiler {..}

-- | Destroy live profiler.
--
-- The function closes all sockets, stops all related threads and
-- restores eventlog sink. 
stopLiveProfile :: MonadIO m => LiveProfiler -> m ()
stopLiveProfile LiveProfiler{..} = liftIO $ do 
  putMVar eventLogTerminate ()
  _ <- takeMVar eventLogPipeThreadTerm
  return ()

-- | Pause live profiler. Temporally disables event sending to
-- remote host, but still maintains internal state of the eventlog.
pauseLiveProfile :: MonadIO m => LiveProfiler -> Bool -> m ()
pauseLiveProfile LiveProfiler{..} flag = liftIO $
  atomicWriteIORef eventLogPause flag