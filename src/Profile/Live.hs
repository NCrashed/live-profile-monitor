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
  ) where 

import Control.Concurrent

import Profile.Live.Options 
import Profile.Live.Parser 
import Profile.Live.State 

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: LiveProfileOpts -> IO LiveProfiler
initLiveProfile opts = do
  termVar <- newEmptyMVar
  pipeTerm <- newEmptyMVar
  pipeId <- redirectEventlog opts termVar pipeTerm
  return LiveProfiler {
      eventLogPipeThread = pipeId
    , eventLogPipeThreadTerm = pipeTerm
    , eventLogTerminate = termVar
    }

-- | Destroy live profiler.
--
-- The function closes all sockets, stops all related threads and
-- restores eventlog sink. 
stopLiveProfile :: LiveProfiler -> IO ()
stopLiveProfile LiveProfiler{..} = do 
  putMVar eventLogTerminate ()
  _ <- takeMVar eventLogPipeThreadTerm
  return ()