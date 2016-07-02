module Test.Client(
    recieveRemoteEventlog
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMChan
import Control.Exception
import Control.Monad 
import Data.IORef 
import System.IO 
import System.Log.FastLogger
import GHC.RTS.Events 

import Profile.Live.Options 
import Profile.Live.Parser 
import Profile.Live.Server
import Profile.Live.State 

import System.Socket
import System.Socket.Family.Inet6
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP
import System.IO

import qualified Data.ByteString as BS 

type ServerSocket = Socket Inet6 Stream TCP 

recieveRemoteEventlog :: SocketAddress Inet6 -> FilePath -> IO ()
recieveRemoteEventlog addr filename = void . forkIO $ bracket socket close $ 
  \s -> connect s addr >> go s 
  where 
  go :: ServerSocket -> IO ()
  go s = do 
    logger <- newStdoutLoggerSet defaultBufSize
    term <- newEmptyMVar
    serverTerm <- newEmptyMVar
    pauseRef <- newIORef False
    eventTypeChan <- newTBMChanIO 0
    eventChan <- newTBMChanIO 0

    fileChan <- newTChanIO 
    let headerCallback = atomically . writeTChan fileChan . Left
        eventCallback = atomically . writeTChan fileChan . Right

    let opts = defaultLiveProfileOpts {
            eventLogListenPort = 8243
          }

    _ <- startLiveServer logger defaultLiveProfileOpts term serverTerm
      pauseRef eventTypeChan eventChan
    
    writeLogFile fileChan

  writeLogFile :: TChan (Either Header Event) -> IO ()
  writeLogFile chan = withFile filename WriteMode $ \h -> forever $ do 
    mres <- atomically $ readTChan chan
    case mres of 
      Left header -> do 
        hPutStr h $ show header
      Right e -> do 
        hPutStr h $ show e
    hFlush h 