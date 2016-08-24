-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Protocol.State
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Utilities to watch after eventlog state: alive threads, existing caps and
-- tasks. When new client is connected, we resend relevant events to the remote
-- side. Having relevant state simplifies client work of correct visualization. 
--
------------------------------------------------------------------------------
module Profile.Live.Protocol.State(
    EventlogState(..)
  , newEventlogState
  , updateEventlogState
  , showl
  ) where 

import Control.DeepSeq 
import Data.Binary.Serialise.CBOR
import GHC.Generics 
import GHC.RTS.Events 
import System.Log.FastLogger

import Profile.Live.Protocol.State.Capability
import Profile.Live.Protocol.State.Task
import Profile.Live.Protocol.State.Thread

-- | Shorthand for 'toLogStr . show'
showl :: Show a => a -> LogStr
showl = toLogStr . show 

-- | Storage of all state of eventlog protocol.
--
-- It contains info about threads, caps, tasks, whether
-- GC is performed right now.
data EventlogState = EventlogState {
  -- | Part of state about alive threads
    eventlogThreads :: !ThreadsState 
  -- | Part of state about cap sets and memory stats
  , eventlogCapsets :: !CapsetsState
  -- | Part of state about caps
  , eventlogCaps :: !CapsState 
  -- | Part of state about tasks
  , eventlogTasks :: !TasksState
    -- | If 'Just' the GC is performed and the value contains time of GC begin
  , eventlogGC :: !(Maybe Timestamp)
    -- | Last update timestamp
  , eventlogTime :: !Timestamp
  } deriving (Generic, Show)

instance NFData EventlogState
instance Serialise EventlogState

-- | Initiate new eventlog state
newEventlogState :: EventlogState 
newEventlogState = EventlogState {
    eventlogThreads = newThreadsState
  , eventlogCapsets = newCapsetsState
  , eventlogCaps = newCapsState 
  , eventlogTasks = newTasksState
  , eventlogGC = Nothing
  , eventlogTime = 0
  }

-- | Update state with next event
updateEventlogState :: Event -> EventlogState -> EventlogState
updateEventlogState !e !es 
  | isThreadEvent e = es' { eventlogThreads = updateThreadsState e (eventlogThreads es) }
  | isCapsetEvent e = es' { eventlogCapsets = updateCapsetsState e (eventlogCapsets es) }
  | isCapEvent e = es' { eventlogCaps = updateCapsState e (eventlogCaps es) }
  | isTaskEvent e = es' { eventlogTasks = updateTasksState e (eventlogTasks es) }
  | isGCEvent e = es' { eventlogGC = updateGCState e (eventlogGC es) }
  | otherwise = es 
  where 
  es' = es { eventlogTime = evTime e }

-- | Update current GC state
updateGCState :: Event -> Maybe Timestamp -> Maybe Timestamp
updateGCState Event{..} mt = case evSpec of 
  StartGC -> Just evTime 
  GCWork -> maybe (Just evTime) Just mt
  GCIdle -> maybe (Just evTime) Just mt
  GlobalSyncGC -> maybe (Just evTime) Just mt
  GCDone -> Nothing
  EndGC -> Nothing
  _ -> mt 

-- | Returns 'True' if the event is related to GC
isGCEvent :: Event -> Bool 
isGCEvent e = case evSpec e of 
  RequestSeqGC {} -> True
  RequestParGC {} -> True
  StartGC {} -> True
  GCWork {} -> True
  GCIdle {} -> True
  GCDone {} -> True
  EndGC {} -> True
  GlobalSyncGC {} -> True
  GCStatsGHC {} -> True
  _ -> False