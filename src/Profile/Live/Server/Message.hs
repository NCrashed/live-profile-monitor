{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Profile.Live.Server.Message(
    ProfileMsg(..)
  , ServiceMsg(..)
  , EventMsg(..)
  , MessageCollector
  ) where 

import Control.DeepSeq
import Data.Time 
import Data.Word 
import GHC.Generics
import GHC.RTS.Events

import qualified Data.ByteString as BS 
import qualified Data.HashMap.Strict as H
import qualified Data.Sequence as S 

-- | Most general type of messages that the monitor generates and understands
--
-- Note: The protocol is designed to be used in both stream based and
-- datagram based transports, so large events could be splitted into several
-- parts to fit into the MTU.
data ProfileMsg = 
    ProfileService {-# UNPACK #-} !ServiceMsg -- ^ Service message
  | ProfileEvent !EventMsg -- ^ Payload message
  deriving (Generic, Show)

-- | Type of messages that controls the monitor behavior
data ServiceMsg =
    ServicePause !Bool -- ^ Command to pause the monitor (client to server)
  deriving (Generic, Show)

-- | Type of messages that carry eventlog datum
data EventMsg = 
    EventHeaderType {-# UNPACK #-} !EventType -- ^ Part of the eventlog header
  -- | Special case for block of events as it can contain large amount of events
  | EventBlockMsgHeader {
      eblockMsgId :: {-# UNPACK #-} !Word64 -- ^ Id of the block that is unique for the session
    , eblockMsgEndTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Time when the block ended
    , eblockMsgCap :: {-# UNPACK #-} !Word32 -- ^ Capability that emitted all the msgs in the block, 0 is global event, 1 is first cap and so on.
    , eblockMsgEventsCount :: {-# UNPACK #-} !Word64 -- ^ Count of substitute msgs that are related to the block
    }
  -- | Wrapper for message that is attached to particular block
  | EventBlockMsg {
      eblockMsgId :: {-# UNPACK #-} !Word64 -- ^ Id of the block that is unique for the session
    , eblockMsgPayload :: !EventMsg -- ^ Message of the block
    }
  | EventMsg {-# UNPACK #-} !Event -- ^ Eventlog event, except the block markers and too large events
  -- | When event is too big to fit into the MTU, it is splited into several parts, it is the first part -- the header of such sequence.
  | EventPartial {
      epartialMsgId :: {-# UNPACK #-} !Word64 -- | Unique id within connection
    , epartialMsgParts :: {-# UNPACK #-} !Word64 -- | How many parts are in the message (not including the message header)
    , epartialMsgPayload :: {-# UNPACK #-} !BS.ByteString -- | Initial part of the message
    }
  | EventPart {
      epartMsgId :: {-# UNPACK #-} !Word64 -- | Unique id within connection, that matches the `epartialMsgId`
    , epartMsgNum :: {-# UNPACK #-} !Word64 -- | Number of the part 
    , epartMsgPayload :: {-# UNPACK #-} !BS.ByteString -- | Payload of the message
    }
  deriving (Generic, Show)

instance NFData EventMsg
instance NFData ServiceMsg
instance NFData ProfileMsg

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

-- | State of message decoder, helps to collect partial and blocked messages into
-- ordinal 'Event'
data MessageCollector = MessageCollector {
    -- | Temporal storage for partial messages with the time tag to be able to discard 
    -- too old messages
    collectorPartials :: !(H.HashMap Word64 (UTCTime, S.Seq (Word64, BS.ByteString)))
    -- | Temporal storage for block messages with the time tag to be able to discard
    -- too old messages
  , collectorBlocks :: !(H.HashMap Word64 (UTCTime, S.Seq (Word64, EventMsg) ))
  } deriving (Show)

-- | Initial state of message collector
emptyMessageCollector :: MessageCollector 
emptyMessageCollector = MessageCollector {
    collectorPartials = H.empty 
  , collectorBlocks = H.empty
  }

