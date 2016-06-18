module Profile.Live(
  -- * Options
    LiveProfileOpts
  , defaultLiveProfileOpts
  -- * Basic API
  , LiveProfiler
  , initLiveProfile
  , stopLiveProfile
  ) where 

import Data.Monoid
import Debug.Trace 
import GHC.RTS.EventsIncremental 
import qualified Data.ByteString as B
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.FilePath (takeBaseName)

-- | Options of live profile monitor
data LiveProfileOpts = LiveProfileOpts {}
  deriving Show 

-- | Default options of live profile
defaultLiveProfileOpts :: LiveProfileOpts
defaultLiveProfileOpts = LiveProfileOpts

-- | Live profiler state
data LiveProfiler = LiveProfiler {
}

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: LiveProfileOpts -> IO LiveProfiler
initLiveProfile opts = do
  initialParser <- ensureEvengLogFile 
  return LiveProfiler

-- | Destroy live profiler.
--
-- The function closes all sockets, stops all related threads and
-- restores eventlog sink. 
stopLiveProfile :: LiveProfiler -> IO ()
stopLiveProfile = error "stopLiveProfile: unimplemented"

-- | Tries to load data from eventlog default file and construct
-- incremental parser. Throws if there is no eventlog file. 
--
-- We need the begining as when user is able to call 'initLiveProfile'
-- some important events were emitted into the default file.
ensureEvengLogFile :: IO EventParserState
ensureEvengLogFile = do 
  execPath <- getExecutablePath
  let fileName = takeBaseName execPath <> ".eventlog"
  eventlogPresents <- doesFileExist fileName
  if eventlogPresents then initParserFromFile fileName
    else fail "Cannot find eventlog file, check if program compiled with '-eventlog -rtsopts' and run it with '+RTS -l'"

-- | Read the begining of eventlog from file and construct
-- incremental parser. 
--
-- We need the begining as when user is able to call 'initLiveProfile'
-- some important events were emitted into the default file.
initParserFromFile :: FilePath -> IO EventParserState
initParserFromFile fn = do 
  bs <- B.readFile fn 
  return $ pushBytes newParserState bs