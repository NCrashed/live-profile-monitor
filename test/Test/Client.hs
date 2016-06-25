module Test.Client(
    recieveRemoteEventlog
  ) where

import Control.Monad 
import Control.Concurrent
import Control.Exception
import System.IO 

import System.Socket
import System.Socket.Family.Inet6
import System.Socket.Type.Stream
import System.Socket.Protocol.TCP

import qualified Data.ByteString as BS 

type ServerSocket = Socket Inet6 Stream TCP 

recieveRemoteEventlog :: SocketAddress Inet6 -> FilePath -> IO ()
recieveRemoteEventlog addr filename = void . forkIO $ bracket socket close $ 
  \s -> connect s addr >> go s 
  where 
  go :: ServerSocket -> IO ()
  go s = withFile filename WriteMode $ \h -> forever $ do 
    bs <- receive s 1024 mempty
    when (BS.length bs > 0) $ do
      BS.hPut h bs 
      hFlush h 