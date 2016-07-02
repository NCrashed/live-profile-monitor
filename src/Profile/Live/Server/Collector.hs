{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
module Profile.Live.Server.Collector(
    MessageCollector
  , CollectorOutput(..)
  , emptyMessageCollector
  , stepMessageCollector
  ) where 

import Control.DeepSeq
import Control.Monad 
import Control.Monad.State.Class
import Control.Monad.Writer.Class
import Data.Maybe
import Data.Monoid
import Data.Time 
import Data.Word 
import GHC.RTS.Events
import GHC.RTS.EventsIncremental
import System.Log.FastLogger
import GHC.Generics 

import qualified Data.ByteString as BS 
import qualified Data.Foldable as F 
import qualified Data.HashMap.Strict as H
import qualified Data.Sequence as S 

import Profile.Live.Server.Message

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
  , collectorHeader :: !(Maybe Word64, Word64)
    -- | Current state of incremental parser
  , collectorParser :: !EventParserState
  }

instance NFData MessageCollector where 
  rnf MessageCollector{..} = 
    collectorPartials `deepseq` 
    collectorBlocks `deepseq`
    collectorTimeout `deepseq`
    (let (a, b) = collectorHeader in a `deepseq` b `seq` ()) `seq`
    collectorParser `seq` ()

-- | Initial state of message collector
emptyMessageCollector :: NominalDiffTime -> MessageCollector 
emptyMessageCollector timeout = MessageCollector {
    collectorPartials = H.empty 
  , collectorBlocks = H.empty
  , collectorTimeout = timeout
  , collectorHeader = (Nothing, 0) 
  , collectorParser = newParserState `pushBytes` ("hdrb" <> "hetb") -- TODO: use constant from ghc-events
  }

-- | Helper that returns 'True' only when collector doesn't have full header inside
isHeaderNotCollected :: MessageCollector -> Bool 
isHeaderNotCollected MessageCollector{..} = let 
     (maxN, curN) = collectorHeader
  in isNothing maxN || fromMaybe 0 maxN > curN 

-- | Return header that is collector in the message collected
collectedEventlogHeader :: MessageCollector -> Maybe Header 
collectedEventlogHeader MessageCollector{..} = readHeader collectorParser

-- | Adding markers to header parser that indicates the end of header block 
-- and start of event decoding.
finaliseEventlogHeader :: MessageCollector -> MessageCollector
finaliseEventlogHeader mc@MessageCollector{..} = mc {
    collectorParser = collectorParser `pushBytes` ("hete" <> "hdre" <> "datb")  -- TODO: use constants from ghc-events
  }

-- | Possible outputs of message collector
data CollectorOutput = 
    CollectorHeader !Header 
  | CollectorService !ServiceMsg 
  | CollectorEvents !(S.Seq Event)
  deriving (Show, Generic)

-- | Perform one step of converting the profiler protocol into events
stepMessageCollector :: (MonadState MessageCollector m, MonadWriter LogStr m)
  => UTCTime -- ^ Current time
  -> ProfileMsg -- ^ New message arrived
  -> m CollectorOutput -- ^ Result of decoded events
stepMessageCollector curTime  msg = do
  isPhase1 <- isHeaderNotCollected <$> get
  case msg of
    ProfileService smsg -> return $ CollectorService smsg 
    ProfileHeader hmsg | isPhase1 -> do
      stepHeaderCollector hmsg 
      isPhase2 <- not . isHeaderNotCollected <$> get
      when isPhase2 $ modify' finaliseEventlogHeader 
      header <- gets collectedEventlogHeader
      return $ maybe (CollectorEvents S.empty) CollectorHeader header
    ProfileHeader hmsg | otherwise -> do 
      tell "Live profiler: Got header message in second phase.\n"
      stepHeaderCollector hmsg
      return (CollectorEvents S.empty)
    ProfileEvent emsg -> do
      when isPhase1 $ tell "Live profiler: Got event message in first phase.\n"
      mseq <- stepEventCollector curTime emsg
      return $ CollectorEvents $ fromMaybe mempty mseq

-- | First phase of the collector when we collect header
stepHeaderCollector :: (MonadState MessageCollector m, MonadWriter LogStr m)
  => HeaderMsg -- ^ New message arrived 
  -> m () -- ^ Returns incremental parser ready for events consuming
stepHeaderCollector hmsg = do
  MessageCollector{..} <- get 
  let (maxN, curN) = collectorHeader
  case hmsg of 
    HeaderLength n -> do
      when (isJust maxN) . tell $ "Live profiler: Received repeated header initiation message. It's not normal.\n"
      let maxN' = Just n
      modify' $ \mc -> maxN' `seq` mc { collectorHeader = (maxN', curN) }
    HeaderType bs -> do
      case maxN of 
        Just n | n <= curN -> do 
          tell $ "Live profiler: Received excess event type (" 
            <> toLogStr (show $ curN+1) <> "). It's not normal. Event type:" 
            <> toLogStr (show bs) <> "\n"
        _ -> do 
          let curN' = curN + 1
          modify' $ \mc -> curN' `seq` mc { 
              collectorHeader = (maxN, curN') 
            , collectorParser = collectorParser `pushBytes` bs -- TODO: use putEventType from GHC.RTS.Events
            }

-- | Perform one step of converting the profiler protocol into events
stepEventCollector :: (MonadState MessageCollector m, MonadWriter LogStr m)
  => UTCTime -- ^ Current time
  -> EventMsg -- ^ New message arrived
  -> m (Maybe (S.Seq Event)) -- ^ Result of decoded event if any
stepEventCollector curTime msg = case msg of
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
    EventMsgFull payload -> withParsed payload $ return . Just 
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
          then withParsed payload $ \ev -> do
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
    where 
      -- We drop new parser state as we always 
      -- feed enough data to get new event. Pure parser state cannot be stored as collector state
      -- as the bits could arrive in out of order.
      withParsed payload m = do 
        parser <- gets collectorParser
        let (res, parser') = readEvent $ pushBytes parser payload
        case res of 
          Incomplete -> do
            modify' $ \mc -> mc { collectorParser = parser' }
            return Nothing
          Complete -> do
            tell $ "Live profiler: Received event, but the incremental parser is finished, please report a bug.\n"
            return Nothing -- something went wrong.
          ParseError s -> do
            tell $ "Live profiler: Received incorrect event's payload: " <> toLogStr (show payload) 
              <> ". Error: " <> toLogStr s <> "\n"
            return Nothing  -- something went wrong. 
          Item ev -> do 
            modify' $ \mc -> mc { collectorParser = parser' }
            m ev 

-- | Inserts the pair into sequence with preserving ascending order
orderedInsert :: Ord a => (a, b) -> S.Seq (a, b) -> S.Seq (a, b)
orderedInsert (a, b) s = snd $ F.foldl' go (False, S.empty) s
  where 
  go (True, acc) e = (True, acc S.|> e)
  go (False, acc) (a', b') 
    | a >= a'   = (False, acc S.|> (a', b'))
    | otherwise = (True, acc S.|> (a', b') S.|> (a, b))