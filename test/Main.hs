module Main where

import Control.Exception (bracket)
import Profile.Live
import Debug.Trace 

main = bracket (initLiveProfile defaultLiveProfileOpts) stopLiveProfile $ const $ do
  traceEventIO "MyEvent"
