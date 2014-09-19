{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module Main where 

import Test.Tasty
import Test.Tasty.HUnit

import Data.Bifunctor
import Data.Monoid
import Data.Foldable
import Data.List.NonEmpty
import Data.ByteString
import Data.ByteString.Lazy as BL
import Data.Text.Lazy as TL
import Data.Typeable
import Data.Tree
import qualified Data.Attoparsec.Text as A
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Except
import Control.Lens (view)
import Control.Concurrent.Async
import Pipes
import qualified Pipes.ByteString as B
import qualified Pipes.Prelude as P
import qualified Pipes.Parse as P
import qualified Pipes.Attoparsec as P
import qualified Pipes.Text as T
import qualified Pipes.Text.Encoding as T
import qualified Pipes.Text.IO as T
import qualified Pipes.Group as G
import qualified Pipes.Safe as S
import qualified Pipes.Safe.Prelude as S
import System.IO
import System.IO.Error
import System.Exit
import System.Directory
import System.Process.Streaming

main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" 
            [ testCollectStdoutStderrAsByteString
            , testFeedStdinCollectStdoutAsText  
            , testCombinedStdoutStderr
            , testInterruptExecution 
            , testFailIfAnythingShowsInStderr 
            , testTwoTextParsersInParallel  
            , testCountWords 
            , testBasicPipeline
            , testBranchingPipeline 
            , testDrainageDeadlock
            , testAlternatingWithCombined 
            ]

-------------------------------------------------------------------------------
testCollectStdoutStderrAsByteString :: TestTree
testCollectStdoutStderrAsByteString = testCase "collectStdoutStderrAsByteString" $ do
    r <- collectStdoutStderrAsByteString
    case r of
        (ExitSuccess,("ooo\nppp\n","eee\nffff\n")) -> return ()
        _ -> assertFailure "oops"

collectStdoutStderrAsByteString :: IO (ExitCode,(BL.ByteString,BL.ByteString))
collectStdoutStderrAsByteString = execute
    (pipeoe (fromFold B.toLazyM) (fromFold B.toLazyM))
    (shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ; }")


-------------------------------------------------------------------------------
testFeedStdinCollectStdoutAsText  :: TestTree
testFeedStdinCollectStdoutAsText = testCase "feedStdinCollectStdoutAsText" $ do
    r <- feedStdinCollectStdoutAsText
    case r of
        (ExitSuccess,((),"aaaaaa\naaaaa")) -> return ()
        _ -> assertFailure "oops"

feedStdinCollectStdoutAsText :: IO (ExitCode, ((), Text))
feedStdinCollectStdoutAsText = execute
    (pipeio (fromProducer $ yield "aaaaaa\naaaaa")
            (encoded T.decodeIso8859_1 (pure id) $ fromFold T.toLazyM))
    (shell "cat")

-------------------------------------------------------------------------------

testCombinedStdoutStderr :: TestTree
testCombinedStdoutStderr = testCase "testCombinedStdoutStderr"  $ do
    r <- combinedStdoutStderr 
    case r of 
        (ExitSuccess,TL.lines -> ls) -> do
            assertEqual "line count" (Prelude.length ls) 4
            assertBool "expected lines" $ 
                getAll $ foldMap (All . flip Prelude.elem ls) $
                    [ "ooo"
                    , "ppp"
                    , "errprefix: eee"
                    , "errprefix: ffff"
                    ]
        _ -> assertFailure "oops"

combinedStdoutStderr :: IO (ExitCode,TL.Text)
combinedStdoutStderr = execute
    (pipeoec (linePolicy T.decodeIso8859_1 (pure ()))
             (tweakLines annotate $ linePolicy T.decodeIso8859_1 (pure ()))    
             (fromFold T.toLazyM))
    (shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ; }")
  where
    annotate x = P.yield "errprefix: " *> x  

-------------------------------------------------------------------------------

testInterruptExecution :: TestTree
testInterruptExecution = localOption (mkTimeout $ 5*(10^6)) $
    testCase "interruptExecution" $ do
        r <- interruptExecution
        case r of
            Left "interrupted" -> return ()
            _ -> assertFailure "oops"

interruptExecution :: IO (Either String (ExitCode,()))
interruptExecution = executeFallibly
    (pipeo . siphon $ \_ -> runExceptT . throwE $ "interrupted")
    (shell "sleep 100s")

-------------------------------------------------------------------------------

testFailIfAnythingShowsInStderr :: TestTree
testFailIfAnythingShowsInStderr = localOption (mkTimeout $ 5*(10^6)) $
    testCase "failIfAnythingShowsInStderr" $ do
        r <- failIfAnythingShowsInStderr 
        case r of
            Left "morestuff\n" -> return ()
            _ -> assertFailure "oops"

failIfAnythingShowsInStderr :: IO (Either T.ByteString (ExitCode,()))
failIfAnythingShowsInStderr = executeFallibly
    (pipee (unwanted ()))
    (shell "{ echo morestuff 1>&2 ; sleep 100s ; }")

-------------------------------------------------------------------------------

testTwoTextParsersInParallel  :: TestTree
testTwoTextParsersInParallel  = testCase "twoTextParsersInParallel" $ do
    r <- twoTextParsersInParallel
    case r of 
        Right (ExitSuccess,("ooooooo","aaaaaa")) -> return ()
        _ -> assertFailure "oops"

parseChars :: Char -> A.Parser [Char] 
parseChars c = fmap mconcat $ 
    many (A.notChar c) *> A.many1 (some (A.char c) <* many (A.notChar c))
        
parser1 = parseChars 'o'

parser2 = parseChars 'a'

twoTextParsersInParallel :: IO (Either String (ExitCode,([Char], [Char])))
twoTextParsersInParallel = executeFallibly
    (pipeo (encoded T.decodeIso8859_1 (pure id) $ 
                (,) <$> adapt parser1 <*> adapt parser2))
    (shell "{ echo ooaaoo ; echo aaooaoa; }")
  where
    adapt p = fromParser $ do
        r <- P.parse p
        return $ case r of
            Just (Right r') -> Right r'
            _ -> Left "parse error"

-------------------------------------------------------------------------------

testCountWords :: TestTree
testCountWords = testCase "testCountWords" $ do
    r <- countWords 
    case r of 
        (ExitSuccess,3) -> return ()                   
        _ -> assertFailure "oops"

countWords :: IO (ExitCode,Int)
countWords = execute
    (pipeo (encoded T.decodeIso8859_1 (pure id) $
                fromFold $ P.sum . G.folds const () (const 1) . view T.words))
    (shell "{ echo aaa ; echo bbb ; echo ccc ; }")

-------------------------------------------------------------------------------
testBasicPipeline :: TestTree
testBasicPipeline = testCase "basicPipeline" $ do
    r <- basicPipeline 
    case r of 
        Right ((),"aaaccc\n") -> return ()                   
        _ -> assertFailure "oops"

basicPipeline :: IO (Either String ((),BL.ByteString))
basicPipeline =  executePipelineFallibly 
    (pipeio (fromProducer $ yield "aaabbb\naaaccc\nxxxccc") 
            (fromFold B.toLazyM)) 
    (simplePipeline T.decodeUtf8 (shell "grep aaa") (pure . pure $ shell "grep ccc"))

-------------------------------------------------------------------------------

testBranchingPipeline :: TestTree
testBranchingPipeline = testCase "branchingPipeline" $ do
    exists <- doesFileExist branchingPipelineFile
    when exists $ removeFile branchingPipelineFile
    r <- branchingPipeline 
    case r of 
        ("ppp\v","eee\nffff\n") -> return ()                   
        _ -> assertFailure "oops"
    fileContents <- withFile branchingPipelineFile ReadMode  $ \hIn -> do
        B.toLazyM $ B.fromHandle hIn 
    assertBool "file contexts" $ BL.isPrefixOf "yyy" fileContents 

branchingPipelineFile :: String 
branchingPipelineFile = "dist/test/process-streaming-pipeline-text.txt"

branchingPipeline :: IO (BL.ByteString, BL.ByteString)
branchingPipeline = executePipeline
    (pipeoe (fromFold B.toLazyM) (fromFold B.toLazyM)) 
    (CreatePipeline rootStage . fromList $ 
        [ Node branch1 [pure terminalStage1] , Node branch2 [pure terminalStage2] ] )
  where
    succStage = SubsequentStage (P.map (Data.ByteString.map succ))

    rootStage :: (Show e, Typeable e) => Stage e
    rootStage = Stage (shell "{ echo oooaaa ; echo eee 1>&2 ; echo xxx ;  echo ffff 1>&2 ; }")
                      (linePolicy T.decodeIso8859_1 (pure ()))                 
                      (\_ -> Nothing)

    branch1 :: (Show e, Typeable e) => SubsequentStage e
    branch1 = SubsequentStage cat $
        Stage (shell "grep ooo")
              (linePolicy T.decodeIso8859_1 (pure ()))                 
              (\_ -> Nothing)

    branch2 :: (Show e, Typeable e) => SubsequentStage e
    branch2 = SubsequentStage cat $
        Stage (shell "grep xxx")
              (linePolicy T.decodeIso8859_1 (pure ()))                 
              (\_ -> Nothing)

    terminalStage1 :: (Show e, Typeable e) => SubsequentStage e
    terminalStage1 = succStage $
        Stage (shell "tr -d b")
              (linePolicy T.decodeIso8859_1 (pure ()))                 
              (\_ -> Nothing)

    terminalStage2 :: (Show e, Typeable e) => SubsequentStage e
    terminalStage2 = succStage $
        Stage (shell $ "cat > " ++ branchingPipelineFile)
              (linePolicy T.decodeIso8859_1 (pure ()))                 
              (\_ -> Nothing)

-------------------------------------------------------------------------------

testDrainageDeadlock :: TestTree
testDrainageDeadlock = localOption (mkTimeout $ 20*(10^6)) $
    testCase "drainageDeadlock" $ do
        execute nopiping $ shell "chmod u+x tests/alternating.sh"
        r <- drainageDeadlock
        case r of
            (ExitSuccess,((),())) -> return ()
            _ -> assertFailure "oops"

-- A bug caused some streams not to be drained, and this caused problems
-- due to full output buffers.
drainageDeadlock :: IO (ExitCode,((),()))
drainageDeadlock = execute
    (pipeoe (pure ()) (fromFold $ \producer -> next producer >> pure ()))
    (proc "tests/alternating.sh" [])


-------------------------------------------------------------------------------

testAlternatingWithCombined :: TestTree
testAlternatingWithCombined = localOption (mkTimeout $ 20*(10^6)) $
    testCase "testAlternatingWithCombined" $ do
        execute nopiping $ shell "chmod u+x tests/alternating.sh"
        r <- alternatingWithCombined  
        case r of 
            (ExitSuccess,80000) -> return ()
            _ -> assertFailure "oops"
        r <- alternatingWithCombined2  
        case r of 
            (ExitSuccess,(80000,80000)) -> return ()
            _ -> assertFailure "oops"

alternatingWithCombined :: IO (ExitCode,Integer)
alternatingWithCombined = execute
    (pipeoec lp lp countLines)
    (proc "tests/alternating.sh" [])
  where
    lp = linePolicy T.decodeIso8859_1 (pure ()) 
    countLines = fromFold $ P.sum . G.folds const () (const 1) . view T.lines


alternatingWithCombined2 :: IO (ExitCode,(Integer,Integer))
alternatingWithCombined2 = execute
    (pipeoec lp lp $ (,) <$> countLines <*> countLines)
    (proc "tests/alternating.sh" [])
  where
    lp = linePolicy T.decodeIso8859_1 (pure ()) 
    countLines = fromFold $ P.sum . G.folds const () (const 1) . view T.lines


