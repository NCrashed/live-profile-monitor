module Profile.Live(
    LiveProfileOpts
  , defaultLiveProfileOpts
  , LiveProfiler
  , initLiveProfile
  ) where 

-- | Options of live profile monitor
data LiveProfileOpts = LiveProfileOpts {}

-- | Default options of live profile
defaultLiveProfileOpts :: LiveProfileOpts
defaultLiveProfileOpts = LiveProfileOpts

-- | Live profiler state
data LiveProfiler = LiveProfiler

-- | Initialize live profile monitor that accepts connections
-- from remote tools and tracks state of eventlog protocol.
initLiveProfile :: LiveProfileOpts -> IO LiveProfiler
initLiveProfile = error "initLiveProfile: unimplemented"