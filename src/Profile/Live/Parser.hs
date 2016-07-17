module Profile.Live.Parser(
    redirectEventlog
  ) where 

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMChan
import Control.Exception (bracket)
import Control.Monad (void)
import Data.Maybe
import Debug.Trace
import Foreign hiding (void)
import GHC.RTS.Events hiding (ThreadId)
import GHC.RTS.EventsIncremental 

import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B 

import Profile.Live.Options 
import Profile.Live.State 
import Profile.Live.Termination
import Profile.Live.Pipe 

-- | Initialise link with C world that pipes data from FIFO file (or named pipe on Windows)
initMemoryPipe :: FilePath -- ^ Pipe name
  -> Word64 -- ^ Chunk size
  -> IO (TChan B.ByteString, IO ())
initMemoryPipe pipeName buffSize = do 
  chan <- newTChanIO 
  stopPipe <- startPipe PipeOptions {
      pipeName = pipeName
    , pipeBufferSize = buffSize
    , pipeCallback = atomically . writeTChan chan 
    }
  return (chan, stopPipe)

-- | Creates thread that pipes eventlog from memory into incremental parser
redirectEventlog :: LoggerSet -- ^ Monitor logger
  -> LiveProfileOpts -- ^ Options of the monitor
  -> TerminationPair -- ^ Termination protocol
  -> EventTypeChan -- ^ Channel for event types, closed as soon as first event occured
  -> EventChan -- ^ Channel for events
  -> IO ThreadId -- ^ Forks new thread with incremental parser
redirectEventlog logger LiveProfileOpts{..} term eventTypeChan eventChan = do
  forkIO . void $ do 
    labelCurrentThread "Parser"
    logProf logger "Parser thread started"
    bracket (initMemoryPipe eventLogPipeName eventLogChunkSize) snd $ \(pipe, _) -> do
      untilTerminatedPair term $ go pipe newParserState
    logProf logger "Parser thread terminated"
  where 
  go !pipe !parserState = do 
    datum <- atomically $ readTChan pipe 
    let parserState' = pushBytes parserState datum
        (res, parserState'') = readEvent parserState'
    case res of 
      Item e -> do
        mhmsg <- atomically $ do 
          closed <- isClosedTBMChan eventTypeChan
          if not closed then do
              msgs <- putHeader parserState'' 
              closeTBMChan eventTypeChan
              return msgs
            else return Nothing
        whenJust mhmsg $ logProf logger

        memsg <- atomically $ putEvent' e
        whenJust memsg $ logProf logger
      Incomplete -> return ()
      Complete -> return ()
      ParseError er -> logProf logger $ "parserThread error: " <> toLogStr er
    go pipe parserState''

  putHeader :: EventParserState -> STM (Maybe LogStr)
  putHeader parserState = case readHeader parserState of 
    Nothing -> return . Just $ "parserThread warning: got no header, that is definitely a bug.\n"
    Just Header{..} -> do 
      msgs <- catMaybes <$> mapM putEventType' eventTypes
      return $ if null msgs then Nothing else Just $ mconcat msgs

  putEventType' = putChannel eventTypeChan "parserThread: dropped event type as channel is overflowed.\n"
  putEvent' = putChannel eventChan "parserThread: dropped event type as channel is overflowed.\n"

  putChannel :: forall a . TBMChan a -> LogStr -> a -> STM (Maybe LogStr)
  putChannel chan msg i = do 
    full <- isFullTBMChan chan
    if full then return $ Just msg
      else do 
        writeTBMChan chan i 
        return Nothing