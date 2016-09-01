{-|
Module      : Profile.Live.Leech
Description : Utilities to control leech thread for live profiler.
Copyright   : (c) Anton Gushcha, 2016
License     : BSD3
Maintainer  : ncrashed@gmail.com
Stability   : experimental
Portability : POSIX

The leech is thread that is run on application side we profile. The thread is 
system thread in C universe (not Haskell thread). Its main purpose to pass
RTS events into external process of live profiler.

You need to start leech thread in your application to use live profiler. 

Example of usage:
@
import Control.Exception (bracket)
import Control.Monad (forM_)
import Debug.Trace (traceEventIO)
import Profile.Live.Leech

main :: IO ()
main = bracket (startLeech defaultLeechOptions) (const stopLeech) $ const $ do 
  forM_ [0 .. 1000000] $ \i -> traceEventIO $ "MyEvent" ++ show i
@

-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE CPP #-}
module Profile.Live.Leech(
  -- * Options
    LeechOptions
  , defaultLeechOptions
  , leechPipeName
  , leechBufferSize
  , leechDisableEventlogFile
  -- * Start/stop leeching events
  , startLeech
  , stopLeech
  -- * User events and helpers
  , traceStartLiveEvent
  , traceStopLiveEvent
  , traceStartLiveEventM
  , traceStopLiveEventM
  , withLiveEventM
  , withLiveEventIO
  ) where 

import Control.Exception (bracket)
import Data.Word 
import Debug.Trace (trace, traceM)
import Foreign.C 
import Foreign.Marshal.Utils 

-- | Configuration of eventlog pipe located
-- on side of application being profiled.
data LeechOptions = LeechOptions {
  -- | Name of pipe file that is used to pass events
  -- to live server process
  leechPipeName :: !FilePath
  -- | Size of RTS buffers to use, leech will restore
  -- default values after termination.
, leechBufferSize :: !Word64
  -- | Whether to disable output to eventlog file or not.
  -- Leech will restore default value after termination.
, leechDisableEventlogFile :: !Bool
}

-- | Reasonable default options for leech thread
defaultLeechOptions :: LeechOptions
defaultLeechOptions = LeechOptions {
#ifdef mingw32_HOST_OS
    leechPipeName = "\\\\.\\pipe\\events"
#else
    leechPipeName = "events.pipe"
#endif
  , leechBufferSize = 1024
  , leechDisableEventlogFile = True
  } 

foreign import ccall "startLeech" c_startLeech :: CString -> Word64 -> CInt -> IO ()
foreign import ccall "stopLeech" c_stopLeech :: IO ()

-- | Start leech thread that pipes eventlog to external process in background.
startLeech :: LeechOptions -> IO ()
startLeech LeechOptions{..} = withCString leechPipeName $ \pname -> do
  c_startLeech pname leechBufferSize (fromBool leechDisableEventlogFile)

-- | Stopping leech thread and restore all changed RTS options
stopLeech :: IO ()
stopLeech = c_stopLeech

-- | Record start of user event
--
-- Note: name of event should correspond one that was used in 'traceStopLiveEvent'
traceStartLiveEvent :: String -- ^ Event name
  -> a -> a 
traceStartLiveEvent name = trace ("START " ++ name)

-- | Record end of user event
-- 
-- Note: name of event should correspond one that was used in 'traceStartLiveEvent'
traceStopLiveEvent :: String -- ^ Event name
  -> a -> a 
traceStopLiveEvent name = trace ("END " ++ name)

-- | Applicative version of 'traceStartLiveEvent' that can be used in do notation
-- 
-- Note: name of event should correspond one that was used in 'traceStopLiveEventM'
traceStartLiveEventM :: Applicative f => String -- ^ Name of event
  -> f ()
traceStartLiveEventM name = traceM ("START " ++ name)

-- | Applicative version of 'traceStopLiveEvent' that can be used in do notation
-- 
-- Note: name of event should correspond one that was used in 'traceStartLiveEventM'
traceStopLiveEventM :: Applicative f => String -- ^ Name of event
  -> f ()
traceStopLiveEventM name = traceM ("END " ++ name)

-- | Tags action with event, that starts when the inner computation starts and
-- ends when it ends.
withLiveEventM :: Applicative f => String -- ^ Name of event
  -> f a -> f a
withLiveEventM name f = 
  traceStartLiveEventM name 
  *> f <*
  traceStopLiveEventM name 

-- | Tags action with event, that starts when the inner computation starts and
-- ends when it ends.
--
-- Note: the version is exception safe unlike the `withLiveEventM`
withLiveEventIO :: String -- ^ Name of event
  -> IO a -> IO a
withLiveEventIO name = bracket (traceStartLiveEventM name) (const $ traceStopLiveEventM name) . const