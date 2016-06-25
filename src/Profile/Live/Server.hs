{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
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
startLiveServer :: LiveProfileOpts -> Termination -> Termination -> IO ThreadId
startLiveServer LiveProfileOpts{..} termVar thisTerm = do 
  forkIO $ do 
    withSocket $ \s -> untilTerminated termVar () $ const $ acceptAndHandle s
    putMVar thisTerm ()
  where
  withSocket m = bracket (socket :: IO ServerSocket) close $ \s -> do 
    setSocketOption s (ReuseAddress True)
    setSocketOption s (V6Only False)
    bind s (SocketAddressInet6 inet6Any eventLogListenPort 0 0)
    listen s 0 -- implentation choose queue size
    putStrLn $ "Live profile: server started"
    m s

  acceptAndHandle :: ServerSocket -> IO ()
  acceptAndHandle s = bracket (timeout 1000000 $ accept s) closeCon acceptCon
    where 
    closeCon mres = whenJust mres $ \(p, addr) -> do 
      close p 
      putStrLn $ "Live profile: closed connection to " ++ show addr
    acceptCon mres = whenJust mres $ \(p, addr) -> do 
      putStrLn $ "Accepted connection from " ++ show addr
      sendAll p "Hello world!" msgNoSignal