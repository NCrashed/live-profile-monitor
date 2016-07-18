{-# LANGUAGE StandaloneDeriving #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Server.State.Thread
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Utilities to watch only threads state of eventlog.
--
------------------------------------------------------------------------------
module Profile.Live.Server.State.Thread(
    ThreadExecutionState
  , ThreadState(..)
  , isSparkThread
  , isThreadEvent
  , ThreadsState
  , newThreadsState
  , updateThreadsState
  ) where 

import Control.DeepSeq 
import Data.Binary.Serialise.CBOR 
import Data.Maybe 
import GHC.Generics 
import GHC.RTS.Events 

import qualified Data.HashMap.Strict as H 

deriving instance Generic ThreadStopStatus
instance NFData ThreadStopStatus
instance Serialise ThreadStopStatus

-- | Marker of thread execution state (created, run, stop)
data ThreadExecutionState = 
    ThreadCreated -- ^ Thread is created recently
  | ThreadQueued -- ^ Thread is put into caps queue
  | ThreadRunning -- ^ Thread is running at the moment
  | ThreadStopped !ThreadStopStatus -- ^ Thread is blocked on some reason
  | ThreadMigrated -- ^ Thread was migrated from another cap
  deriving (Generic, Show)

instance NFData ThreadExecutionState
instance Serialise ThreadExecutionState

-- | The full state of single Thread
data ThreadState = ThreadState {
  threadId :: {-# UNPACK #-} !ThreadId -- ^ Id of the thread
, threadLabel :: {-# UNPACK #-} !(Maybe String) -- ^ User can assign names for threads
, threadCap :: {-# UNPACK #-} !Int -- ^ Current capability of the thread (negative means no current cap)
, threadExecution :: {-# UNPACK #-} !ThreadExecutionState -- ^ Execution state
, threadSparkCount :: {-# UNPACK #-} !(Maybe Int) -- ^ How much sparks were processed by the thread
, threadCreationTimestamp :: {-# UNPACK #-} !Timestamp -- ^ When the thread was created
, threadLastTimestamp :: {-# UNPACK #-} !Timestamp -- ^ When the thread state was changed last time
} deriving (Generic, Show)

instance NFData ThreadState
instance Serialise ThreadState

-- | Check whether the thread is special spark worker
isSparkThread :: ThreadState -> Bool 
isSparkThread = isJust . threadSparkCount

-- | Check whether the event refers to threads events
-- TODO: sparks thread specific state
isThreadEvent :: Event -> Bool 
isThreadEvent e = case evSpec e of 
  CreateThread{} -> True
  RunThread{} -> True
  StopThread{} -> True
  ThreadRunnable{} -> True
  MigrateThread{} -> True
  WakeupThread{} -> True
  ThreadLabel{} -> True
  CreateSparkThread{} -> True
  _ -> False 

-- | Check whether the event refers to threads events
-- TODO: sparks thread specific state
getEventThreadId :: Event -> Maybe ThreadId 
getEventThreadId e = case evSpec e of 
  CreateThread{..} -> Just thread
  RunThread{..} -> Just thread
  StopThread{..} -> Just thread
  ThreadRunnable{..} -> Just thread
  MigrateThread{..} -> Just thread
  WakeupThread{..} -> Just thread
  ThreadLabel{..} -> Just thread
  CreateSparkThread{..} -> Just sparkThread
  _ -> Nothing 

-- | Helper to create new thread state
newThreadState :: Timestamp -> ThreadId -> Bool -> ThreadState 
newThreadState t i isSpark = ThreadState {
    threadId = i
  , threadLabel = Nothing
  , threadCap = -1 
  , threadExecution = ThreadCreated
  , threadSparkCount = if isSpark then (Just 0) else Nothing
  , threadCreationTimestamp = t
  , threadLastTimestamp = t
  }

-- | Update thread state with payload of the event, doesn't check thread id actually
updateThreadState :: Event -> ThreadState -> ThreadState
updateThreadState !e !ts = case ei of 
  RunThread{} -> ts' { threadExecution = ThreadRunning }
  StopThread{..} -> ts' { threadExecution = ThreadStopped status }
  ThreadRunnable{} -> ts' { threadExecution = ThreadQueued }
  MigrateThread{..} -> ts' { threadExecution = ThreadMigrated, threadCap = newCap }
  ThreadLabel{..} -> ts { threadLabel = Just threadlabel }
  _ -> ts 
  where 
  t = evTime e 
  ei = evSpec e
  ts' = ts { threadLastTimestamp = t }

-- | Cumulative state of all threads
type ThreadsState = H.HashMap ThreadId ThreadState

-- | New empty threads state
newThreadsState :: ThreadsState
newThreadsState = H.empty 

-- | Update the threads state with given event
updateThreadsState :: Event -> ThreadsState -> ThreadsState 
updateThreadsState !e tss = case getEventThreadId e of 
  Nothing -> tss
  Just i -> case evSpec e of 
    CreateThread{..} -> H.insert i (newThreadState (evTime e) i False) tss
    CreateSparkThread{..} -> H.insert i (newThreadState (evTime e) i True) tss 
    StopThread _ ThreadFinished -> H.delete i tss
    _ -> H.adjust (updateThreadState e) i tss