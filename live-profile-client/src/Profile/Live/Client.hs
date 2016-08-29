-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Client
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Client side utilities to receive data from remote profiling server. 
--
------------------------------------------------------------------------------
module Profile.Live.Client(
  -- * Options
    LiveProfileClientOpts(..)
  , defaultLiveProfileClientOpts
  -- * Client API
  , ClientBehavior(..)
  , defaultClientBehavior
  , startLiveClient
  ) where 

import Control.Concurrent
import Control.DeepSeq 
import Control.Exception 
import Control.Monad.State.Strict 
import Control.Monad.Writer.Strict
import Data.Time 
import GHC.Generics
import GHC.RTS.Events hiding (ThreadId)
import System.Log.FastLogger

import System.Socket
import System.Socket.Family.Inet6
import System.Socket.Protocol.TCP
import System.Socket.Type.Stream

import Profile.Live.Protocol.Collector
import Profile.Live.Protocol.Message 
import Profile.Live.Protocol.State 
import Profile.Live.Protocol.Utils
import Profile.Live.Termination 

-- | Options for live profile client side
data LiveProfileClientOpts = LiveProfileClientOpts {
  -- | Target address where the client connects to 
    clientTargetAddr :: !(SocketAddress Inet6)
  -- | How long to wait until the server drops outdated sequences of partial messages and blocks.
  , clientMessageTimeout :: !NominalDiffTime
  } deriving Show 

-- | Default values for options of live profiler client
defaultLiveProfileClientOpts :: LiveProfileClientOpts
defaultLiveProfileClientOpts = LiveProfileClientOpts {
    clientTargetAddr = SocketAddressInet6 inet6Loopback 8242 0 0
  , clientMessageTimeout = fromIntegral (360 :: Int)
  }

-- | Socket type that is used for the server
type ClientSocket = Socket Inet6 Stream TCP

-- | Customisable behavior of the eventlog client
data ClientBehavior = ClientBehavior {
  clientOnHeader :: !(Header -> IO ())  -- ^ Callback that is called when the client receives full header of the remote eventlog
, clientOnEvent :: !(Event -> IO ()) -- ^ Callback that is called when the client receives a remote event
, clientOnService :: !(ServiceMsg -> IO ()) -- ^ Callback that is called when the client receives service message from the server
, clientOnState :: !(EventlogState -> IO ()) -- ^ Callback that is called when the client receives dump of eventlog alive objects
, clientOnExit :: !(Maybe SomeException -> IO ()) -- ^ Callback that is called when client thread is terminated by exception or by normal way.
} deriving (Generic)

-- | Client behavior that does nothing
defaultClientBehavior :: ClientBehavior 
defaultClientBehavior = ClientBehavior {
    clientOnHeader = const $ return ()
  , clientOnEvent = const $ return ()
  , clientOnService = const $ return ()
  , clientOnState = const $ return ()
  , clientOnExit = const $ return ()
  }

-- | Connect to remote app and recieve eventlog from it.
startLiveClient :: LoggerSet -- ^ Monitor logging messages sink
  -> LiveProfileClientOpts -- ^ Options for client side
  -> TerminationPair  -- ^ Termination protocol
  -> ClientBehavior -- ^ User specified callbacks 
  -> IO ThreadId -- ^ Starts new thread that connects to remote host and 
startLiveClient logger LiveProfileClientOpts{..} term cb = forkIO $ 
  trackTermination (clientOnExit cb) $ 
  printExceptions "Live client" $ do 
    labelCurrentThread "Client"
    untilTerminatedPair term $ bracket socket clientClose $ \s -> do
      connect s clientTargetAddr
      clientBody s
    logProf logger "Client thread terminated"
    where
    clientClose s = do 
      logProf logger "Client disconnected"
      close s 
    clientBody s = do 
      logProf logger $ "Client thread started and connected to " <> showl clientTargetAddr
      runEventListener logger s clientMessageTimeout cb
      --_ <- senderThread s

    --senderThread _ = forkIO $ forever yield -- TODO: implement service msg passing

-- | Helper for creation listening threads that accepts eventlog messages from socket
runEventListener :: LoggerSet -- ^ Where to spam about everything
  -> ClientSocket -- ^ Which socket to listen for incoming messages
  -> NominalDiffTime -- ^ Timeout for collector internal state
  -> ClientBehavior -- ^ User specified callbacks 
  -> IO ()
runEventListener logger p msgTimeout ClientBehavior{..} = go (emptyMessageCollector msgTimeout)
  where 
  go collector = do
    mmsg <- recieveMessage p
    case mmsg of 
      Left MsgEndOfInput -> do 
        logProf logger "runEventListener: end of input"
        return ()
      Left (MsgDeserialisationFail er) -> do
        logProf logger er
        go collector
      Right msg -> do 
        --logProf logger $ showl msg
        curTime <- getCurrentTime
        let stepper = stepMessageCollector curTime msg
        let ((evs, collector'), msgs) = runWriter $ runStateT stepper collector 
        logProf' logger msgs
        forM_ evs $ \ev -> case ev of 
          CollectorHeader h -> do 
            logProf logger $ "Collected full header with " 
              <> showl (length $ eventTypes h) <> " event types"
            clientOnHeader h 
          CollectorService smsg -> do 
            logProf logger $ "Got service message" <> showl smsg
            clientOnService smsg
          CollectorEvents es -> do
            mapM_ clientOnEvent es
          CollectorState s -> clientOnState s 

        collector' `deepseq` go collector'