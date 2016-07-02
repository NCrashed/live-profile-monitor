module Test.Client(
    receiveRemoteEventlog
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad 
import System.Log.FastLogger
import GHC.RTS.Events 
import System.IO

import Profile.Live.Options 
import Profile.Live.Server
import Profile.Live.State 

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
  writeLogFile term chan = withFile filename WriteMode $ \h -> untilTerminated term () $ const $ do 
    mres <- atomically $ readTChan chan
    case mres of 
      Left hdr -> do 
        hPutStrLn h $ show hdr
      Right e -> do 
        hPutStrLn h $ show e
    hFlush h 