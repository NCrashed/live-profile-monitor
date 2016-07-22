import Control.Exception (bracket)
import Control.Monad (forM_)
import Debug.Trace 
import Profile.Live.Leech

main :: IO ()
main = bracket (startLeech defaultLeechOptions) (const stopLeech) $ const $ do 
  forM_ [0 .. 1000000 :: Int] $ \i -> traceEventIO $ "MyEvent" ++ show i
  putStrLn "test-leech finished"