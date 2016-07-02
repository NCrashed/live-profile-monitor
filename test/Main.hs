module Main where

import Control.Concurrent
import Control.Exception (bracket)
import Control.Monad 
import Debug.Trace 
import Profile.Live
import System.Log.FastLogger

import Test.Client
import System.Socket.Family.Inet6

import System.Directory

main = do
  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile defaultLiveProfileOpts logger) stopLiveProfile $ const $ do
    flag <- doesFileExist "test.eventlog"
    when flag $ removeFile "test.eventlog"
    recieveRemoteEventlog (SocketAddressInet6 inet6Loopback 8242 0 0) "test.eventlog"
    void $ replicateM 100000 $ traceEventIO "MyEvent"
    threadDelay 10000000
