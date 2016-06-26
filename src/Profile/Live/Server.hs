module Profile.Live.Server(
    startLiveServer
  ) where 

import Control.Concurrent
import Control.Exception 

import Profile.Live.Options 
import Profile.Live.State 

import System.Socket 
import System.Socket.Family.Inet6
import System.Socket.Protocol.TCP
import System.Socket.Type.Stream
import System.Timeout

-- | Socket type that is used for the server
type ServerSocket = Socket Inet6 Stream TCP

-- | Starts TCP server that listens on particular port which profiling 
-- clients connect with. 
startLiveServer :: LoggerSet -> LiveProfileOpts -> Termination -> Termination -> IO ThreadId
startLiveServer logger LiveProfileOpts{..} termVar thisTerm = do 
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
      sendAll p "Hello world!" msgNoSignal