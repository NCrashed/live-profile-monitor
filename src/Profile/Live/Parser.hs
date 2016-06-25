{-# LANGUAGE RecordWildCards #-}
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
preserveEventlog :: Word -> IO a -> IO a 
preserveEventlog chunkSize m = do
  oldf <- getEventLogCFile
  odlSize <- getEventLogBufferSize
  bracket saveOld (restoreOld oldf odlSize) $ const m 
  where 
  saveOld = do
    setEventLogCFile nullPtr False False
    setEventLogBufferSize chunkSize
  restoreOld oldf odlSize _ = do
    setEventLogCFile oldf False False
    setEventLogBufferSize odlSize

-- | Same as 'getEventLogChunk' but wraps result in 'ByteString'
getEventLogChunk' :: IO (Maybe B.ByteString)
getEventLogChunk' = do
  mres <- getEventLogChunk
  case mres of 
    Nothing -> return Nothing
    Just cbuf -> Just <$> B.unsafePackMallocCStringLen cbuf

-- | Creates thread that pipes eventlog from memory into incremental parser
redirectEventlog :: LiveProfileOpts -> Termination -> Termination -> IORef Bool -> IO ThreadId
redirectEventlog LiveProfileOpts{..} termVar thisTerm _ = do
  forkIO . void . preserveEventlog eventLogChunkSize $ do 
    untilTerminated termVar newParserState $ go
    putMVar thisTerm ()
  where 
  go parserState = do 
    mdatum <- getEventLogChunk'
    let parserState' = maybe parserState (pushBytes parserState) mdatum
        (res, parserState'') = readEvent parserState'
    case res of 
      Item e -> print e 
      Incomplete -> return ()
      Complete -> return ()
      ParseError er -> putStrLn $ "parserThread: " ++ er
    return parserState''