module Profile.Live.Server(
  -- * Server side
    startLiveServer
  -- * Client side
  , ClientBehavior(..)
  , defaultClientBehavior
  , startLiveClient
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
import GHC.RTS.Events hiding (ThreadId)

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
  -> EventTypeChan -- ^ Channel for event types, should be closed as soon as first event occured (input)
  -> EventChan -- ^ Channel for events (input)
  -> IO ThreadId
startLiveServer logger LiveProfileOpts{..} termVar thisTerm _ eventTypeChan eventChan = forkIO $ do 
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
    closeOnExit p addr = bracket (return p) (\p' -> closeCon p' addr) . const 
    closeCon p addr = do 
      close p 
      logProf logger $ "Live profile: closed connection to " <> showl addr
    acceptCon p addr = do 
      logProf logger $ "Accepted connection from " <> showl addr
      _ <- listenThread p addr
      _ <- senderThread p addr
      return ()

    listenThread p addr = forkIO $ closeOnExit p addr $ 
      forever yield -- TODO: add service messages listener
    senderThread p addr = forkIO $ closeOnExit p addr $ 
      runEventSender logger p (fromMaybe maxBound eventMessageMaxSize) eventTypeChan eventChan

-- | Customisable behavior of the eventlog client
data ClientBehavior = ClientBehavior {
  clientOnHeader :: !(Header -> IO ())  -- ^ Callback that is called when the client receives full header of the remote eventlog
, clientOnEvent :: !(Event -> IO ()) -- ^ Callback that is called when the client receives a remote event
, clientOnService :: !(ServiceMsg -> IO ()) -- ^ Callback that is called when the client receives service message from the server
}

-- | Client behavior that does nothing
defaultClientBehavior :: ClientBehavior 
defaultClientBehavior = ClientBehavior {
    clientOnHeader = const $ return ()
  , clientOnEvent = const $ return ()
  , clientOnService = const $ return ()
  }

-- | Connect to remote app and recieve eventlog from it.
startLiveClient :: LoggerSet -- ^ Monitor logging messages sink
  -> LiveProfileClientOpts -- ^ Options for client side
  -> Termination  -- ^ When set we need to terminate self
  -> Termination  -- ^ When terminates we need to set this  
  -> ClientBehavior -- ^ User specified callbacks 
  -> IO ThreadId -- ^ Starts new thread that connects to remote host and 
startLiveClient logger LiveProfileClientOpts{..} termVar thisTerm cb = forkIO $ do 
  bracket socket clientClose $ \s -> connect s clientTargetAddr >> clientBody s
  logProf logger "Client thread terminated"
  where
  clientClose s = do 
    logProf logger "Client disconnected"
    close s 
  clientBody s = do 
    logProf logger $ "Client thread started and connected to " <> showl clientTargetAddr
    _ <- listenThread s
    _ <- senderThread s
    untilTerminated termVar () $ const yield
    putMVar thisTerm ()

  listenThread s = forkIO $ runEventListener logger s clientMessageTimeout cb
  senderThread _ = forkIO $ forever yield -- TODO: implement service msg passing

-- | Helper for creation listening threads that accepts eventlog messages from socket
runEventListener :: LoggerSet -- ^ Where to spam about everything
  -> ServerSocket -- ^ Which socket to listen for incoming messages
  -> NominalDiffTime -- ^ Timeout for collector internal state
  -> ClientBehavior -- ^ User specified callbacks 
  -> IO ()
runEventListener logger p msgTimeout ClientBehavior{..} = go (emptyMessageCollector msgTimeout)
  where 
  go collector = do 
    mmsg <- recieveMessage p
    case mmsg of 
      Left er -> do
        logProf logger er
        go collector
      Right msg -> do 
        logProf logger $ "RECEIVED MESSAGE:" <> showl msg
        curTime <- getCurrentTime
        let stepper = stepMessageCollector curTime msg
        let ((evs, collector'), msgs) = runWriter $ runStateT stepper collector 
        logProf' logger msgs
        case evs of 
          CollectorHeader h -> do 
            logProf logger $ "Collected full header with " 
              <> showl (length $ eventTypes h) <> " event types"
            clientOnHeader h 
          CollectorService smsg -> do 
            logProf logger $ "Got service message" <> showl smsg
            clientOnService smsg
          CollectorEvents es -> do
            forM_ es $ \e -> do
              logProf logger $ "Got event: " <> showl e
              clientOnEvent e
        collector' `deepseq` go collector'


-- | Helper for creation threads that sends events (and header) to the remote side
runEventSender :: LoggerSet -- ^ Where to spam about everthing
  -> ServerSocket -- ^ Socket where we send the messages about eventlog
  -> Word -- ^ Maximum size of datagram
  -> EventTypeChan -- ^ Channel to read eventlog header from
  -> EventChan -- ^ Channel to read events from
  -> IO ()
runEventSender logger p maxSize eventTypeChan eventChan = goHeader S.empty
  where 
  goHeader ets = do 
    met <- atomically $ readTBMChan eventTypeChan
    logProf logger $ "Read header from channel: " <> showl met
    case met of 
      Nothing -> do -- header is complete
        mapM_ (sendMessage p . ProfileHeader) $ mkHeaderMsgs ets 
        goMain $ emptySplitterState maxSize
      Just et -> do 
        let ets' = ets S.|> et 
        ets' `seq` goHeader ets'

  goMain splitter = do 
    me <- atomically $ readTBMChan eventChan
    logProf logger $ "Read event from channel: " <> showl me
    case me of 
      Nothing -> return ()
      Just e -> do 
        let ((msgs, splitter'), logMsgs) = runWriter $ runStateT (stepSplitter e) splitter
        logProf' logger logMsgs
        mapM_ (sendMessage p . ProfileEvent) msgs
        splitter' `deepseq` goMain splitter'

-- | Helper to read next message from the socket
recieveMessage :: ServerSocket -> IO (Either LogStr ProfileMsg)
recieveMessage p = do 
  lbytes <- receive p 4 (msgWaitAll <> msgNoSignal)
  (l :: Word32) <- BS.unsafeUseAsCString lbytes $ peekBE . castPtr
  msgbytes <- receive p (fromIntegral l) (msgWaitAll <> msgNoSignal)
  case deserialiseOrFail $ BS.fromStrict msgbytes of 
    Left er -> return . Left $ "Failed to deserialize message: " <> showl er 
        <> ", payload: " <> showl msgbytes
    Right msg -> return . Right $ msg 

-- | Helper to write message into socket
sendMessage :: ServerSocket -> ProfileMsg -> IO ()
sendMessage p msg = do
  let msgbytes = serialise msg 
  let lbytes = fromIntegral (BS.length msgbytes) :: Word32
  allocaArray 4 $ \(ptr :: Ptr CUChar) -> do 
    pokeBE (castPtr ptr) lbytes
    lbs <- BS.fromStrict <$> BS.unsafePackCStringLen (castPtr ptr, 4)
    void $ send p (BS.toStrict $ lbs <> msgbytes) msgNoSignal