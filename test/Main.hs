module Main where

import Control.Exception (bracket)
import Profile.Live
import Debug.Trace 
import Control.Monad 
import Control.Concurrent

main = bracket (initLiveProfile defaultLiveProfileOpts) stopLiveProfile $ const $ do
  void $ replicateM 5000 $ putStrLn "MY" >> traceEventIO "MyEvent"
