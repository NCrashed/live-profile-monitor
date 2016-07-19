{-# LANGUAGE ForeignFunctionInterface #-}
module Main where

import Control.Concurrent
import Control.Monad 
import System.Log.FastLogger
import System.Environment

import Test.Client
import Test.Put 

import System.Directory
import System.Process 

import Foreign 
import Foreign.C 

main :: IO ()
main = do 
  runEventlogSerialisationTests
  
  [path] <- getArgs
  ph <- spawnCommand $ "hs-live-profile --RTS " ++ path ++ " +RTS -lm -N4"

  threadDelay 1000000
  flag <- doesFileExist "test.eventlog"
  when flag $ removeFile "test.eventlog"

  term <- newEmptyMVar
  clientTerm <- receiveRemoteEventlog term "test.eventlog"

  print =<< waitForProcess ph
  putMVar term ()
  takeMVar clientTerm
