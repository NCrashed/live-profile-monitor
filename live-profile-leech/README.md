live-profile-leech
==================

The small library that intented to be easily injected in user software. It transfers event log through file pipe for live-profile-monitor server.

Usage
=====

* You need [patched GHC](https://github.com/NCrashed/ghc) that is able to store events
in memory and provides facilities to take them from RTS side.

* Add the library as dependency.

* Wrap main thread into `startLeech` and `stopLeech`, for example:

``` haskell
import Control.Exception (bracket)
import Control.Monad (forM_)
import Debug.Trace 
import Profile.Live.Leech

main :: IO ()
main = bracket (startLeech defaultLeechOptions) (const stopLeech) $ const $ do 
  forM_ [0 .. 1000000 :: Int] $ \i -> traceEventIO $ "MyEvent" ++ show i
```

* Also you can trigger custom markers that are used in profiling tools:

``` haskell
-- | Record start of user event
--
-- Note: name of event should correspond one that was used in 'traceStopLiveEvent'
traceStartLiveEvent :: String -- ^ Event name
  -> a -> a 

-- | Record end of user event
-- 
-- Note: name of event should correspond one that was used in 'traceStartLiveEvent'
traceStopLiveEvent :: String -- ^ Event name
  -> a -> a 

-- | Applicative version of 'traceStartLiveEvent' that can be used in do notation
-- 
-- Note: name of event should correspond one that was used in 'traceStopLiveEventM'
traceStartLiveEventM :: Applicative f => String -- ^ Name of event
  -> f ()

-- | Applicative version of 'traceStopLiveEvent' that can be used in do notation
-- 
-- Note: name of event should correspond one that was used in 'traceStartLiveEventM'
traceStopLiveEventM :: Applicative f => String -- ^ Name of event
  -> f ()

-- | Tags action with event, that starts when the inner computation starts and
-- ends when it ends.
withLiveEventM :: Applicative f => String -- ^ Name of event
  -> f a -> f a
  
-- | Tags action with event, that starts when the inner computation starts and
-- ends when it ends.
--
-- Note: the version is exception safe unlike the `withLiveEventM`
withLiveEventIO :: String -- ^ Name of event
  -> IO a -> IO a
```