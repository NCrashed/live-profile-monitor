module Profile.Live.Pipe(
    PipeOptions(..)
  , startPipe
  ) where 

import Control.Monad.IO.Class 
import Foreign hiding (void)
import Foreign.C 

import qualified Data.ByteString as BS

-- | Pipe OS thread configuration
data PipeOptions = PipeOptions {
  -- | Name of FIFO file on linux or named pipe on Windows
  pipeName :: !FilePath
  -- | Size of buffer, the maximum size of data passed in 'pipeCallback'
, pipeBufferSize :: !Word64
  -- | Callback on data arrival
, pipeCallback :: !(BS.ByteString -> IO ())
}

-- | Internal type of pipe callback
type PipeCallback = Ptr CUChar -> CInt -> IO ()

foreign import ccall "startProfilerPipe" c_startPipe :: CString -> Word64 -> FunPtr PipeCallback -> IO ()
foreign import ccall "stopProfilerPipe" c_stopPipe :: IO ()

foreign import ccall "wrapper" createPipeCallback :: PipeCallback -> IO (FunPtr PipeCallback)

-- | Start separate OS thread that will pipe data from FIFO/named pipe
-- and pass them to specified callback.
--
-- Returns action which call stops the pipe and frees its memory.
startPipe :: MonadIO m => PipeOptions -> m (IO ())
startPipe PipeOptions{..} = liftIO $ withCString pipeName $ \pn -> do 
  cb <- createPipeCallback $ \ptr i -> do
    bs <- BS.packCStringLen (castPtr ptr, fromIntegral i)
    pipeCallback bs 
  c_startPipe pn pipeBufferSize cb
  return $ do
    c_stopPipe
    freeHaskellFunPtr cb