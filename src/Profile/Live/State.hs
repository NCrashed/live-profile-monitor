module Profile.Live.State(
    Termination
  , EventTypeChan
  , EventChan
  , LiveProfiler(..)
  -- * Helpers
  , untilTerminated
  , whenJust
  , logProf
  , logProf'
  -- * Reexports
  , Monoid(..)
  , (<>)
  , LoggerSet
  , LogStr
  , ToLogStr(..)
  , showl
  ) where 

import Control.Concurrent
import Control.Concurrent.STM.TBMChan
import Data.IORef 
import Data.Monoid
import GHC.RTS.Events hiding (ThreadId)
import System.Log.FastLogger

-- | Termination mutex, all threads are stopped when the mvar is filled
type Termination = MVar ()

-- | Channel for eventlog header, closeable and bounded in length
type EventTypeChan = TBMChan EventType 

-- | Channel for eventlog events, closeable and bounded in length
type EventChan = TBMChan Event

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
  -- | Channel between parser and server to transfer initial header to the server side.
  -- If there are too much items (set in options), they are dropped off and the profiler
  -- will spam into logger about the accident.
, eventTypeChan :: !EventTypeChan
  -- | Channel between parser and server to transfer events to the server side.
  -- If there are too much items (set in options), they are dropped off and the profiler
  -- will spam into logger about the accident.
, eventChan :: !EventChan
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

-- | Shorthand for 'toLogStr . show'
showl :: Show a => a -> LogStr
showl = toLogStr . show 
