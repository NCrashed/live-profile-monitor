{-# LANGUAGE RecordWildCards #-}
module Profile.Live.Server(
    startLiveServer
  ) where 

import Control.Concurrent

import Profile.Live.Options 
import Profile.Live.State 

-- | Starts TCP server that listens on particular port which profiling 
-- clients connect with. 
startLiveServer :: LiveProfileOpts -> Termination -> Termination -> IO ThreadId
startLiveServer LiveProfileOpts{..} termVar thisTerm = do 
  forkIO $ do 
    untilTerminated termVar () go 
    putMVar thisTerm ()
  where 
  go _ = yield