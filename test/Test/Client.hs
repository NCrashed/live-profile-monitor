module Test.Client(
    receiveRemoteEventlog
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad 
import Data.Binary.Put
import GHC.RTS.Events 
import System.IO
import System.Log.FastLogger

import Profile.Live.Options 
import Profile.Live.Server
import Profile.Live.State 
import Profile.Live.Termination

import qualified Data.ByteString as BS 
import qualified Data.ByteString.Lazy as BSL

receiveRemoteEventlog :: Termination -> FilePath -> IO Termination
receiveRemoteEventlog term filename = do
  serverTerm <- newEmptyMVar
  _ <- forkIO $ do 
    logger <- newStdoutLoggerSet defaultBufSize
    fileChan <- newTChanIO 
    let opts = defaultLiveProfileClientOpts
        behavior = defaultClientBehavior {
            clientOnHeader = atomically . writeTChan fileChan . Left
          , clientOnEvent = atomically . writeTChan fileChan . Right
          }

    cid <- startLiveClient logger opts (term, serverTerm) behavior
    writeLogFile term fileChan
    terminate serverTerm
  return serverTerm
  where

  writeLogFile :: Termination -> TChan (Either Header Event) -> IO ()
  writeLogFile term chan = withFile filename WriteMode $ \h -> 
    onExit (finishLog h) $ untilTerminated term $ do 
      mres <- atomically $ readTChan chan
      case mres of 
        Left hdr -> do 
          BS.hPut h . BSL.toStrict . runPut $ do
           putHeader hdr
           putDataBeginMarker
        Right e -> do 
          BS.hPut h . BSL.toStrict . runPut $ putEvent e
      hFlush h 
    where 
    finishLog h = BS.hPut h . BSL.toStrict $ runPut putDataEndMarker

  onExit m = bracket (pure ()) (const m) . const