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
import Data.Word
import GHC.Conc.Sync (labelThread)
import GHC.Generics
import System.Log.FastLogger
import System.Socket 

import qualified Data.Binary.Get as G 
import qualified Data.Binary.Put as P
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BS 

import Profile.Live.Protocol.Message 
import Profile.Live.Protocol.State

-- | Special type of errors that 'recieveMessage' can produce
data ReceiveMsgError = 
    MsgDeserialisationFail !LogStr
  | MsgEndOfInput
  deriving (Generic)

-- | Helper to receive all requested bytes
receiveWaitAll :: Socket i str p -> Int -> IO B.ByteString 
--receiveWaitAll p size = receive p size (msgNoSignal <> msgWaitAll)
receiveWaitAll p size = go mempty size
  where 
  go !bs !n 
    | n < 0 = fail "Received too much"
    | n > 0 = do 
      bs' <- receive p n msgNoSignal
      go (bs <> bs') (n - B.length bs')
    | otherwise = return bs 

-- | Helper to read next message from the socket
recieveMessage :: Socket i str p -> IO (Either ReceiveMsgError ProfileMsg)
recieveMessage p = runExceptT $ do 
  lbytes <- liftIO $ receiveWaitAll p 4
  guardEndOfInput lbytes

  let (l :: Word32) = G.runGet G.getWord32be $ BS.fromStrict lbytes
  liftIO $ putStrLn $ "Receiving " <> show l <> " bytes... " <> show lbytes 
  
  msgbytes <- liftIO $ receiveWaitAll p (fromIntegral l)
  guardEndOfInput msgbytes 
  case deserialiseOrFail $ BS.fromStrict msgbytes of 
    Left er -> throwError . MsgDeserialisationFail $ "Failed to deserialize message: " 
        <> showl er <> ", payload: " <> showl msgbytes
    Right msg -> return msg 
  where 
  guardEndOfInput bs | B.null bs = throwError MsgEndOfInput
                     | otherwise = return ()

-- | Send all messages to remote host
sendAll :: Socket i str p -> B.ByteString -> IO ()
sendAll p = go
  where 
  go !bs 
    | B.null bs = return ()
    | otherwise = do 
      i <- send p bs msgNoSignal
      go (B.drop (fromIntegral i) bs)

-- | Helper to write message into socket
sendMessage :: Socket i str p -> ProfileMsg -> IO () 
sendMessage p msg = do
  let bytes = serialise msg 
  let l = fromIntegral (BS.length bytes) :: Word32
  let lbytes = P.runPut $ P.putWord32be l
  let fullmsg = lbytes <> bytes
  sendAll p (BS.toStrict fullmsg)

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