{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnliftedFFITypes #-}
{-# LANGUAGE TupleSections #-}
module Profile.Live.Hidden(
  -- * Utilities to hide the monitor activity
    HiddenThreadSet
  , emptyHiddenSet
  , addToHiddenSet
  , removeFromHiddenSet
  , isHiddenThread
  , isHiddenEvent
  , hideCurrentThread
  , atomicHideCurrentThread
  ) where 

import Control.Concurrent
import Data.IORef 
import Data.Word 
import Foreign.C.Types 
import GHC.Conc.Sync
import GHC.Prim (ThreadId#)
import GHC.RTS.Events hiding (ThreadId)

import qualified Data.HashSet as H 

-- | Holds info about threads that we want to hide from the eventlog
type HiddenThreadSet = H.HashSet Word32 

-- | Hidden set with zero elements
emptyHiddenSet :: HiddenThreadSet
emptyHiddenSet = H.empty 

class HiddenThread a where 
  -- | Add given thread id to the hidden set
  addToHiddenSet :: a -> HiddenThreadSet -> HiddenThreadSet

  -- | Remove givent thread id from the hidden set
  removeFromHiddenSet :: a -> HiddenThreadSet -> HiddenThreadSet

  -- | Check if the given thread should be hidden from the eventlog
  isHiddenThread :: a -> HiddenThreadSet -> Bool

instance HiddenThread Word32 where 
  addToHiddenSet = H.insert
  removeFromHiddenSet = H.delete
  isHiddenThread = H.member

foreign import ccall unsafe "rts_getThreadId" getThreadId :: ThreadId# -> CInt

threadIdToNum :: Num a => ThreadId -> a 
threadIdToNum (ThreadId i) = fromIntegral $ getThreadId i 

instance HiddenThread ThreadId where 
  addToHiddenSet i = H.insert (threadIdToNum i)
  removeFromHiddenSet i = H.delete (threadIdToNum i)
  isHiddenThread i = H.member (threadIdToNum i)

-- | Check whether the given event contains info about hidden thread
isHiddenEvent :: Event -> HiddenThreadSet -> Bool
isHiddenEvent Event{..} s = case evSpec of 
  CreateThread{..} -> thread `isHiddenThread` s 
  RunThread{..} -> thread `isHiddenThread` s 
  StopThread{..} -> thread `isHiddenThread` s
  ThreadRunnable{..} -> thread `isHiddenThread` s
  MigrateThread{..} -> thread `isHiddenThread` s
  WakeupThread{..} -> thread `isHiddenThread` s
  ThreadLabel{..} -> thread `isHiddenThread` s
  AssignThreadToProcess{..} -> thread `isHiddenThread` s
  SendMessage{..} -> senderThread `isHiddenThread` s
  ReceiveMessage{..} -> senderThread `isHiddenThread` s
  SendReceiveLocalMessage{..} -> senderThread `isHiddenThread` s
  MerReleaseThread{..} -> thread_id `isHiddenThread` s
  _ -> False
  
-- | Add current thread into the set
hideCurrentThread :: HiddenThreadSet -> IO HiddenThreadSet
hideCurrentThread s = do 
  tid <- myThreadId
  return $ addToHiddenSet tid s 

-- | Add current thread into hidden set stored in 'IORef'
atomicHideCurrentThread :: IORef HiddenThreadSet -> IO ()
atomicHideCurrentThread ref = do 
  tid <- myThreadId
  atomicModifyIORef ref $ (, ()) . addToHiddenSet tid 