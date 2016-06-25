module Main where

import Control.Exception (bracket)
import Profile.Live
import Debug.Trace 
import Control.Monad 
import Control.Concurrent

import Test.Client
import System.Socket.Family.Inet6

import System.Directory

main = bracket (initLiveProfile defaultLiveProfileOpts) stopLiveProfile $ const $ do
  flag <- doesFileExist "test.eventlog"
  when flag $ removeFile "test.eventlog"
  recieveRemoteEventlog (SocketAddressInet6 inet6Loopback 8242 0 0) "test.eventlog"
  void $ replicateM 100000 $ traceEventIO "MyEvent"
