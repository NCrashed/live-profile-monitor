module Profile.Live.State(
    Termination
  , LiveProfiler(..)
  , untilTerminated
  , whenJust
  , logProf
  , logProf'
  -- * Reexports
  , Monoid(..)
  , (<>)
  , LoggerSet
  , ToLogStr(..)
  ) where 

import Control.Concurrent
import Data.IORef 
import Data.Monoid
import System.Log.FastLogger

-- | Termination mutex, all threads are stopped when the mvar is filled
type Termination = MVar ()

-- | Live profiler state
data LiveProfiler = LiveProfiler {
  -- | ID of thread that pipes from memory into incremental parser
  -- and maintains parsed events to keep eye on state of the eventlog.
  eventLogPipeThread :: !ThreadId
  -- | When the pipe thread is ended it fills the mvar
, eventLogPipeThreadTerm :: !Termination
  -- | ID of thread that manages TCP connections to remote profiles 
  -- and manages communication with them.
, eventLogServerThread :: !ThreadId
  -- | When the server thread is ended it fills the mvar
, eventLogServerThreadTerm :: !Termination
  -- | Termination mutex, all threads are stopped when the mvar is filled
, eventLogTerminate :: !Termination
  -- | Holds flag of pause state, if paused, no events are sent to remote hosts,
  -- but internal eventlog state is still maintained.
, eventLogPause :: !(IORef Bool)
  -- | Where we log about live profiler progress and errors
, eventLogger :: !LoggerSet
}

-- | Do action until the mvar is not filled
untilTerminated :: Termination -> a -> (a -> IO a) -> IO ()
untilTerminated termVar a m = do 
  res <- tryReadMVar termVar
  case res of 
    Nothing -> do
      a' <- m a
      untilTerminated termVar a' m
    Just _ -> return ()

whenJust :: Applicative m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing _ = pure ()
whenJust (Just x) m = m x 

-- | Helper to log in live profiler
logProf :: LoggerSet -> LogStr -> IO ()
logProf logger msg = pushLogStrLn logger $ "Live profiler: " <> msg

-- | Helper to log in live profiler, without prefix
logProf' :: LoggerSet -> LogStr -> IO ()
logProf' = pushLogStrLn