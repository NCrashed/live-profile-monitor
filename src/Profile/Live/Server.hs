module Profile.Live.Server(
    startLiveServer
  ) where 

import Control.Concurrent
import Control.DeepSeq
import Control.Exception 
import Control.Monad 
import Control.Monad.State.Strict
import Control.Monad.Writer.Strict (runWriter)
import Data.Binary.Serialise.CBOR 
import Data.IORef 
import Data.Storable.Endian
import Data.Time.Clock
import Data.Word 
import Foreign 

import Profile.Live.Options 
import Profile.Live.State 

import System.Socket 
import System.Socket.Family.Inet6
import System.Socket.Protocol.TCP
import System.Socket.Type.Stream
import System.Timeout

import Profile.Live.Server.Collector

import qualified Data.ByteString.Lazy as BS 
import qualified Data.ByteString.Unsafe as BS 

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
startLiveServer logger LiveProfileOpts{..} termVar thisTerm _ _ _ = do 
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
  acceptAndHandle s = bracket (timeout 1000000 $ accept s) closeCon acceptCon
    where 
    closeCon mres = whenJust mres $ \(p, addr) -> do 
      close p 
      logProf logger $ "Live profile: closed connection to " <> toLogStr (show addr)
    acceptCon mres = whenJust mres $ \(p, addr) -> do 
      logProf logger $ "Accepted connection from " <> toLogStr (show addr)
      listenThread p 
      senderThread p
      return ()

    listenThread p = forkIO $ go (emptyMessageCollector eventLogMessageTimeout)
      where 
      go collector = do 
        mmsg <- recieveMessage p
        case mmsg of 
          Nothing -> go collector
          Just msg -> do 
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

    senderThread p = forkIO $ forever yield