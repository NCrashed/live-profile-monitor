-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Protocol.Utils
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Helpers to implement client/server for the live profiling protocol.
--
------------------------------------------------------------------------------
module Profile.Live.Protocol.Utils(
    ReceiveMsgError(..)
  , recieveMessage
  , sendMessage
  -- * General utils
  , printExceptions
  , whenJust
  , logProf
  , logProf'
  , labelCurrentThread
  ) where 

import Control.Concurrent
import Control.Exception 
import Control.Monad.Except 
import Data.Binary.Serialise.CBOR
import Data.Monoid 
import Data.Storable.Endian
import Data.Word
import Foreign hiding (void)
import Foreign.C.Types 
import GHC.Conc.Sync (labelThread)
import GHC.Generics
import System.Log.FastLogger
import System.Socket 

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BS 
import qualified Data.ByteString.Unsafe as BS 

import Profile.Live.Protocol.Message 
import Profile.Live.Protocol.State

-- | Special type of errors that 'recieveMessage' can produce
data ReceiveMsgError = 
    MsgDeserialisationFail !LogStr
  | MsgEndOfInput
  deriving (Generic)

-- | Helper to read next message from the socket
recieveMessage :: Socket i str p -> IO (Either ReceiveMsgError ProfileMsg)
recieveMessage p = runExceptT $ do 
  lbytes <- liftIO $ receive p 4 msgNoSignal
  guardEndOfInput lbytes 
  (l :: Word32) <- liftIO $ BS.unsafeUseAsCString lbytes $ peekBE . castPtr
  msgbytes <- liftIO $ receive p (fromIntegral l) msgNoSignal
  guardEndOfInput msgbytes 
  case deserialiseOrFail $ BS.fromStrict msgbytes of 
    Left er -> throwError . MsgDeserialisationFail $ "Failed to deserialize message: " 
        <> showl er <> ", payload: " <> showl msgbytes
    Right msg -> return msg 
  where 
  guardEndOfInput bs | B.null bs = throwError MsgEndOfInput
                     | otherwise = return ()

-- | Helper to write message into socket
sendMessage :: Socket i str p -> ProfileMsg -> IO ()
sendMessage p msg = do
  let msgbytes = serialise msg 
  let lbytes = fromIntegral (BS.length msgbytes) :: Word32
  allocaArray 4 $ \(ptr :: Ptr CUChar) -> do 
    pokeBE (castPtr ptr) lbytes
    lbs <- BS.fromStrict <$> BS.unsafePackCStringLen (castPtr ptr, 4)
    void $ send p (BS.toStrict $ lbs <> msgbytes) msgNoSignal

-- | Helper that prints all exceptions passed through
printExceptions :: String -> IO a -> IO a 
printExceptions s m = catch m $ \(e :: SomeException) -> do
  putStrLn $ s ++ ":" ++ show e 
  throw e 

-- | Do thing only when value is 'Just'
whenJust :: Applicative m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing _ = pure ()
whenJust (Just x) m = m x 

-- | Helper to log in live profiler
logProf :: LoggerSet -> LogStr -> IO ()
logProf logger msg = pushLogStrLn logger $ "Live profiler: " <> msg

-- | Helper to log in live profiler, without prefix
logProf' :: LoggerSet -> LogStr -> IO ()
logProf' = pushLogStr

-- | Assign label to current thread
labelCurrentThread :: String -> IO ()
labelCurrentThread name = do 
  tid <- myThreadId 
  labelThread tid ("LiveProfile_" <> name)