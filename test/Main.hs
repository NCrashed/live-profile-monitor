{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import Control.Concurrent
import Control.Monad 
import System.Log.FastLogger

import Test.Client
import Test.Put 

import System.Directory

import Foreign 
import Foreign.C 

import Control.Exception (bracket)
import Debug.Trace 
import Profile.Live.Leech

main :: IO ()
main = bracket (startLeech defaultLeechOptions) (const stopLeech) $ const $ do 
  forM_ [0 .. 1000000] $ \i -> traceEventIO $ "MyEvent" ++ show i

{-  runEventlogSerialisationTests

  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile defaultLiveProfileOpts logger) stopLiveProfile $ const $ do
    flag <- doesFileExist "test.eventlog"
    when flag $ removeFile "test.eventlog"
    receiveRemoteEventlog "test.eventlog"
    forM_ [0 .. 10000] $ \i -> traceEventIO $ "MyEvent" ++ show i
    threadDelay 30000000
-}