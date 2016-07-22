{-# LANGUAGE StandaloneDeriving #-}
-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Protocol.State.Capability
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Utilities to watch only capabilities state of eventlog.
--
------------------------------------------------------------------------------
module Profile.Live.Protocol.State.Capability(
  -- * Capability set state 
    CapsetState(..)
  , isCapsetEvent
  , CapsetsState
  , newCapsetsState
  , updateCapsetsState
  -- * Capability state
  , CapState(..)
  , isCapEvent
  , CapsState
  , newCapsState
  , updateCapsState
  ) where 

import Control.DeepSeq 
import Data.Binary.Serialise.CBOR 
import Data.Maybe 
import Data.Word 
import GHC.Generics 
import GHC.RTS.Events 

import qualified Data.HashMap.Strict as H 
import qualified Data.Sequence as S

-- Just because it is not reexported from ghc-events
type Capset = Word32
type PID = Word32

deriving instance Generic CapsetType
instance NFData CapsetType 
instance Serialise CapsetType 

-- | The full state of single capset
data CapsetState = CapsetState {
  capsetStateId :: {-# UNPACK #-} !Capset -- ^ Unique id 
, capsetStateType :: !CapsetType -- ^ Type of the capset
, capsetStateCaps :: !(S.Seq Int) -- ^ Assigned caps
, capsetStateLastTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Last change timestamp
, capsetStateTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Creation timestamp
, capsetStateRtsIdent :: !String -- ^ RTS version and general info
, capsetStateArgs :: ![String] -- ^ Program arguments
, capsetStateEnvs :: ![String] -- ^ Program environment
, capsetStateOsPid ::  !(Maybe PID) -- ^ OS process id assigned to capset
, capsetStateOsParentPid ::  !(Maybe PID) -- ^ OS process id of parent process 
, capsetStateWallSecs :: {-# UNPACK #-} !Word64 -- ^ Value of capset wall clock
, capsetStateWallNsecs :: {-# UNPACK #-} !Word32 -- ^ Value of capset wall clock
, capsetStateHeapAllocated :: {-# UNPACK #-} !Word64 -- ^ Last info about allocated bytes
, capsetStateHeapSize :: {-# UNPACK #-} !Word64 -- ^ Last info about heap size
, capsetStateHeapLive :: {-# UNPACK #-} !Word64 -- ^ Last info about heap live size
, capsetStateHeapGens :: {-# UNPACK #-} !Int -- ^ Number of generations 
, capsetStateHeapMaxSize :: {-# UNPACK #-} !Word64 -- ^ Last info about heap maximum size
, capsetStateHeapAllocAreaSize :: {-# UNPACK #-} !Word64 -- ^ Last info about heap alloc area size
, capsetStateHeapMBlockSize :: {-# UNPACK #-} !Word64 -- ^ Last info about mblock(?) size
, capsetStateHeapBlockSize :: {-# UNPACK #-} !Word64 -- ^ Last info about block size
, capsetStateGCTimestamp :: !(Maybe Timestamp) -- ^ Last GC time
, capsetStateGCCopied :: {-# UNPACK #-} !Word64 -- ^ Last GC copied size
, capsetStateGCSlop :: {-# UNPACK #-} !Word64 -- ^ Last GC slop value
, capsetStateGCFrag :: {-# UNPACK #-} !Word64 -- ^ Last GC frag value
, capsetStateGCParThreads :: {-# UNPACK #-} !Int -- ^ Last GC count of parallel threads
, capsetStateGCParMaxCopied :: {-# UNPACK #-} !Word64 -- ^ Last GC parallel max copied value 
, capsetStateGCParTotCopied :: {-# UNPACK #-} !Word64 -- ^ Last GC parallel total copied value
} deriving (Generic, Show)

instance NFData CapsetState
instance Serialise CapsetState

-- | Create new record about capset
newCapsetState :: Capset -> CapsetType -> Timestamp -> CapsetState 
newCapsetState i ty t = CapsetState {
    capsetStateId = i 
  , capsetStateType = ty 
  , capsetStateCaps = mempty 
  , capsetStateLastTimestamp = t 
  , capsetStateTimestamp = t 
  , capsetStateRtsIdent = ""
  , capsetStateArgs = []
  , capsetStateEnvs = []
  , capsetStateOsPid = Nothing
  , capsetStateOsParentPid = Nothing
  , capsetStateWallSecs = 0
  , capsetStateWallNsecs = 0
  , capsetStateHeapAllocated = 0
  , capsetStateHeapSize = 0
  , capsetStateHeapLive = 0
  , capsetStateHeapGens = 0
  , capsetStateHeapMaxSize = 0
  , capsetStateHeapAllocAreaSize = 0
  , capsetStateHeapMBlockSize = 0
  , capsetStateHeapBlockSize = 0
  , capsetStateGCTimestamp = Nothing
  , capsetStateGCCopied = 0
  , capsetStateGCSlop = 0
  , capsetStateGCFrag = 0
  , capsetStateGCParThreads = 0
  , capsetStateGCParMaxCopied = 0
  , capsetStateGCParTotCopied = 0
  }

-- | Return 'True' if given event is related to a capset
isCapsetEvent :: Event -> Bool 
isCapsetEvent e = case evSpec e of 
  GCStatsGHC{} -> True
  HeapAllocated{} -> True
  HeapSize{} -> True
  HeapLive{} -> True
  HeapInfoGHC{} -> True
  CapsetCreate{} -> True
  CapsetDelete{} -> True
  CapsetAssignCap{} -> True
  CapsetRemoveCap{} -> True
  RtsIdentifier{} -> True
  ProgramArgs{} -> True
  ProgramEnv{} -> True
  OsProcessPid{} -> True
  OsProcessParentPid{} -> True
  WallClockTime{} -> True
  _ -> False 

-- | Extract capset id from event
getCapsetId :: Event -> Maybe Capset  
getCapsetId e = case evSpec e of 
  GCStatsGHC{..} -> Just heapCapset
  HeapAllocated{..} -> Just heapCapset
  HeapSize{..} -> Just heapCapset
  HeapLive{..} -> Just heapCapset
  HeapInfoGHC{..} -> Just heapCapset
  CapsetCreate{..} -> Just capset
  CapsetDelete{..} -> Just capset
  CapsetAssignCap{..} -> Just capset
  CapsetRemoveCap{..} -> Just capset
  RtsIdentifier{..} -> Just capset
  ProgramArgs{..} -> Just capset
  ProgramEnv{..} -> Just capset
  OsProcessPid{..} -> Just capset
  OsProcessParentPid{..} -> Just capset
  WallClockTime{..} -> Just capset
  _ -> Nothing 

-- | Update capset state with event
updateCapsetState :: Event -> CapsetState -> CapsetState
updateCapsetState e cs = case evSpec e of 
  GCStatsGHC{..} -> cs {
      capsetStateGCTimestamp = Just $ evTime e 
    , capsetStateHeapGens = gen 
    , capsetStateGCCopied = copied 
    , capsetStateGCSlop = slop 
    , capsetStateGCFrag = frag 
    , capsetStateGCParThreads = parNThreads
    , capsetStateGCParMaxCopied = parMaxCopied
    , capsetStateGCParTotCopied = parTotCopied
    }
  HeapAllocated{..} -> cs {
      capsetStateHeapAllocated = allocBytes
    }
  HeapSize{..} -> cs {
      capsetStateHeapSize = sizeBytes
    }
  HeapLive{..} -> cs {
      capsetStateHeapLive = liveBytes
    }
  HeapInfoGHC{..} -> cs {
      capsetStateHeapGens = gens 
    , capsetStateHeapMaxSize = maxHeapSize 
    , capsetStateHeapAllocAreaSize = allocAreaSize 
    , capsetStateHeapMBlockSize = mblockSize
    , capsetStateHeapBlockSize = blockSize 
    }
  CapsetAssignCap{..} -> cs {
      capsetStateCaps = capsetStateCaps cs S.|> cap
    , capsetStateLastTimestamp = evTime e 
    }
  CapsetRemoveCap{..} -> cs {
      capsetStateCaps = S.filter (/= cap) $ capsetStateCaps cs 
    , capsetStateLastTimestamp = evTime e
    }
  RtsIdentifier{..} -> cs {
      capsetStateRtsIdent = rtsident
    }
  ProgramArgs{..} -> cs {
      capsetStateArgs = args 
    }
  ProgramEnv{..} -> cs {
      capsetStateEnvs = env 
    }
  OsProcessPid{..} -> cs {
      capsetStateOsPid = Just pid 
    }
  OsProcessParentPid{..} -> cs {
      capsetStateOsParentPid = Just ppid
    }
  WallClockTime{..} -> cs {
      capsetStateWallSecs = sec
    , capsetStateWallNsecs = nsec
    }  
  _ -> cs 

-- | Accumulative state of all capsets
type CapsetsState = H.HashMap Capset CapsetState 

-- | New empty capsets state
newCapsetsState :: CapsetsState 
newCapsetsState = H.empty 

-- | Update capsets state with new event
updateCapsetsState :: Event -> CapsetsState -> CapsetsState 
updateCapsetsState e csss = case getCapsetId e of 
    Nothing -> csss 
    Just i -> case evSpec e of 
      CapsetCreate{..} -> H.insert i (newCapsetState i capsetType (evTime e)) csss
      CapsetDelete{} -> H.delete i csss 
      _ -> H.adjust (updateCapsetState e) i csss 

-- | The full state of single capability
data CapState = CapState {
  capStateId :: {-# UNPACK #-} !Int -- ^ Unique id of capability
, capStateDisabled :: !Bool -- ^ Is the cap is disabled
, capStateLastTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Time of last change (creation of enable/disable)
, capStateTimestamp :: {-# UNPACK #-} !Timestamp -- ^ Time of creation
} deriving (Generic, Show)

instance NFData CapState
instance Serialise CapState

-- | Create new state record 
newCapState :: Int -> Timestamp -> CapState 
newCapState i t = CapState {
    capStateId = i 
  , capStateDisabled = False 
  , capStateLastTimestamp = t
  , capStateTimestamp = t
  }

-- | Return 'True' if the event is related to some cap
isCapEvent :: Event -> Bool 
isCapEvent e = case evSpec e of 
  CapCreate{} -> True
  CapDelete{} -> True
  CapDisable{} -> True
  CapEnable{} -> True
  _ -> False

-- | Extract capability id from event
capIdFromEvent :: Event -> Maybe Int 
capIdFromEvent e = case evSpec e of 
  CapCreate{..} -> Just cap
  CapDelete{..} -> Just cap
  CapDisable{..} -> Just cap
  CapEnable{..} -> Just cap
  _ -> Nothing

-- | Update a capset state with given event, doesn't check if the event 
-- actually about the capability of cap state.
updateCapState :: Event -> CapState -> CapState 
updateCapState e cs = case evSpec e of 
  CapDisable{} -> cs' { capStateDisabled = True }
  CapEnable{} -> cs' { capStateDisabled = False }
  _ -> cs 
  where cs' = cs { capStateLastTimestamp = evTime e }

-- | Holds state of all caps
type CapsState = H.HashMap Int CapState 

-- | Empty state
newCapsState :: CapsState 
newCapsState = H.empty 

-- | Update state of all caps with event
updateCapsState :: Event -> CapsState -> CapsState 
updateCapsState e css = case capIdFromEvent e of 
  Nothing -> css 
  Just capi -> case evSpec e of 
    CapCreate{} -> H.insert capi (newCapState capi (evTime e)) css
    CapDelete{} -> H.delete capi css
    _ -> H.adjust (updateCapState e) capi css
