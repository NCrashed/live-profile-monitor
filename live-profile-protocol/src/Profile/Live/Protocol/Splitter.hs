{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
module Profile.Live.Protocol.Splitter(
    SplitterState
  , emptySplitterState
  , mkHeaderMsgs
  , stepSplitter
  ) where 

import Control.DeepSeq
import Control.Monad
import Control.Monad.State.Class
import Data.Binary.Put
import Data.Binary.Serialise.CBOR 
import Data.Word 
import GHC.Generics 
import GHC.RTS.Events

import Profile.Live.Protocol.Message
import Profile.Live.Protocol.State 

import qualified Data.Sequence as S 
import qualified Data.ByteString.Lazy as BSL

data SplitterState = SplitterState {
    -- | If the event block is arrived, we store its ID and number of next
    -- events to proceed as blocked events.
    splitterCurrentBlock :: !(Maybe (Word64, Word32))
    -- | Next free block ID, all blocks during session must have unique id
  , splitterNextBlockId :: !Word64
    -- | Maximum datagram size when it needed to be split into several parts
  , splitterDatagramSize :: !Word 
    -- | Next free partial message ID, when we need to partial messages set
    -- the field is taken as msg ID and incremented.
  , splitterNextMessageId :: !Word64 
} deriving Generic
 
instance NFData SplitterState

-- | Initial state of splitter state
emptySplitterState :: Word -> SplitterState
emptySplitterState datagramSize = SplitterState {
    splitterCurrentBlock = Nothing
  , splitterNextBlockId = 0
  , splitterDatagramSize = datagramSize
  , splitterNextMessageId = 0
  }

-- | Generate sequence of messages for header
mkHeaderMsgs :: S.Seq EventType -> S.Seq HeaderMsg 
mkHeaderMsgs ets = header S.<| msgs 
  where 
  header = HeaderLength (fromIntegral $ S.length ets)
  msgs = HeaderType . BSL.toStrict . runPut . putEventType <$> ets

-- | Generator of protocol messages from GHC events
stepSplitter :: (MonadState SplitterState m)
  => (Either EventlogState Event)
  -> m (S.Seq ProfileMsg)
stepSplitter (Left st) = do 
  msgs <- makePartial $ serialise st
  return $ ProfileState <$> msgs
stepSplitter (Right ev@Event{..}) = do
  SplitterState{..} <- get  
  case evSpec of 
    EventBlock{..} -> do 
      modify' $ \ss -> ss {
          splitterCurrentBlock = Just (splitterNextBlockId, block_size)
        , splitterNextBlockId = splitterNextBlockId + 1
        }
      return . S.singleton . ProfileEvent . EventBlockMsg . EventBlockMsgHeader $ EventBlockMsgData {
          eblockMsgDataId = splitterNextBlockId
        , eblockMsgDataBeginTimestamp = evTime
        , eblockMsgDataEndTimestamp = end_time
        , eblockMsgDataCap = capFromGhcEvents cap 
        , eblockMsgDataEventsCount = block_size
        }
    _ -> do
      let payload = runPut (putEvent ev)
      msgs <- makePartial payload
      case splitterCurrentBlock of 
        Nothing -> return $ ProfileEvent . EventMsg <$> msgs
        Just (_, curBlockSize) -> do 
          when (curBlockSize <= 1) $ modify' $ \ss -> ss {
              splitterCurrentBlock = Nothing
            }
          return $ ProfileEvent . EventMsg <$> msgs

-- | Make sequence of network messages from given event, and the event payload
-- is splitted by max datagram size
makePartial :: (MonadState SplitterState m)
  => BSL.ByteString 
  -> m (S.Seq EventMsgPartial)
makePartial payload = do 
  SplitterState{..} <- get
  if fromIntegral (BSL.length payload) > splitterDatagramSize
    then do 
      modify' $ \ss -> ss {
          splitterNextMessageId = splitterNextMessageId + 1
        }
      let payloads = accumUnless BSL.null (BSL.splitAt $ fromIntegral splitterDatagramSize) payload
          headMsg = EventMsgPartial $ EventPartialData {
              epartialMsgId = splitterNextMessageId
            , epartialMsgParts = fromIntegral $ S.length payloads
            }
          mkMsg i bs = EventMsgPart {
              epartMsgId = splitterNextMessageId
            , epartMsgNum = fromIntegral i 
            , epartMsgPayload = BSL.toStrict bs
            }
          msgs = S.mapWithIndex mkMsg payloads
      return $ headMsg S.<| msgs
    else return . S.singleton . EventMsgFull . BSL.toStrict $ payload  
  where 
  accumUnless :: (a -> Bool) -> (a -> (b, a)) -> a -> S.Seq b 
  accumUnless cond f = go S.empty
    where 
    go !acc !a = if cond a then acc 
      else let (!b, a') = f a in go (acc S.|> b) a'