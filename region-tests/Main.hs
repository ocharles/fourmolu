{-# LANGUAGE RecordWildCards #-}

import Control.Monad (forM_, when)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

main :: IO ()
main = hspec $
  describe "region-tests" . beforeAll getExe $
    forM_ tests $ \Test {..} ->
      specify testLabel $ \fourmoluExe -> do
        actual <-
          readProcess fourmoluExe $
            ["region-tests/src.hs", "--check-idempotence"] ++ testArgs
        expected <- readFile $ "region-tests/" ++ testExpectedFileName
        actual `shouldBe` expected

data Test = Test
  { testLabel :: String,
    testArgs :: [String],
    testExpectedFileName :: FilePath
  }

tests :: [Test]
tests =
  [ Test
      { testLabel = "Works with implicit arguments",
        testArgs = [],
        testExpectedFileName = "expected-result-all.hs"
      },
    Test
      { testLabel = "Works with explicit arguments",
        testArgs = ["--start-line", "1", "--end-line", "18"],
        testExpectedFileName = "expected-result-all.hs"
      },
    Test
      { testLabel = "Works with only --start-line",
        testArgs = ["--start-line", "1"],
        testExpectedFileName = "expected-result-all.hs"
      },
    Test
      { testLabel = "Works with only --end-line",
        testArgs = ["--end-line", "18"],
        testExpectedFileName = "expected-result-all.hs"
      },
    Test
      { testLabel = "Works with lines 6-7",
        testArgs = ["--start-line", "6", "--end-line", "7"],
        testExpectedFileName = "expected-result-6-7.hs"
      },
    Test
      { testLabel = "Works with lines 6-8",
        testArgs = ["--start-line", "6", "--end-line", "8"],
        testExpectedFileName = "expected-result-6-8.hs"
      },
    Test
      { testLabel = "Works with lines 9-12",
        testArgs = ["--start-line", "9", "--end-line", "12"],
        testExpectedFileName = "expected-result-9-12.hs"
      },
    Test
      { testLabel = "Works with lines 17-18",
        testArgs = ["--start-line", "17", "--end-line", "18"],
        testExpectedFileName = "expected-result-17-18.hs"
      }
  ]

-- | Find a `fourmolu` executable on PATH.
getExe :: IO FilePath
getExe = findExecutable "fourmolu" >>= maybe (fail "Could not find fourmolu executable") return

readProcess :: FilePath -> [String] -> IO String
readProcess cmd args = do
  (code, stdout, stderr) <- readProcessWithExitCode cmd args ""
  when (code /= ExitSuccess) $ do
    putStrLn $ "Command failed: " ++ (unwords . map (\s -> "\"" ++ s ++ "\"")) (cmd : args)
    putStrLn "========== stdout =========="
    putStrLn stdout
    putStrLn "========== stderr =========="
    putStrLn stderr
    fail "Command failed. See output for more details."
  return stdout
