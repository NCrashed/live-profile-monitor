module Profile.Live.State(
    EventTypeChan
  , EventChan
  , LiveProfiler(..)
  ) where 

import Control.Concurrent
import Control.Concurrent.STM.TBMChan
import Data.IORef 
import Data.Monoid
import GHC.Conc.Sync (labelThread)
import GHC.RTS.Events hiding (ThreadId)
import System.Log.FastLogger

import Profile.Live.Termination

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