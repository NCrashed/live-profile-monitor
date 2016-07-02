module Profile.Live.Options(
    LiveProfileOpts(..)
  , defaultLiveProfileOpts
  ) where 

import System.Socket.Family.Inet6
import Data.Time.Clock

-- | Options of live profile monitor
data LiveProfileOpts = LiveProfileOpts {
  -- | Chunk size to get from eventlog before feeding into incremental parser
  -- TODO: make the size also the size of eventlog buffers
  eventLogChunkSize :: !Word
  -- | Port that is used to listen for incoming connections.
, eventLogListenPort :: !Inet6Port
  -- | How long to wait until the server drops outdated sequences of partial messages and blocks.
, eventLogMessageTimeout :: !NominalDiffTime
  -- | How many items in internal channels we hold. If there are additional items, the system
  -- will drop the new items to prevent out of memory issue. Nothing means no restriction on 
  -- the channels size.
, eventChannelMaximumSize :: !(Maybe Word)
} deriving Show 

-- | Default options of live profile
defaultLiveProfileOpts :: LiveProfileOpts
defaultLiveProfileOpts = LiveProfileOpts {
    eventLogChunkSize = 512 -- 1 Kb
  , eventLogListenPort = 8242 
  , eventLogMessageTimeout = fromIntegral 360
  , eventChannelMaximumSize = Just 1000000
  }