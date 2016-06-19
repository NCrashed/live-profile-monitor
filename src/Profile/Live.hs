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

-- | Live profiler state
data LiveProfiler = LiveProfiler {
  -- | Id of thread that pipes from memory into incremental parser
  eventLogPipeThread :: ThreadId
, eventLogTerminate :: MVar ()
}

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: LiveProfileOpts -> IO LiveProfiler
initLiveProfile opts = do
  initialParser <- ensureEvengLogFile 
  parserRef <- newIORef initialParser
  termVar <- newEmptyMVar
  pipeId <- redirectEventlog opts termVar parserRef
  return LiveProfiler {
      eventLogPipeThread = pipeId
    , eventLogTerminate = termVar
    }

-- | Destroy live profiler.
--
-- The function closes all sockets, stops all related threads and
-- restores eventlog sink. 
stopLiveProfile :: LiveProfiler -> IO ()
stopLiveProfile LiveProfiler{..} = do
  putMVar eventLogTerminate ()

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
  return $ pushBytes newParserState bs

foreign import ccall "enableEventLogPipe"
  enableEventLogPipe :: CSize -> IO ()

foreign import ccall "disableEventLogPipe"
  disableEventLogPipe :: IO ()

foreign import ccall "getEventLogChunk"
  getEventLogChunk :: Ptr (Ptr ()) -> Ptr CSize -> IO ()

-- | Create pipe on C side to transfer data from RTS to Haskell side
withPipe :: Word64 -> IO a -> IO a 
withPipe chunkSize m = do
  oldf <- getEventLogCFile
  bracket createPipes (deletePipes oldf) $ const m 
  where 
  createPipes = withCString "w" $ \iomode -> do 
    enableEventLogPipe (fromIntegral chunkSize)
    setEventLogCFile nullPtr False False
    return ()
  deletePipes oldf _ = do
    disableEventLogPipe
    setEventLogCFile oldf False False
    return ()

whenJust :: Applicative m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing _ = pure ()
whenJust (Just x) m = m x 

getEventLogChunk' :: IO (Maybe B.ByteString)
getEventLogChunk' = alloca $ \ptrBuf -> alloca $ \ptrSize -> do 
  getEventLogChunk ptrBuf ptrSize
  size <- peek ptrSize
  if size == 0 then return Nothing 
    else do
      buf <- peek ptrBuf
      Just <$> B.unsafePackMallocCStringLen (castPtr buf, fromIntegral size)

-- | Creates thread that pipes eventlog from memory into incremental parser
redirectEventlog :: LiveProfileOpts -> MVar () -> IORef EventParserState -> IO ThreadId
redirectEventlog LiveProfileOpts{..} termVar parserRef = do 
  forkIO . void . withPipe eventLogChunkSize . untilTerminated $ do
    mdatum <- getEventLogChunk'
    whenJust mdatum $ \datum -> do
      print $ B.take 30 datum
      --datum `deepseq` atomicModifyIORef' parserRef $ \parser -> (pushBytes parser datum, ())
    yield
  where 
    untilTerminated m = do 
      res <- tryTakeMVar termVar
      case res of 
        Nothing -> m 
        Just _ -> return ()
