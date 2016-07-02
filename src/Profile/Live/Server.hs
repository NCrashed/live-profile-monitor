module Profile.Live.Server(
    startLiveServer
  ) where 

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMChan
import Control.DeepSeq
import Control.Exception 
import Control.Monad 
import Control.Monad.State.Strict
import Control.Monad.Writer.Strict (runWriter)
import Data.Binary.Serialise.CBOR
import Data.IORef 
import Data.Maybe
import Data.Storable.Endian
import Data.Time.Clock
import Data.Word 
import Foreign hiding (void)
import Foreign.C.Types 

import Profile.Live.Options 
import Profile.Live.State 

import System.Socket 
import System.Socket.Family.Inet6
import System.Socket.Protocol.TCP
import System.Socket.Type.Stream
import System.Timeout

import Profile.Live.Server.Collector
import Profile.Live.Server.Message 
import Profile.Live.Server.Splitter

import qualified Data.ByteString.Lazy as BS 
import qualified Data.ByteString.Unsafe as BS 
import qualified Data.Sequence as S 

-- | Socket type that is used for the server
type ServerSocket = Socket Inet6 Stream TCP

-- | Starts TCP server that listens on particular port which profiling 
-- clients connect with. 
startLiveServer :: LoggerSet -- ^ Monitor logger
  -> LiveProfileOpts -- ^ Options of the monitor
  -> Termination  -- ^ When set we need to terminate self
  -> Termination  -- ^ When terminates we need to set this  
  -> IORef Bool -- ^ Holds flag whether the monitor is paused
  -> EventTypeChan -- ^ Channel for event types, closed as soon as first event occured
  -> EventChan -- ^ Channel for events
  -> IO ThreadId
startLiveServer logger LiveProfileOpts{..} termVar thisTerm _ eventTypeChan eventChan = do 
  forkIO $ do 
    logProf logger "Server thread started"
    withSocket $ \s -> untilTerminated termVar () $ const $ acceptAndHandle s
    putMVar thisTerm ()
    logProf logger "Server thread terminated"
  where
  withSocket m = bracket (socket :: IO ServerSocket) close $ \s -> do 
    setSocketOption s (ReuseAddress True)
    setSocketOption s (V6Only False)
    bind s (SocketAddressInet6 inet6Any eventLogListenPort 0 0)
    listen s 0 -- implentation chooses the queue size
    logProf logger "Server started to listen"
    m s

  acceptAndHandle :: ServerSocket -> IO ()
  acceptAndHandle s = do  
    mres <- timeout 1000000 $ accept s
    whenJust mres $ uncurry acceptCon
    where 
    closeOnExit p addr = bracket (return p) (\p -> closeCon p addr) . const 
    closeCon p addr = do 
      close p 
      logProf logger $ "Live profile: closed connection to " <> toLogStr (show addr)
    acceptCon p addr = do 
      logProf logger $ "Accepted connection from " <> toLogStr (show addr)
      listenThread p addr
      senderThread p addr
      return ()

    listenThread p addr = forkIO $ closeOnExit p addr $ go (emptyMessageCollector eventLogMessageTimeout)
      where 
      go collector = do 
        mmsg <- recieveMessage p
        case mmsg of 
          Nothing -> go collector
          Just msg -> do 
            logProf logger $ "RECIEVED MESSAGE:" <> toLogStr (show msg)
            curTime <- getCurrentTime
            let stepper = stepMessageCollector curTime msg
            let ((evs, collector'), msgs) = runWriter $ runStateT stepper collector 
            logProf' logger msgs
            case evs of 
              Left smsg -> do 
                logProf logger $ "Got service msg: " <> toLogStr (show smsg)
              Right evts -> do 
                forM_ evts $ \evt -> logProf logger $ "Got event: " <> toLogStr (show evt)
            collector' `deepseq` go collector'

    senderThread p addr = forkIO $ closeOnExit p addr $ goHeader S.empty
      where 
      goHeader ets = do 
        met <- atomically $ readTBMChan eventTypeChan
        logProf logger $ "Readed from channel: " <> toLogStr (show met)
        case met of 
          -- header is complete
          Nothing -> do
            mapM_ (sendMessage p . ProfileHeader) $ mkHeaderMsgs ets 
            goMain . emptySplitterState $ fromMaybe maxBound eventMessageMaxSize 
          Just et -> do 
            let ets' = ets S.|> et 
            ets' `seq` goHeader ets'

      goMain splitter = forever yield

    recieveMessage p = do 
      lbytes <- receive p 4 msgWaitAll
      (l :: Word32) <- BS.unsafeUseAsCString lbytes $ peekBE . castPtr
      msgbytes <- receive p (fromIntegral l) msgWaitAll
      case deserialiseOrFail $ BS.fromStrict msgbytes of 
        Left er -> do
          logProf logger $ "Failed to deserialize message: " <> toLogStr (show er) 
            <> ", payload: " <> toLogStr (show msgbytes)
          return Nothing
        Right msg -> return msg 

    sendMessage p msg = do 
      logProf logger $ "Sending message " <> toLogStr (show msg)
      let msgbytes = serialise msg 
      let lbytes = fromIntegral (BS.length msgbytes) :: Word32
      allocaArray 4 $ \(ptr :: Ptr CUChar) -> do 
        pokeBE (castPtr ptr) lbytes
        lbs <- BS.fromStrict <$> BS.unsafePackCStringLen (castPtr ptr, 4)
        void $ send p (BS.toStrict $ lbs <> msgbytes) mempty