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
  ) where 

import Data.Word 
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