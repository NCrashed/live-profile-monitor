module Main(main) where 

import Control.Exception (bracket)
import Options.Applicative
import System.Log.FastLogger
import System.Process

import Profile.Live 
import Profile.Live.Options

optionsParser :: Parser (String, LiveProfileOpts)
optionsParser = (,)
  <$> strOption (
       long "command"
    <> help "How to call profiled application"
    )
  <*> profOpts
  where 
  profOpts = LiveProfileOpts
    <$> option auto (
         long "chunk"
      <> help "Chunk size to get from eventlog before feeding into incremental parser"
      <> value (eventLogChunkSize defOpts)
      )
    <*> strOption (
         long "pipe"
      <> help "Name of pipe (file path on linux, name of named pipe on Windows) where profiled application put its events."
      <> value (eventLogPipeName defOpts)
      )
    <*> (fmap fromIntegral $ option auto (
         long "port"
      <> help "Port that is used to listen for incoming connections."
      <> value defPort
      ))
    <*> (optional $ option auto (
         long "maxchannel"
      <> help "How many items in internal channels we hold. If there are additional items, the system will drop the new items to prevent out of memory issue. Nothing means no restriction on the channels size."
      ))
    <*> (optional $ option auto (
         long "maxmsgsize"
      <> help "If the datagram transport is used (UDP) the option bounds maximum size of single message."
      ))

  defOpts = defaultLiveProfileOpts
  
  defPort :: Word 
  defPort = 8242

profile :: String -> LiveProfileOpts -> IO ()
profile comm opts = do
  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile opts logger) stopLiveProfile $ const $ do
    callCommand comm

main :: IO ()
main = execParser opts >>= uncurry profile
  where
    opts = info (helper <*> optionsParser)
      ( fullDesc
     <> progDesc "Run a profiler monitor for Haskell application"
     <> header "hs-live-profile - live profiler monitor to send statistics about Haskell programs to remote host" )