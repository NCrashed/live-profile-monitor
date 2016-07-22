module Profile.Live.Server(
  -- * Server side
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
import Data.IORef 
import Data.Maybe
import Data.Monoid 
import System.Log.FastLogger

import Profile.Live.Options 
import Profile.Live.State 

import System.Socket 
import System.Socket.Family.Inet6
import System.Socket.Protocol.TCP
import System.Socket.Type.Stream

import Profile.Live.Protocol.Message 
import Profile.Live.Protocol.Splitter
import Profile.Live.Protocol.State 
import Profile.Live.Protocol.Utils
import Profile.Live.Termination 

import qualified Data.Sequence as S 

-- | Socket type that is used for the server
type ServerSocket = Socket Inet6 Stream TCP

-- | Starts TCP server that listens on particular port which profiling 
-- clients connect with. 
startLiveServer :: LoggerSet -- ^ Monitor logger
  -> LiveProfileOpts -- ^ Options of the monitor
  -> TerminationPair  -- ^ Termination protocol
  -> IORef Bool -- ^ Holds flag whether the monitor is paused
  -> EventTypeChan -- ^ Channel for event types, should be closed as soon as first event occured (input)
  -> EventChan -- ^ Channel for events (input)
  -> IORef EventlogState -- ^ Ref with relevant state of eventlog
  -> IO ThreadId
startLiveServer logger LiveProfileOpts{..} term pausedRef eventTypeChan eventChan stateRef = forkIO $ printExceptions "Live server" $ do 
  labelCurrentThread "Server"
  logProf logger "Server thread started"
  withSocket $ \s -> untilTerminatedPair term $ acceptAndHandle s
  logProf logger "Server thread terminated"
  where
  withSocket m = bracket (socket :: IO ServerSocket) close $ \s -> do 
    setSocketOption s (ReuseAddress True)
    setSocketOption s (V6Only False)
    bind s (SocketAddressInet6 inet6Any eventLogListenPort 0 0)
    listen s 0 -- implementation chooses the queue size
    logProf logger "Server started to listen"
    m s

  acceptAndHandle :: ServerSocket -> IO ()
  acceptAndHandle s = forever $ do  
    res <- accept s
    uncurry acceptCon res
    where 
    closeOnExit p addr = bracket (return p) (\p' -> closeCon p' addr) . const 
    closeCon p addr = do 
      close p 
      logProf logger $ "Live profile: closed connection to " <> showl addr
    acceptCon p addr = do 
      logProf logger $ "Accepted connection from " <> showl addr
      -- _ <- listenThread p addr
      let splitter = emptySplitterState $ fromMaybe maxBound eventMessageMaxSize
      splitter' <- sendEventlogState logger p splitter stateRef
      _ <- senderThread p addr splitter'
      return ()

    --listenThread p addr = forkIO $ closeOnExit p addr $ 
    --  forever yield -- TODO: add service messages listener
    senderThread p addr splitter = forkIO $ closeOnExit p addr $ do
      labelCurrentThread $ "Sender_" <> show addr
      runEventSender logger p splitter pausedRef eventTypeChan eventChan stateRef

-- Send full state to the remote host
sendEventlogState :: LoggerSet 
  -> ServerSocket
  -> SplitterState
  -> IORef EventlogState
  -> IO SplitterState
sendEventlogState logger p splitter stateRef = do 
  st <- readIORef stateRef 
  let action = stepSplitter $ Left st 
      ((msgs, splitter'), logMsgs) = runWriter $ runStateT action splitter
  logProf' logger logMsgs
  mapM_ (sendMessage p) msgs
  return splitter'

-- | Helper for creation threads that sends events (and header) to the remote side
runEventSender :: LoggerSet -- ^ Where to spam about everthing
  -> ServerSocket -- ^ Socket where we send the messages about eventlog
  -> SplitterState
  -> IORef Bool -- ^ When value set to true, the sender won't send events to remote side
  -> EventTypeChan -- ^ Channel to read eventlog header from
  -> EventChan -- ^ Channel to read events from
  -> IORef EventlogState -- ^ Reference with global eventlog state
  -> IO ()
runEventSender logger p initialSplitter pausedRef eventTypeChan eventChan stateRef = goHeader S.empty
  where 
  goHeader ets = do 
    met <- atomically $ readTBMChan eventTypeChan
    case met of 
      Nothing -> do -- header is complete
        let msgs = mkHeaderMsgs ets
        mapM_ (sendMessage p . ProfileHeader) msgs
        goMain initialSplitter False
      Just et -> do 
        let ets' = ets S.|> et 
        ets' `seq` goHeader ets'

  goMain splitter oldPaused = do 
    me <- atomically $ readTBMChan eventChan
    case me of 
      Nothing -> return ()
      Just e -> do
        paused <- readIORef pausedRef 
        splitter' <- if (paused == oldPaused) -- After pause everything might be different
          then return splitter
          else sendEventlogState logger p splitter stateRef
        if paused 
          then splitter' `deepseq` goMain splitter' True
          else do 
            let 
              action = stepSplitter $ Right e 
              ((msgs, splitter''), logMsgs) = runWriter $ runStateT action splitter'
            logProf' logger logMsgs
            mapM_ (sendMessage p) msgs
            splitter'' `deepseq` goMain splitter'' False