-- | Running tests
module Test.Tasty.Run
  ( Status(..)
  , StatusMap
  , Runner
  , execRunner
  , launchTestTree
  ) where

import qualified Data.IntMap as IntMap
import Data.Maybe
import Data.Typeable
import Control.Monad.State
import Control.Concurrent.STM
import Control.Exception

import Test.Tasty.Core
import Test.Tasty.Parallel
import Test.Tasty.Options
import Test.Tasty.CoreOptions

-- | Current status of a test
data Status
  = NotStarted
    -- ^ test has not started running yet
  | Executing Progress
    -- ^ test is being run
  | Exception SomeException
    -- ^ test threw an exception and was aborted
  | Done Result
    -- ^ test finished with a given result

data TestMap = TestMap
    !Int
    !(IntMap.IntMap (IO (), TVar Status))
      -- ^ Int is the first free index
      --
      -- IntMap maps test indices to:
      --
      --    * the action to launch the test
      --
      --    * the status variable of the launched test

-- | Mapping from test numbers (starting from 0) to their status variables.
--
-- This is what a runner uses to analyse and display progress, and to
-- detect when tests finish.
type StatusMap = IntMap.IntMap (TVar Status)

-- | A 'Runner' is responsible for user interaction during the test run.
--
-- It is provided with the 'StatusMap', so the tests are already launched
-- and all it needs to do is notifying the user about the progress and
-- then displaying the overall results in the end.
--
-- The function's result should indicate whether all the tests passed.
type Runner = OptionSet -> TestTree -> StatusMap -> IO Bool

-- | Start executing a test
executeTest
  :: ((Progress -> IO ()) -> IO Result)
    -- ^ the action to execute the test, which takes a progress callback as
    -- a parameter
  -> TVar Status -- ^ variable to write status to
  -> IO ()
executeTest action statusVar = do
  result <- handleExceptions $
    -- pass our callback (which updates the status variable) to the test
    -- action
    action yieldProgress

  -- when the test is finished, write its result to the status variable
  atomically $ writeTVar statusVar result

  where
    -- the callback
    yieldProgress progress =
      atomically $ writeTVar statusVar $ Executing progress

    handleExceptions a = do
      resultOrException <- try a
      case resultOrException of
        Left e
          | Just async <- fromException e
          -> throwIO (async :: AsyncException) -- user interrupt, etc

          | otherwise
          -> return $ Exception e

        Right result -> return $ Done result

-- | Prepare the test tree to be run
createTestMap :: OptionSet -> TestTree -> IO TestMap
createTestMap opts tree =
  flip execStateT (TestMap 0 IntMap.empty) $ getApp $
  foldTestTree
    runSingleTest
    (const id)
    opts
    tree
  where
    runSingleTest opts _ test = AppMonoid $ do
      statusVar <- liftIO $ atomically $ newTVar NotStarted
      let
        act =
          executeTest (run opts test) statusVar
      TestMap ix tmap <- get
      let
        tmap' = IntMap.insert ix (act, statusVar) tmap
        ix' = ix+1
      put $! TestMap ix' tmap'

-- | Start running all the tests in the TestMap in parallel
launchTests :: Int -> TestMap -> IO ()
launchTests threads (TestMap _ tmap) =
  runInParallel threads $ map fst $ IntMap.elems tmap

-- | Start running all the tests in a test tree in parallel. The number of
-- threads is determined by the 'NumThreads' option.
--
-- Return a map from the test number (starting from 0) to its status
-- variable.
launchTestTree :: OptionSet -> TestTree -> IO StatusMap
launchTestTree opts tree = do
  tmap@(TestMap _ smap) <- createTestMap opts tree
  let NumThreads numTheads = lookupOption opts
  launchTests numTheads tmap
  return $ fmap snd smap

-- | Execute a 'Runner'.
--
-- This is a shortcut which runs 'launchTestTree' behind the scenes.
execRunner :: Runner -> OptionSet -> TestTree -> IO Bool
execRunner runner opts testTree =
  runner opts testTree =<< launchTestTree opts testTree
