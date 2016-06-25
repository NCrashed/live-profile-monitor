module Profile.Live.State(
    Termination
  , LiveProfiler(..)
  , untilTerminated
  , whenJust
  ) where 

import Control.Concurrent

-- | Termination mutex, all threads are stopped when the mvar is filled
type Termination = MVar ()

-- | Live profiler state
data LiveProfiler = LiveProfiler {
  -- | Id of thread that pipes from memory into incremental parser and
  -- and maintains parsed events to keep eye on state of the eventlog.
  eventLogPipeThread :: ThreadId
  -- | When pipe thread is ended it fills the mvar
, eventLogPipeThreadTerm :: Termination
  -- | Termination mutex, all threads are stopped when the mvar is filled
, eventLogTerminate :: Termination
}

-- | Do action until the mvar is not filled
untilTerminated :: Termination -> a -> (a -> IO a) -> IO ()
untilTerminated termVar a m = do 
  res <- tryTakeMVar termVar
  case res of 
    Nothing -> do
      a' <- m a
      untilTerminated termVar a' m
    Just _ -> return ()

whenJust :: Applicative m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing _ = pure ()
whenJust (Just x) m = m x 