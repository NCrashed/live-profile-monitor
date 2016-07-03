module Main where

import Control.Concurrent
import Control.Exception (bracket)
import Control.Monad 
import Debug.Trace 
import Profile.Live
import System.Log.FastLogger

import Test.Client
import Test.Put 

import System.Directory

main :: IO ()
main = do
  runEventlogSerialisationTests

  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile defaultLiveProfileOpts logger) stopLiveProfile $ const $ do
    flag <- doesFileExist "test.eventlog"
    when flag $ removeFile "test.eventlog"
    receiveRemoteEventlog "test.eventlog"
    void $ replicateM 100000 $ traceEventIO "MyEvent"
    threadDelay 10000000
