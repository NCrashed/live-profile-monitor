{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Protocol.State.Task
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Utilities to watch only tasks state of eventlog.
--
------------------------------------------------------------------------------
module Profile.Live.Protocol.State.Task(
    TaskState(..)
  , isTaskEvent
  , TasksState
  , newTasksState
  , updateTasksState
  ) where 

import Control.DeepSeq 
import Data.Binary.Serialise.CBOR 
import GHC.Generics 
import GHC.RTS.Events 

import qualified Data.HashMap.Strict as H 

deriving instance Generic KernelThreadId
instance NFData KernelThreadId
instance Serialise KernelThreadId

-- | State of single task
data TaskState = TaskState {
  taskStateId :: {-# UNPACK #-} !TaskId -- ^ unique id
, taskStateCap :: {-# UNPACK #-} !Int -- ^ current cap
, taskStateTid :: {-# UNPACK #-} !KernelThreadId -- ^ kernel thread (ffi call)
, taskStateTimestamp :: {-# UNPACK #-} !Timestamp -- ^ creation timestamp
, taskStateLastTimestamp :: {-# UNPACK #-} !Timestamp -- ^ last change (migration) timestamp
} deriving (Generic, Show)

instance NFData TaskState 
instance Serialise TaskState

-- | Return 'True' only if the event related to a task
isTaskEvent :: Event -> Bool 
isTaskEvent e = case evSpec e of 
  TaskCreate{} -> True 
  TaskMigrate{} -> True 
  TaskDelete{} -> True 
  _ -> False 

-- | Extract task id from event
getEventTaskId :: Event -> Maybe TaskId 
getEventTaskId e = case evSpec e of 
  TaskCreate{..} -> Just taskId 
  TaskMigrate{..} -> Just taskId 
  TaskDelete{..} -> Just taskId 
  _ -> Nothing 

-- | Create new record about task state
newTaskState :: TaskId -- ^ unique id
  -> Timestamp -- ^ creation timestamp
  -> Int -- ^ Parent cap
  -> KernelThreadId -- ^ External thread id
  -> TaskState
newTaskState i t cap tid = TaskState {
    taskStateId = i 
  , taskStateCap = cap 
  , taskStateTid = tid 
  , taskStateTimestamp = t 
  , taskStateLastTimestamp = t
  }

-- | Update a task state with given event, doesn't chekc whether the id of task conform with current state's one
updateTaskState :: Event -> TaskState -> TaskState 
updateTaskState e ts = case evSpec e of 
  TaskMigrate{..} -> ts {
      taskStateCap = new_cap 
    , taskStateLastTimestamp = evTime e 
    }
  _ -> ts 

-- | Accumulative state of all known tasks
type TasksState = H.HashMap TaskId TaskState 

-- | New empty tasks state
newTasksState :: TasksState 
newTasksState = H.empty 

-- | Update tasks state with given event
--
-- Tracks as single task states, as creation/deletion of tasks
updateTasksState :: Event -> TasksState -> TasksState 
updateTasksState e tss = case getEventTaskId e of 
  Nothing -> tss 
  Just i -> case evSpec e of 
    TaskCreate{..} -> H.insert i (newTaskState i (evTime e) cap tid) tss
    TaskDelete{} -> H.delete i tss
    _ -> H.adjust (updateTaskState e) i tss