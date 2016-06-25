module Profile.Live.Parser(
    redirectEventlog
  ) where 

import Control.Concurrent
import Control.Exception (bracket)
import Control.Monad (void)
import Data.IORef 
import Debug.Trace
import Foreign hiding (void)
import GHC.RTS.EventsIncremental 

import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B 

import Profile.Live.Options 
import Profile.Live.State 

-- | Temporaly disables event log to file
preserveEventlog :: LoggerSet -> Word -> IO a -> IO a 
preserveEventlog logger chunkSize m = do
  oldf <- getEventLogCFile
  odlSize <- getEventLogBufferSize
  bracket saveOld (restoreOld oldf odlSize) $ const m 
  where 
  saveOld = do
    logProf logger "Disable logging to file"
    setEventLogCFile nullPtr False False
    logProf logger "Resize eventlog buffers"
    setEventLogBufferSize chunkSize
  restoreOld oldf odlSize _ = do
    logProf logger "Restore logging to file"
    setEventLogCFile oldf False False
    logProf logger "Restore old buffer size"
    setEventLogBufferSize odlSize

-- | Same as 'getEventLogChunk' but wraps result in 'ByteString'
getEventLogChunk' :: IO (Maybe B.ByteString)
getEventLogChunk' = do
  mres <- getEventLogChunk
  case mres of 
    Nothing -> return Nothing
    Just cbuf -> Just <$> B.unsafePackMallocCStringLen cbuf

-- | Creates thread that pipes eventlog from memory into incremental parser
redirectEventlog :: LoggerSet -- ^ Monitor logger
  -> LiveProfileOpts -- ^ Options of the monitor
  -> Termination -- ^ When set we need to terminate self
  -> Termination -- ^ When terminates we need to set this
  -> IORef Bool -- ^ Holds flag whether the monitor is paused
  -> IO ThreadId -- ^ Forks new thread with incremental parser
redirectEventlog logger LiveProfileOpts{..} termVar thisTerm _ = do
  forkIO . void . preserveEventlog logger eventLogChunkSize $ do 
    logProf logger "Parser thread started"
    untilTerminated termVar newParserState go
    putMVar thisTerm ()
    logProf logger "Parser thread terminated"
  where 
  go parserState = do 
    mdatum <- getEventLogChunk'
    let parserState' = maybe parserState (pushBytes parserState) mdatum
        (res, parserState'') = readEvent parserState'
    case res of 
      Item _ -> return () --logProf logger $ toLogStr $ show e 
      Incomplete -> return ()
      Complete -> return ()
      ParseError er -> logProf logger $ "parserThread error: " <> toLogStr er
    return parserState''