{-# LANGUAGE ForeignFunctionInterface #-}
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

foreign import ccall "startProfiler" startProfiler :: IO ()
foreign import ccall "stopProfiler" stopProfiler :: IO ()

main :: IO ()
main = do
  startProfiler
  forM_ [0 .. 1000000] $ \i -> traceEventIO $ "MyEvent" ++ show i
  stopProfiler

{-  runEventlogSerialisationTests

  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile defaultLiveProfileOpts logger) stopLiveProfile $ const $ do
    flag <- doesFileExist "test.eventlog"
    when flag $ removeFile "test.eventlog"
    receiveRemoteEventlog "test.eventlog"
    forM_ [0 .. 10000] $ \i -> traceEventIO $ "MyEvent" ++ show i
    threadDelay 30000000
-}