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

import qualified Data.ByteString as BS 
import qualified Data.ByteString.Lazy as BSL

receiveRemoteEventlog :: FilePath -> IO ()
receiveRemoteEventlog filename = void . forkIO $ do 
  logger <- newStdoutLoggerSet defaultBufSize
  term <- newEmptyMVar
  serverTerm <- newEmptyMVar

  fileChan <- newTChanIO 
  let opts = defaultLiveProfileClientOpts
      behavior = defaultClientBehavior {
          clientOnHeader = atomically . writeTChan fileChan . Left
        , clientOnEvent = atomically . writeTChan fileChan . Right
        }

  _ <- startLiveClient logger opts term serverTerm behavior
  writeLogFile serverTerm fileChan
  where

  writeLogFile :: Termination -> TChan (Either Header Event) -> IO ()
  writeLogFile term chan = withFile filename WriteMode $ \h -> 
    onExit (finishLog h) $ untilTerminated term () $ const $ do 
      mres <- atomically $ readTChan chan
      case mres of 
        Left hdr -> do 
          BS.hPut h . BSL.toStrict . runPut $ do
           putHeader hdr
           putDataBeginMarker
          --return ()
        Right e -> do 
          --putStrLn $ show e 
          BS.hPut h . BSL.toStrict . runPut $ putEvent e
          --hPutStrLn h $ show e
      hFlush h 
    where 
    finishLog h = BS.hPut h . BSL.toStrict $ runPut putDataEndMarker

  onExit m = bracket (pure ()) (const m) . const