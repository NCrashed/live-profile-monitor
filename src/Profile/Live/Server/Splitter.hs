{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
module Profile.Live.Server.Splitter(
    SplitterState
  , emptySplitterState
  , mkHeaderMsgs
  , stepSplitter
  ) where 

import Control.DeepSeq
import Control.Monad.State.Class
import Control.Monad.Writer.Class
import Data.Binary.Put
import GHC.Generics 
import GHC.RTS.Events
import Profile.Live.Server.Message
import System.Log.FastLogger
import Data.Word 

import qualified Data.Sequence as S 
import qualified Data.ByteString.Lazy as BSL

data SplitterState = SplitterState {
    -- | If the event block is arrived, we store its ID and number of next
    -- events to proceed as blocked events.
    splitterCurrentBlock :: !(Maybe (Word64, Word32))
    -- | Next free block ID, all blocks during session must have unique id
  , splitterNextBlockId :: !Word64
} deriving Generic

instance NFData SplitterState

-- | Initial state of splitter state
emptySplitterState :: SplitterState
emptySplitterState = SplitterState {
    splitterCurrentBlock = Nothing
  , splitterNextBlockId = 0
  }

-- | Generate sequence of messages for header
mkHeaderMsgs :: Header -> S.Seq HeaderMsg 
mkHeaderMsgs (Header ets) = header S.<| msgs 
  where 
  header = HeaderLength (fromIntegral $ length ets)
  msgs = HeaderType . BSL.toStrict . runPut . putEventType <$> S.fromList ets

-- | Generator of protocol messages from GHC events
stepSplitter :: (MonadState SplitterState m, MonadWriter LogStr m)
  => Event 
  -> m (S.Seq ProfileMsg)
stepSplitter Event{..} = case evSpec of 
  EventBlock{..} -> do 
    SplitterState{..} <- get
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
  _ -> undefined 