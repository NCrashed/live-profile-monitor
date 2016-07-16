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

  ph <- spawnCommand "hs-live-profile ./.stack-work/dist/*/Cabal-*/build/test-leech/test-leech"

  threadDelay 1000000
  flag <- doesFileExist "test.eventlog"
  when flag $ removeFile "test.eventlog"
  receiveRemoteEventlog "test.eventlog"

  print =<< waitForProcess ph