{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
module Profile.Live.Server.Message(
    ProfileMsg(..)
  , ServiceMsg(..)
  , HeaderMsg(..)
  , EventMsg(..)
  , EventBlockMsg(..)
  , EventMsgPartial(..)
  , EventBlockMsgData(..)
  , EventPartialData(..)
  -- * Helpers for the protocol users
  , capToGhcEvents
  , capFromGhcEvents
  ) where 
 
import Control.DeepSeq
import Data.Binary.Serialise.CBOR 
import Data.Word 
import GHC.Generics
import GHC.RTS.Events

import qualified Data.ByteString as BS

-- | Most general type of messages that the monitor generates and understands
--
-- Note: The protocol is designed to be used in both stream based and
-- datagram based transports, so large events could be splitted into several
-- parts to fit into the MTU.
--
-- Note: the datagram implementation should support delivery guarantees 
data ProfileMsg = 
    ProfileService {-# UNPACK #-} !ServiceMsg -- ^ Service message
  | ProfileHeader !HeaderMsg -- ^ Header message
  | ProfileEvent !EventMsg -- ^ Payload message
  deriving (Generic, Show)

-- | Type of messages that controls the monitor behavior
data ServiceMsg =
    ServicePause !Bool -- ^ Command to pause the monitor (client to server)
  deriving (Generic, Show)

-- | Messages about eventlog header
data HeaderMsg = 
    HeaderLength {-# UNPACK #-} !Word64
  | HeaderType {-# UNPACK #-} !BS.ByteString
  deriving (Generic, Show)

-- | Type of messages that carry eventlog datum
data EventMsg = 
    EventBlockMsg !EventBlockMsg -- ^ Chunked portion of events
  | EventMsg !EventMsgPartial -- ^ Possibly partial message
  deriving (Generic, Show)

-- | Special case for block of events as it can contain large amount of events
data EventBlockMsg = 
  -- | Header of the block
    EventBlockMsgHeader {-# UNPACK #-} !EventBlockMsgData
  -- | Wrapper for message that is attached to particular block
  | EventBlockMsgPart {
      eblockMsgId :: {-# UNPACK #-} !Word64 -- ^ Id of the block that is unique for the session
    , eblockMsgPayload :: !EventMsgPartial -- ^ Message of the block
    }
  deriving (Generic, Show)

-- | Header of event block, extracted from ADT to be able to use as standalone type 
data EventBlockMsgData = EventBlockMsgData {
    eblockMsgDataId :: {-# UNPACK #-} !Word64 -- ^ Id of the block that is unique for the session
  , eblockMsgDataBeginTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Time when the block began
  , eblockMsgDataEndTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Time when the block ended
  , eblockMsgDataCap :: {-# UNPACK #-} !Word32 -- ^ Capability that emitted all the msgs in the block, 0 is global event, 1 is first cap and so on.
  , eblockMsgDataEventsCount :: {-# UNPACK #-} !Word32 -- ^ Count of substitute msgs that are related to the block
  } deriving (Generic, Show)

-- | Subtype of payload messages that can be splitted into several parts
data EventMsgPartial = 
    EventMsgFull {-# UNPACK #-} !BS.ByteString -- ^ Eventlog event, except the block markers and too large events
  -- | When event is too big to fit into the MTU, it is splited into several parts, it is the first part -- the header of such sequence.
  | EventMsgPartial {-# UNPACK #-} !EventPartialData 
  | EventMsgPart {
      epartMsgId :: {-# UNPACK #-} !Word64 -- | Unique id within connection, that matches the `epartialMsgId`
    , epartMsgNum :: {-# UNPACK #-} !Word64 -- | Number of the part 
    , epartMsgPayload :: {-# UNPACK #-} !BS.ByteString -- | Payload of the message
    }
  deriving (Generic, Show)

-- | Header of partial event message, extracted from ADT to be able to use as standalone type 
data EventPartialData = EventPartialData {
    epartialMsgId :: {-# UNPACK #-} !Word64 -- | Unique id within connection
  , epartialMsgParts :: {-# UNPACK #-} !Word64 -- | How many parts are in the messages
  } deriving (Generic, Show)

instance NFData EventMsg
instance NFData ServiceMsg
instance NFData HeaderMsg
instance NFData ProfileMsg
instance NFData EventBlockMsg
instance NFData EventBlockMsgData
instance NFData EventMsgPartial
instance NFData EventPartialData

instance NFData EventType where 
  rnf EventType{..} = num `seq` desc `seq` size `deepseq` ()

instance NFData Event where 
  rnf Event{..} = evTime `seq` evSpec `deepseq` evCap `seq` ()

instance NFData KernelThreadId where 
  rnf (KernelThreadId v) = v `seq` ()

instance NFData EventInfo where 
  rnf e = case e of 
    EventBlock{..} -> end_time `seq` cap `seq` block_size `deepseq` ()
    UnknownEvent{..} -> ref `seq` ()
    Startup{..} -> n_caps `seq` ()
    Shutdown -> ()
    CreateThread{..} -> thread `seq` ()
    RunThread{..} -> thread `seq` ()
    StopThread{..} -> thread `seq` status `seq` ()
    ThreadRunnable{..} -> thread `seq` ()
    MigrateThread{..} -> thread `seq` newCap `seq` ()
    WakeupThread{..} -> thread `seq` otherCap `seq` ()
    ThreadLabel{..} -> thread `seq` threadlabel `seq` ()
    CreateSparkThread{..} -> sparkThread `seq` ()
    SparkCounters{..} -> sparksCreated `seq`
      sparksDud `seq`
      sparksOverflowed `seq`
      sparksConverted `seq`
      sparksFizzled `seq`
      sparksGCd `seq`
      sparksRemaining `seq` ()
    SparkCreate -> ()
    SparkDud -> ()
    SparkOverflow -> ()
    SparkRun -> ()
    SparkSteal{..} -> victimCap `seq` ()
    SparkFizzle -> ()
    SparkGC -> ()
    TaskCreate{..} -> taskId `seq` cap `seq` tid `deepseq` ()
    TaskMigrate{..} -> taskId `seq` cap `seq` new_cap `seq` ()
    TaskDelete{..} -> taskId `seq` ()
    RequestSeqGC -> ()
    RequestParGC -> ()
    StartGC -> ()
    GCWork -> ()
    GCIdle -> ()
    GCDone -> ()
    EndGC -> ()
    GlobalSyncGC -> ()
    GCStatsGHC{..} -> heapCapset `deepseq`
      gen `seq`
      copied `seq`
      slop `seq`
      frag `seq`
      parNThreads `seq`
      parMaxCopied `seq`
      parTotCopied `seq` ()
    HeapAllocated{..} -> heapCapset `deepseq` allocBytes `seq` ()
    HeapSize{..} -> heapCapset `deepseq` sizeBytes `seq` ()
    HeapLive{..} -> heapCapset `deepseq` liveBytes `seq` ()
    HeapInfoGHC{..} -> heapCapset `deepseq` 
      gens `seq`
      maxHeapSize `seq`
      allocAreaSize `seq`
      mblockSize `seq`
      blockSize `seq` ()
    CapCreate{..} -> cap `seq` ()
    CapDelete{..} -> cap `seq` ()
    CapDisable{..} -> cap `seq` ()
    CapEnable{..} -> cap `seq` ()
    CapsetCreate{..} -> capset `deepseq` capsetType `seq` ()
    CapsetDelete{..} -> capset `deepseq` ()
    CapsetAssignCap{..} -> capset `deepseq` cap `seq` ()
    CapsetRemoveCap{..} -> capset `deepseq` cap `seq` ()
    RtsIdentifier{..} -> capset `deepseq` rtsident `deepseq` ()
    ProgramArgs{..} -> capset `deepseq` args `deepseq` ()
    ProgramEnv{..} -> capset `deepseq` env `deepseq` ()
    OsProcessPid{..} -> capset `deepseq` pid `deepseq` ()
    OsProcessParentPid{..} -> capset `deepseq` ppid `deepseq` ()
    WallClockTime{..} -> capset `deepseq` sec `seq` nsec `seq` ()
    Message{..} -> msg `deepseq` ()
    UserMessage{..} -> msg `deepseq` ()
    UserMarker{..} -> markername `deepseq` ()
    Version{..} -> version `deepseq` ()
    ProgramInvocation{..} -> commandline `deepseq` ()
    CreateMachine{..} -> machine `seq` realtime `seq` ()
    KillMachine{..} -> machine `seq` ()
    CreateProcess{..} -> process `seq` ()
    KillProcess{..} -> process `seq` ()
    AssignThreadToProcess{..} -> thread `seq` process `seq` ()
    EdenStartReceive -> ()
    EdenEndReceive -> ()
    SendMessage{..} -> mesTag `seq`
      senderProcess `seq`
      senderThread `seq`
      receiverMachine `seq`
      receiverProcess `seq`
      receiverInport `seq` ()
    ReceiveMessage{..} -> mesTag `seq`
      receiverProcess `seq`
      receiverInport `seq`
      senderMachine `seq`
      senderProcess `seq`
      senderThread `seq` 
      messageSize `seq` ()
    SendReceiveLocalMessage{..} -> mesTag `seq`
      senderProcess `seq`
      senderThread `seq`
      receiverProcess `seq`
      receiverInport `seq` ()
    InternString{..} -> str `deepseq` sId `seq` ()
    MerStartParConjunction{..} -> dyn_id `seq` static_id `seq` ()
    MerEndParConjunction{..} -> dyn_id `seq` ()
    MerEndParConjunct{..} -> dyn_id `seq` ()
    MerCreateSpark{..} -> dyn_id `seq` spark_id `seq` ()
    MerFutureCreate{..} -> future_id `seq` name_id `seq` ()
    MerFutureWaitNosuspend{..} -> future_id `seq` ()
    MerFutureWaitSuspended{..} -> future_id `seq` ()
    MerFutureSignal{..} -> future_id `seq` ()
    MerLookingForGlobalThread -> ()
    MerWorkStealing -> ()
    MerLookingForLocalSpark -> ()
    MerReleaseThread{..} -> thread_id `seq` ()
    MerCapSleeping -> ()
    MerCallingMain -> ()
    PerfName{..} -> perfNum `seq` name `deepseq` ()
    PerfCounter{..} -> perfNum `seq` tid `deepseq` period `seq` ()
    PerfTracepoint{..} -> perfNum `seq` tid `deepseq` ()

instance Serialise ProfileMsg
instance Serialise ServiceMsg
instance Serialise HeaderMsg
instance Serialise EventMsg
instance Serialise EventBlockMsg
instance Serialise EventMsgPartial
instance Serialise EventBlockMsgData
instance Serialise EventPartialData

-- | Convert representation of cap to ghc-events one
capToGhcEvents :: Word32 -> Int 
capToGhcEvents i = fromIntegral i - 1

-- | Convert representation of cap from ghc-events one
capFromGhcEvents :: Int -> Word32 
capFromGhcEvents i 
  | i < 0 = 0 
  | otherwise = fromIntegral i + 1

-- | Convert a GHC event into sequence of datagrams
--eventToMsg :: Word64 -> Word -> Event -> S.Seq EventMsg
--eventToMsg counter maxSize ev = case ev of
--  EventBlock{..} -> S.singleton . EventBlockMsg $ 
--  _ -> msgs 
--  where 
--    payload = runPut (putEvent ev)
--    payloads = accumUnless BS.null (BS.splitAt maxSize payload)
--
--    accumUnless :: (a -> Bool) -> (a -> (b, a)) -> a -> S.Seq b 
--    accumUnless cond f = go S.empty
--      where 
--      go !acc !a = if cond a then acc 
--        else let (!b, a') = f a in go (acc S.|> b) a'