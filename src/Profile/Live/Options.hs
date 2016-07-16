module Profile.Live.Options(
  -- * Server side
    LiveProfileOpts(..)
  , defaultLiveProfileOpts
  -- * Client side
  , LiveProfileClientOpts(..)
  , defaultLiveProfileClientOpts
  ) where 

import System.Socket.Family.Inet6
import Data.Time.Clock
import Data.Word 

-- | Options of live profile monitor
data LiveProfileOpts = LiveProfileOpts {
  -- | Chunk size to get from eventlog before feeding into incremental parser
  eventLogChunkSize :: !Word64
  -- | Name of pipe (file path on linux, name of named pipe on Windows) where profiled
  -- application put its events.
, eventLogPipeName :: !FilePath
  -- | Port that is used to listen for incoming connections.
, eventLogListenPort :: !Inet6Port
  -- | How many items in internal channels we hold. If there are additional items, the system
  -- will drop the new items to prevent out of memory issue. Nothing means no restriction on 
  -- the channels size.
, eventChannelMaximumSize :: !(Maybe Word)
  -- | If the datagram transport is used (UDP) the option bounds maximum size of single message.
  -- Set 'Nothing' to never split payload into several messages.
, eventMessageMaxSize :: !(Maybe Word)
  -- | The live profile monitor has several threads that can excessively generate own eventlog 
  -- events. It could add significant noise into resulting eventlog of whole application, so 
  -- the options allows an user to drop off such uninformative events.
, eventHideMonitorActivity :: !Bool
} deriving Show 

-- | Default options of live profile
defaultLiveProfileOpts :: LiveProfileOpts
defaultLiveProfileOpts = LiveProfileOpts {
    eventLogChunkSize = 1024 -- 1 Kb
  , eventLogPipeName = "events.pipe"
  , eventLogListenPort = 8242
  , eventChannelMaximumSize = Just 1000000
  , eventMessageMaxSize = Nothing
  , eventHideMonitorActivity = False
  }

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