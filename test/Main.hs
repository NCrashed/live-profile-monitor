{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import Control.Concurrent
import Control.Monad 
import System.Log.FastLogger

import Test.Client
import Test.Put 

import System.Directory
import System.Process 

import Foreign 
import Foreign.C 

main :: IO ()
main = do 
  runEventlogSerialisationTests

  flag <- doesFileExist "test.eventlog"
  when flag $ removeFile "test.eventlog"
  receiveRemoteEventlog "test.eventlog"

  callCommand "hs-live-profile ./.stack-work/dist/*/Cabal-*/build/test-leech/test-leech"
  -- TODO: make termination protocol

{-  runEventlogSerialisationTests

  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile defaultLiveProfileOpts logger) stopLiveProfile $ const $ do
    flag <- doesFileExist "test.eventlog"
    when flag $ removeFile "test.eventlog"
    receiveRemoteEventlog "test.eventlog"
    forM_ [0 .. 10000] $ \i -> traceEventIO $ "MyEvent" ++ show i
    threadDelay 30000000
-}