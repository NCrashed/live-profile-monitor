module Main(main) where 

import System.Environment
import System.Log.FastLogger
import System.Process
import Control.Exception (bracket)

import Profile.Live 

main :: IO ()
main = do 
  args <- getArgs -- TODO: add options parser
  logger <- newStdoutLoggerSet defaultBufSize
  bracket (initLiveProfile defaultLiveProfileOpts logger) stopLiveProfile $ const $ do
    callCommand $ unwords args