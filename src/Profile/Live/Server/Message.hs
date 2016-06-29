{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
module Profile.Live.Server.Message(
    ProfileMsg(..)
  , ServiceMsg(..)
  , EventMsg(..)
  , EventBlockMsgData(..)
  , EventPartialData(..)
  -- * Helpers for the protocol users
  , MessageCollector
  , emptyMessageCollector
  , stepMessageCollector
  , capToGhcEvents
  , capFromGhcEvents
  ) where 

import Control.DeepSeq
import Control.Monad 
import Control.Monad.State.Class
import Control.Monad.Writer.Class
import Data.Maybe
import Data.Monoid
import Data.Time 
import Data.Word 
import GHC.Generics
import GHC.RTS.Events
import GHC.RTS.EventsIncremental
import System.Log.FastLogger

import qualified Data.ByteString as BS 
import qualified Data.Foldable as F 
import qualified Data.HashMap.Strict as H
import qualified Data.Sequence as S 

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
    EventMsgFull {-# UNPACK #-} !Event -- ^ Eventlog event, except the block markers and too large events
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

-- | State of message decoder, helps to collect partial and blocked messages into
-- ordinal 'Event'
data MessageCollector = MessageCollector {
    -- | Temporal storage for partial messages with the time tag to be able to discard 
    -- too old messages
    collectorPartials :: !(H.HashMap Word64 (UTCTime, Maybe EventPartialData, S.Seq (Word64, BS.ByteString)))
    -- | Temporal storage for block messages with the time tag to be able to discard
    -- too old messages
  , collectorBlocks :: !(H.HashMap Word64 (UTCTime, Maybe EventBlockMsgData, S.Seq Event))
    -- | How long to store partial and blocks messages,
    -- if we don't drop old invalid cache one could attack the monitor with
    -- invalid messages sequence and cause memory leak.
  , collectorTimeout :: !NominalDiffTime
    -- | Holds intermediate state of header that is collected in the first phase of the protocol.
    -- The first word holds info about how many event types we await, the second how many we have 
    -- received.
  , collectorHeader :: !(Maybe Word64, Word64, EventParserState)
  }

instance NFData MessageCollector where 
  rnf MessageCollector{..} = 
    collectorPartials `deepseq` 
    collectorBlocks `deepseq`
    collectorTimeout `deepseq`
    (let (a, b, c) = collectorHeader in a `deepseq` b `seq` c `seq` ()) `seq` ()

-- | Initial state of message collector
emptyMessageCollector :: NominalDiffTime -> MessageCollector 
emptyMessageCollector timeout = MessageCollector {
    collectorPartials = H.empty 
  , collectorBlocks = H.empty
  , collectorTimeout = timeout
  , collectorHeader = (Nothing, 0, newParserState `pushBytes` ("hdrb" <> "hetb")) -- TODO: use constant from ghc-events
  }

-- | Perform one step of converting the profiler protocol into events
stepMessageCollector :: (MonadState MessageCollector m, MonadWriter LogStr m)
  => UTCTime -- ^ Current time
  -> ProfileMsg -- ^ New message arrived
  -> m (Either ServiceMsg (S.Seq Event)) -- ^ Result of decoded events
stepMessageCollector curTime  msg = do
  (maxN, curN, parser) <- gets collectorHeader
  let isPhase1 = isNothing maxN || fromMaybe 0 maxN > curN 
  case msg of
    ProfileService smsg -> return $ Left smsg 
    ProfileHeader hmsg | isPhase1 -> stepHeaderCollector hmsg >> return (Right S.empty)
    ProfileHeader hmsg | otherwise -> do 
      tell "Live profiler: Got header message in second phase.\n"
      stepHeaderCollector hmsg
      return (Right S.empty)
    ProfileEvent emsg -> do
      when isPhase1 $ tell "Live profiler: Got event message in first phase.\n"
      mseq <- stepEventCollector curTime parser emsg
      return $ Right $ fromMaybe mempty mseq

-- | First phase of the collector when we collect header
stepHeaderCollector :: (MonadState MessageCollector m, MonadWriter LogStr m)
  => HeaderMsg -- ^ New message arrived 
  -> m () -- ^ Returns incremental parser ready for events consuming
stepHeaderCollector hmsg = do
  (maxN, curN, parser) <- gets collectorHeader
  case hmsg of 
    HeaderLength n -> do
      when (isJust maxN) . tell $ "Live profiler: Received repeated header initiation message. It's not normal.\n"
      let maxN' = Just n
      modify' $ \mc -> maxN' `seq` mc { collectorHeader = (maxN', curN, parser) }
    HeaderType bs -> do
      case maxN of 
        Just n | n <= curN -> do 
          tell $ "Live profiler: Received excess event type (" 
            <> toLogStr (show $ curN+1) <> "). It's not normal. Event type:" 
            <> toLogStr (show bs) <> "\n"
        Just n | otherwise -> do 
          let parser' = parser `pushBytes` bs -- TODO: use putEventType from GHC.RTS.Events
              parser'' = if n == curN'
                then parser' `pushBytes` ("hete" <> "hdre" <> "datb")  -- TODO: use constants from ghc-events
                else parser'
              curN' = curN + 1
          modify' $ \mc -> parser'' `seq` curN' `seq` mc { collectorHeader = (maxN, curN', parser'') }
        Nothing -> do
          let parser' = parser `pushBytes` bs -- TODO: use putEventType from GHC.RTS.Events
              curN' = curN + 1
          modify' $ \mc -> parser' `seq` curN' `seq` mc { collectorHeader = (maxN, curN', parser') }

-- | Perform one step of converting the profiler protocol into events
stepEventCollector :: (MonadState MessageCollector m, MonadWriter LogStr m)
  => UTCTime -- ^ Current time
  -> EventParserState -- ^ Incremental parser with fully feeded header
  -> EventMsg -- ^ New message arrived
  -> m (Maybe (S.Seq Event)) -- ^ Result of decoded event if any
stepEventCollector curTime parser msg = case msg of
  EventBlockMsg bmsg -> collectorBlock bmsg 
  EventMsg pmsg -> do 
    res <- collectorPartial pmsg 
    return $ case res of 
      Nothing -> Nothing 
      Just e -> Just $ S.singleton e 
  where 
  -- Handle event's block messages. Watch when a block starts, when messages
  -- of the block are arrived. The main nuance is that header and events can 
  -- arrive in out of order, so need to handle this neatly.   
  collectorBlock :: (MonadState MessageCollector m, MonadWriter LogStr m)
    => EventBlockMsg -- ^ Message about event block
    -> m (Maybe (S.Seq Event))
  collectorBlock bmsg = case bmsg of 
    EventBlockMsgHeader header@EventBlockMsgData{..} -> do 
      modify' $ \mc@MessageCollector{..} -> mc {
          collectorBlocks = case eblockMsgDataId `H.lookup` collectorBlocks of 
            Nothing -> H.insert eblockMsgDataId (curTime, Just header, S.empty) collectorBlocks
            Just (t, _, es) -> H.insert eblockMsgDataId (t, Just header, es) collectorBlocks
        }
      return Nothing
    EventBlockMsgPart {..} -> do 
      mc <- get 
      mpayload <- collectorPartial eblockMsgPayload 
      case mpayload of 
        Nothing -> return Nothing -- The case when only part of a message arrived
        Just payload -> case eblockMsgId `H.lookup` collectorBlocks mc of 
          Nothing -> do 
            put mc {
                collectorBlocks = H.insert eblockMsgId (curTime, Nothing, S.singleton payload) $ collectorBlocks mc
              }
            return Nothing
          Just (t, Nothing, es) -> do
            put mc {
                collectorBlocks = H.insert eblockMsgId (t, Nothing, es S.|> payload) $ collectorBlocks mc
              }
            return Nothing
          Just (t, Just header, es) -> if fromIntegral (S.length es) >= eblockMsgDataEventsCount header
            then do
              modify' $ \mc'@MessageCollector{..} -> mc' {
                  collectorBlocks = H.delete eblockMsgId collectorBlocks
                }
              let blockHead = Event {
                    evTime = eblockMsgDataBeginTimestamp header
                  , evSpec = EventBlock {
                      end_time = eblockMsgDataEndTimestamp header
                    , cap = capToGhcEvents $ eblockMsgDataCap header
                    , block_size = eblockMsgDataEventsCount header
                    }
                  , evCap = Just $ capToGhcEvents $ eblockMsgDataCap header
                  }
              return . Just $ (blockHead S.<| es) S.|> payload
            else do 
              modify' $ \mc'@MessageCollector{..} -> mc' {
                  collectorBlocks = H.insert eblockMsgId (t, Just header, es S.|> payload) collectorBlocks
                }
              return Nothing

  -- | Process partial messages and return collected results. 
  -- The main nuance is that header and events can arrive in 
  -- out of order, so need to handle this neatly.   
  collectorPartial :: (MonadState MessageCollector m, MonadWriter LogStr m)
    => EventMsgPartial -- ^ Message about event block
    -> m (Maybe Event)
  collectorPartial pmsg = case pmsg of 
    EventMsgFull ev -> return $ Just ev 
    EventMsgPartial header@EventPartialData{..} -> do 
      mc@MessageCollector{..} <- get
      put mc {
          collectorPartials = case epartialMsgId `H.lookup` collectorPartials of 
            Nothing -> H.insert epartialMsgId (curTime, Just header, S.empty) collectorPartials
            Just _ -> collectorPartials
        }
      return Nothing 
    EventMsgPart {..} -> do 
      mc@MessageCollector{..} <- get
      case epartMsgId `H.lookup` collectorPartials of 
        Nothing -> do 
          put mc {
              collectorPartials = H.insert epartMsgId 
                (curTime, Nothing, S.singleton (epartMsgNum, epartMsgPayload)) collectorPartials
            }
          return Nothing
        Just (t, Nothing, es) -> do 
          put mc {
              collectorPartials = H.insert epartMsgId 
                (t, Nothing, (epartMsgNum, epartMsgPayload) `orderedInsert` es) collectorPartials
            }
          return Nothing
        Just (t, Just header, es) -> if fromIntegral (S.length es) >= epartialMsgParts header
          then case parsed of 
            Incomplete -> do
              tell $ "Live profiler: Received incomplete message: " <> toLogStr (show payload) <> ", please report a bug.\n"
              return Nothing -- something went wrong.
            Complete -> do
              tell $ "Live profiler: Received event, but the incremental parser is finished, please report a bug.\n"
              return Nothing -- something went wrong.
            ParseError s -> do
              tell $ "Live profiler: Received incorrect event's payload: " <> toLogStr (show payload) 
                <> ". Error: " <> toLogStr s <> "\n"
              return Nothing  -- something went wrong. 
            Item ev -> do
              put mc {
                collectorPartials = H.delete epartMsgId collectorPartials
                }
              return $ Just ev
          else do 
            put mc {
                collectorPartials = H.insert epartMsgId 
                  (t, Just header, (epartMsgNum, epartMsgPayload) `orderedInsert` es) collectorPartials
              }
            return Nothing
          where
            es' = (epartMsgNum, epartMsgPayload) `orderedInsert` es 
            payload = F.foldl' (\acc s -> acc <> s) BS.empty $ snd `fmap` es'
            (parsed, _) = readEvent $ pushBytes parser payload -- We drop new parser state as we always 
              -- feed enough data to get new event. Pure parser state cannot be stored as collector state
              -- as the bits could arrive in out of order.

-- | Inserts the pair into sequence with preserving ascending order
orderedInsert :: Ord a => (a, b) -> S.Seq (a, b) -> S.Seq (a, b)
orderedInsert (a, b) s = snd $ F.foldl' go (False, S.empty) s
  where 
  go (True, acc) e = (True, acc S.|> e)
  go (False, acc) (a', b') 
    | a >= a'   = (False, acc S.|> (a', b'))
    | otherwise = (True, acc S.|> (a', b') S.|> (a, b))

-- | Convert representation of cap to ghc-events one
capToGhcEvents :: Word32 -> Int 
capToGhcEvents i = fromIntegral i - 1

-- | Convert representation of cap from ghc-events one
capFromGhcEvents :: Int -> Word32 
capFromGhcEvents i 
  | i < 0 = 0 
  | otherwise = fromIntegral i + 1

