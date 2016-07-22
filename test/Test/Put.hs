{-# LANGUAGE BangPatterns #-}
module Test.Put(
    runEventlogSerialisationTests
  ) where

import GHC.RTS.Events 
import GHC.RTS.EventsIncremental 
import Control.DeepSeq 

import qualified Data.Sequence as S 
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Foldable as F 

import Profile.Live.Protocol.Message()

testHeader :: Header 
testHeader = Header { eventTypes = [
    EventType {num = 0, desc = "Create thread", size = Just 4}
  , EventType {num = 1, desc = "Run thread", size = Just 4}
  , EventType {num = 2, desc = "Stop thread", size = Just 10}
  , EventType {num = 3, desc = "Thread runnable", size = Just 4}
  , EventType {num = 4, desc = "Migrate thread", size = Just 6}
  , EventType {num = 8, desc = "Wakeup thread", size = Just 6}
  , EventType {num = 9, desc = "Starting GC", size = Just 0}
  , EventType {num = 10, desc = "Finished GC", size = Just 0}
  , EventType {num = 11, desc = "Request sequential GC", size = Just 0}
  , EventType {num = 12, desc = "Request parallel GC", size = Just 0}
  , EventType {num = 15, desc = "Create spark thread", size = Just 4}
  , EventType {num = 16, desc = "Log message", size = Nothing}
  , EventType {num = 18, desc = "Block marker", size = Just 14}
  , EventType {num = 19, desc = "User message", size = Nothing}
  , EventType {num = 20, desc = "GC idle", size = Just 0}
  , EventType {num = 21, desc = "GC working", size = Just 0}
  , EventType {num = 22, desc = "GC done", size = Just 0}
  , EventType {num = 25, desc = "Create capability set", size = Just 6}
  , EventType {num = 26, desc = "Delete capability set", size = Just 4}
  , EventType {num = 27, desc = "Add capability to capability set", size = Just 6}
  , EventType {num = 28, desc = "Remove capability from capability set", size = Just 6}
  , EventType {num = 29, desc = "RTS name and version", size = Nothing}
  , EventType {num = 30, desc = "Program arguments", size = Nothing}
  , EventType {num = 31, desc = "Program environment variables", size = Nothing}
  , EventType {num = 32, desc = "Process ID", size = Just 8}
  , EventType {num = 33, desc = "Parent process ID", size = Just 8}
  , EventType {num = 34, desc = "Spark counters", size = Just 56}
  , EventType {num = 35, desc = "Spark create", size = Just 0}
  , EventType {num = 36, desc = "Spark dud", size = Just 0}
  , EventType {num = 37, desc = "Spark overflow", size = Just 0}
  , EventType {num = 38, desc = "Spark run", size = Just 0}
  , EventType {num = 39, desc = "Spark steal", size = Just 2}
  , EventType {num = 40, desc = "Spark fizzle", size = Just 0}
  , EventType {num = 41, desc = "Spark GC", size = Just 0}
  , EventType {num = 43, desc = "Wall clock time", size = Just 16}
  , EventType {num = 44, desc = "Thread label", size = Nothing}
  , EventType {num = 45, desc = "Create capability", size = Just 2}
  , EventType {num = 46, desc = "Delete capability", size = Just 2}
  , EventType {num = 47, desc = "Disable capability", size = Just 2}
  , EventType {num = 48, desc = "Enable capability", size = Just 2}
  , EventType {num = 49, desc = "Total heap mem ever allocated", size = Just 12}
  , EventType {num = 50, desc = "Current heap size", size = Just 12}
  , EventType {num = 51, desc = "Current heap live data", size = Just 12}
  , EventType {num = 52, desc = "Heap static parameters", size = Just 38}
  , EventType {num = 53, desc = "GC statistics", size = Just 50}
  , EventType {num = 54, desc = "Synchronise stop-the-world GC", size = Just 0}
  , EventType {num = 55, desc = "Task create", size = Just 18}
  , EventType {num = 56, desc = "Task migrate", size = Just 12}
  , EventType {num = 57, desc = "Task delete", size = Just 8}
  , EventType {num = 58, desc = "User marker", size = Nothing}
  , EventType {num = 59, desc = "Empty event for bug #9003", size = Just 0}
  ]}

testEvents :: Data 
testEvents = Data {
    events = [
      Event {evTime = 9917074, evSpec = UserMessage {msg = "MyEvent"}, evCap = Nothing}
    -- GC related events
    , Event {evTime = 8738837, evSpec = RequestParGC, evCap = Nothing}
    , Event {evTime = 8768780, evSpec = StartGC, evCap = Nothing}
    , Event {evTime = 8771294, evSpec = GCWork, evCap = Nothing}
    , Event {evTime = 8799599, evSpec = GCIdle, evCap = Nothing}
    , Event {evTime = 8799657, evSpec = GCDone, evCap = Nothing}
    , Event {evTime = 8799865, evSpec = GCIdle, evCap = Nothing}
    , Event {evTime = 8799932, evSpec = GCDone, evCap = Nothing}
    , Event {evTime = 8801466, evSpec = GlobalSyncGC, evCap = Nothing}
    , Event {evTime = 8801574, evSpec = GCStatsGHC {heapCapset = 0, gen = 0, copied = 1272, slop = 44640, frag = 491520, parNThreads = 4, parMaxCopied = 40, parTotCopied = 40}, evCap = Nothing}
    , Event {evTime = 8802753, evSpec = EndGC, evCap = Nothing}
    ]
  }

deserialiseEventLog :: BSL.ByteString -> EventLog 
deserialiseEventLog bs = go False S.empty initParser 
  where 
  initParser = newParserState `pushBytes` BSL.toStrict bs 
  go wasIncomplete !acc !parser = let 
    (res, parser') = readEvent parser
    in case res of 
      Item e -> go wasIncomplete (acc S.|> e) parser'
      Incomplete -> if wasIncomplete then error "deserializeEventLog: Incomplete"
        else go True acc parser'
      ParseError s -> error $ "deserializeEventLog: " ++ s
      Complete -> let 
        Just header' = readHeader parser'
        in EventLog header' (Data (F.toList acc))

checkEventlogSerialisation :: EventLog -> IO ()
checkEventlogSerialisation el = el' `deepseq` return ()
  where 
  el' = deserialiseEventLog . serialiseEventLog $ el 

runEventlogSerialisationTests :: IO ()
runEventlogSerialisationTests = do 
  checkEventlogSerialisation $ EventLog testHeader testEvents