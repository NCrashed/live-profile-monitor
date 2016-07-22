{-# LANGUAGE Safe #-}
{-# LANGUAGE CPP #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Termination
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Utilities for termination protocol of threads. Can be used to terminate
-- worker threads and wait for the event that they actually quited. 
--
------------------------------------------------------------------------------
module Profile.Live.Termination(
  -- * Core API
    Termination
  , TerminationPair
  , untilTerminated
  , untilTerminatedPair
  -- * Helpers
  , terminate 
  , terminateAndWait
  , waitTermination
  ) where 

import Control.Concurrent
import Control.Exception   (Exception(..), handleJust, bracket,
                            uninterruptibleMask_,
                            asyncExceptionToException,
                            asyncExceptionFromException)
import Control.Monad.IO.Class 
import Data.Unique         (Unique, newUnique)

-- | Termination mutex, all threads are stopped when the mvar is filled
type Termination = MVar ()

-- | Pair of mutex, first one is used as termination of child thread,
-- the second one is set by terminated client wich helps to hold on
-- parent thread from exiting too early.
type TerminationPair = (Termination, Termination)

-- | Helper to send termination signal to listener
terminate :: MonadIO m => Termination -> m ()
terminate v = liftIO $ putMVar v ()

-- | Blocks until termination flag is not set
waitTermination :: MonadIO m => Termination -> m ()
waitTermination v = liftIO $ readMVar v

-- | Blocking variant of 'terminate', wait until the child thread is terminated
terminateAndWait :: MonadIO m => TerminationPair -> m ()
terminateAndWait (v1, v2) = do 
  terminate v1 
  waitTermination v2

-- An internal type that is thrown as a dynamic exception to
-- interrupt the running IO computation when the termination
-- flag is set.
newtype TerminationException = Termination Unique deriving (Eq)

instance Show TerminationException where
    show _ = "<<termination>>"

-- TerminationException is a child of SomeAsyncException
instance Exception TerminationException where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | Do action until termination flag is set.
-- 
-- The implemenation is taken from 'System.Timeout' module and
-- has the same weak points: we cannot terminate blocking FFI call.
untilTerminated :: MonadIO m => Termination -> IO a -> m ()
untilTerminated v m = liftIO $ do
  pid <- myThreadId
  ex  <- fmap Termination newUnique
  handleJust (\e -> if e == ex then Just () else Nothing)
             (\_ -> return Nothing)
             (bracket (forkIOWithUnmask $ \unmask ->
                           unmask $ waitTermination v >> throwTo pid ex)
                      (uninterruptibleMask_ . killThread)
                      (\_ -> fmap Just m))
  return ()
  -- #7719 explains why we need uninterruptibleMask_ above.

-- | Do action until termination flag is set and signal remote thread 
-- that we are done.
-- 
-- The implemenation is taken from 'System.Timeout' module and
-- has the same weak points: we cannot terminate blocking FFI call.
untilTerminatedPair :: MonadIO m => TerminationPair -> IO a -> m ()
untilTerminatedPair (v1, v2) m = do 
  untilTerminated v1 m 
  terminate v2 