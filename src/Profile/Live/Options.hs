module Profile.Live.Options(
    LiveProfileOpts(..)
  , defaultLiveProfileOpts
  ) where 

import System.Socket.Family.Inet

-- | Options of live profile monitor
data LiveProfileOpts = LiveProfileOpts {
  -- | Chunk size to get from eventlog before feeding into incremental parser
  -- TODO: make the size also the size of eventlog buffers
  eventLogChunkSize :: !Word
  -- | Port that is used to listen for incoming connections.
, eventLogListenPort :: !InetPort
} deriving Show 

-- | Default options of live profile
defaultLiveProfileOpts :: LiveProfileOpts
defaultLiveProfileOpts = LiveProfileOpts {
    eventLogChunkSize = 512 -- 1 Kb
  , eventLogListenPort = 8242 
  }