{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}
module Profile.Live(
  -- * Options
    LiveProfileOpts
  , defaultLiveProfileOpts
  -- * Basic API
  , LiveProfiler
  , initLiveProfile
  , stopLiveProfile
  ) where 

import Control.Concurrent (ThreadId, forkIO, throwTo, yield)
import Control.Concurrent.MVar 
import Control.Concurrent.STM
import Control.DeepSeq 
import Control.Exception (bracket, Exception, AsyncException(..))
import Control.Monad (void)
import Data.Bits
import Data.IORef
import Data.Maybe (fromMaybe)
import Data.Monoid
import Data.Word
import Debug.Trace (getEventLogCFile, setEventLogCFile, setEventLogHandle)
import Foreign hiding (void)
import Foreign.C
import Foreign.Marshal.Utils (toBool)
import GHC.RTS.EventsIncremental 
import System.Directory (doesFileExist, getTemporaryDirectory, removeFile)
import System.Environment (getExecutablePath)
import System.FilePath (takeBaseName)
import System.IO (IOMode(..), openFile, Handle, hClose)
import System.Posix.Types (Fd(..))

import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as B 

-- | Options of live profile monitor
data LiveProfileOpts = LiveProfileOpts {
  -- | Chunk size to get from eventlog before feeding into incremental parser
  -- TODO: make the size also the size of eventlog buffers
  eventLogChunkSize :: !Word64
} deriving Show 

-- | Default options of live profile
defaultLiveProfileOpts :: LiveProfileOpts
defaultLiveProfileOpts = LiveProfileOpts {
    eventLogChunkSize = 1024 * 1024 -- 1 Mb
  }

-- | Termination mutex, all threads are stopped when the mvar is filled
type Termination = MVar ()

-- | Live profiler state
data LiveProfiler = LiveProfiler {
  -- | Id of thread that pipes from memory into incremental parser
  eventLogPipeThread :: ThreadId
  -- | Id of thread that performs incremental parsing
, eventLogParserThread :: ThreadId 
  -- | Termination mutex, all threads are stopped when the mvar is filled
, eventLogTerminate :: Termination
}

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: LiveProfileOpts -> IO LiveProfiler
initLiveProfile opts = do
  initialParser <- ensureEvengLogFile 
  parserRef <- newTVarIO initialParser
  termVar <- newEmptyMVar
  pipeId <- redirectEventlog opts termVar parserRef
  parserId <- parserThread opts termVar parserRef
  return LiveProfiler {
      eventLogPipeThread = pipeId
    , eventLogParserThread = parserId
    , eventLogTerminate = termVar
    }

-- | Destroy live profiler.
--
-- The function closes all sockets, stops all related threads and
-- restores eventlog sink. 
stopLiveProfile :: LiveProfiler -> IO ()
stopLiveProfile LiveProfiler{..} = putMVar eventLogTerminate ()

-- | Tries to load data from eventlog default file and construct
-- incremental parser. Throws if there is no eventlog file. 
--
-- We need the begining as when user is able to call 'initLiveProfile'
-- some important events were emitted into the default file.
ensureEvengLogFile :: IO EventParserState
ensureEvengLogFile = do 
  execPath <- getExecutablePath
  let fileName = takeBaseName execPath <> ".eventlog"
  eventlogPresents <- doesFileExist fileName
  if eventlogPresents then initParserFromFile fileName
    else fail "Cannot find eventlog file, check if program compiled with '-eventlog -rtsopts' and run it with '+RTS -l'"

-- | Read the begining of eventlog from file and construct
-- incremental parser. 
--
-- We need the begining as when user is able to call 'initLiveProfile'
-- some important events were emitted into the default file.
initParserFromFile :: FilePath -> IO EventParserState
initParserFromFile fn = do 
  bs <- B.readFile fn
  putStrLn fn 
  B.putStrLn bs
  return $ bs `seq` newParserState `pushBytes` bs

foreign import ccall "enableEventLogPipe"
  enableEventLogPipe :: CSize -> IO ()

foreign import ccall "disableEventLogPipe"
  disableEventLogPipe :: IO ()

foreign import ccall "getEventLogChunk"
  getEventLogChunk :: Ptr (Ptr ()) -> IO CSize

-- | Temporaly disables event log to file
preserveEventlog :: IO a -> IO a 
preserveEventlog m = do
  oldf <- getEventLogCFile
  bracket saveOld (restoreOld oldf) $ const m 
  where 
  saveOld = setEventLogCFile nullPtr False False
  restoreOld oldf _ = setEventLogCFile oldf False False

whenJust :: Applicative m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing _ = pure ()
whenJust (Just x) m = m x 

getEventLogChunk' :: IO (Maybe B.ByteString)
getEventLogChunk' = alloca $ \ptrBuf -> do 
  size <- getEventLogChunk ptrBuf
  if size == 0 then return Nothing 
    else do
      buf <- peek ptrBuf
      Just <$> B.unsafePackMallocCStringLen (castPtr buf, fromIntegral size)

-- | Do action until the mvar is not filled
untilTerminated :: Termination -> IO a -> IO ()
untilTerminated termVar m = do 
  res <- tryTakeMVar termVar
  case res of 
    Nothing -> m >> untilTerminated termVar m
    Just _ -> return ()

-- | Creates thread that pipes eventlog from memory into incremental parser
redirectEventlog :: LiveProfileOpts -> Termination -> TVar EventParserState -> IO ThreadId
redirectEventlog LiveProfileOpts{..} termVar parserRef = do 
  forkIO . void . preserveEventlog . untilTerminated termVar $ do
    mdatum <- getEventLogChunk'
    whenJust mdatum $ \datum -> atomically $
      modifyTVar' parserRef $ \parser -> pushBytes parser datum
    yield

-- | Performs incremental parsing and eventlog state management
parserThread :: LiveProfileOpts -> Termination -> TVar EventParserState -> IO ThreadId
parserThread LiveProfileOpts{..} termVar parserRef = do 
  forkIO . untilTerminated termVar $ do 
    res <- atomically $ do 
      (res, parser') <- readEvent <$> readTVar parserRef
      writeTVar parserRef parser'
      return $ parser' `seq` res
    case res of 
      Item e -> print e 
      Incomplete -> return ()
      Complete -> return ()
      ParseError er -> putStrLn $ "parserThread: " ++ er