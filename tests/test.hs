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
import Data.Text.Lazy.Encoding as TL
import Data.Typeable
import Data.Tree
import qualified Data.Attoparsec.Text as A
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Except
import Control.Exception
import Lens.Family (view)
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
import Pipes.Transduce 
import Pipes.Transduce.Text 
import qualified Pipes.Transduce.Text as PT
import Pipes.Transduce.ByteString 

main :: IO ()
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
            , testDrainageDeadlock
            , testAlternatingWithCombined 
            , testDecodeFailure
            , testMultipleFeeds
            , testMultipleFeedsNoPiped
            ]

-------------------------------------------------------------------------------
testCollectStdoutStderrAsByteString :: TestTree
testCollectStdoutStderrAsByteString = testCase "collectStdoutStderrAsByteString" $ do
    r <- collectStdoutStderrAsByteString
    case r of
        ("ooo\nppp\n","eee\nffff\n") -> return ()
        _ -> assertFailure "oops"

collectStdoutStderrAsByteString :: IO (BL.ByteString,BL.ByteString)
collectStdoutStderrAsByteString = 
    execute
    (piped (shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ; }"))
    (liftA2 (,) (foldOut intoLazyBytes) (foldErr intoLazyBytes))


-------------------------------------------------------------------------------
testFeedStdinCollectStdoutAsText  :: TestTree
testFeedStdinCollectStdoutAsText = testCase "feedStdinCollectStdoutAsText" $ do
    r <- feedStdinCollectStdoutAsText
    case r of
        "aaaaaa\naaaaa" -> return ()
        _ -> assertFailure "oops"

feedStdinCollectStdoutAsText :: IO Text
feedStdinCollectStdoutAsText = 
    execute
    (piped (shell "cat"))
    (feedUtf8 (Just "aaaaaa\naaaaa") *> foldOut (transduce1 utf8x intoLazyText))

-------------------------------------------------------------------------------

testCombinedStdoutStderr :: TestTree
testCombinedStdoutStderr = testCase "testCombinedStdoutStderr"  $ do
    r <- combinedStdoutStderr 
    case r of 
        (TL.lines -> ls) -> do
            assertEqual "line count" (Prelude.length ls) 4
            assertBool "expected lines" $ 
                getAll $ foldMap (All . flip Prelude.elem ls) $
                    [ "ooo"
                    , "ppp"
                    , "errprefix: eee"
                    , "errprefix: ffff"
                    ]

combinedStdoutStderr :: IO TL.Text
combinedStdoutStderr = execute
    (piped (shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ; }"))
    (foldOutErr (combined (PT.lines utf8x) (groups annotate . PT.lines $ utf8x) intoLazyText))
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

interruptExecution :: IO (Either String ())
interruptExecution = executeFallibly
    (piped (shell "sleep 100s"))
    (foldOut $ withFallibleCont $ \_ -> runExceptT . throwE $ "interrupted")

-------------------------------------------------------------------------------

testFailIfAnythingShowsInStderr :: TestTree
testFailIfAnythingShowsInStderr = localOption (mkTimeout $ 5*(10^6)) $
    testCase "failIfAnythingShowsInStderr" $ do
        r <- failIfAnythingShowsInStderr 
        case r of
            Left "morestuff\n" -> return ()
            _ -> assertFailure "oops"

failIfAnythingShowsInStderr :: IO (Either T.ByteString ())
failIfAnythingShowsInStderr = executeFallibly
    (piped (shell "{ echo morestuff 1>&2 ; sleep 100s ; }"))
    (foldErr trip)

-------------------------------------------------------------------------------

testTwoTextParsersInParallel  :: TestTree
testTwoTextParsersInParallel  = testCase "twoTextParsersInParallel" $ do
    r <- twoTextParsersInParallel
    case r of 
        Right ("ooooooo","aaaaaa") -> return ()
        _ -> assertFailure "oops"

parseChars :: Char -> A.Parser [Char] 
parseChars c = fmap mconcat $ 
    many (A.notChar c) *> A.many1 (some (A.char c) <* many (A.notChar c))
        
parser1 :: A.Parser [Char]
parser1 = parseChars 'o'

parser2 :: A.Parser [Char]
parser2 = parseChars 'a'

twoTextParsersInParallel :: IO (Either String ([Char], [Char]))
twoTextParsersInParallel = 
    executeFallibly
    (piped (shell "{ echo ooaaoo ; echo aaooaoa; }"))
    (foldOut (transduce1 utf8x $ 
                (,) <$> adapt parser1 <*> adapt parser2))
  where
    adapt p = withParser $ do
        r <- P.parse p
        return $ case r of
            Just (Right r') -> Right r'
            _ -> Left "parse error"
 
-------------------------------------------------------------------------------

testCountWords :: TestTree
testCountWords = testCase "testCountWords" $ do
    r <- countWords 
    case r of 
        3 -> return ()                   
        _ -> assertFailure "oops"

countWords :: IO Int
countWords = 
    execute
    (piped (shell "{ echo aaa ; echo bbb ; echo ccc ; }"))
    (foldOut (transduce1 PT.utf8x $
                withCont $ P.sum . G.folds const () (const 1) . view T.words))

-------------------------------------------------------------------------------

testDrainageDeadlock :: TestTree
testDrainageDeadlock = localOption (mkTimeout $ 20*(10^6)) $
    testCase "drainageDeadlock" $ do
        execute (piped (shell "chmod u+x tests/alternating.sh")) (pure ())
        r <- drainageDeadlock
        case r of
            ExitSuccess -> return ()
            _ -> assertFailure "oops"

-- A bug caused some streams not to be drained, and this caused problems
-- due to full output buffers.
drainageDeadlock :: IO ExitCode
drainageDeadlock = 
    execute
    (piped (proc "tests/alternating.sh" []))
    (foldErr (withCont $ \producer -> next producer >> pure ()) *> exitCode)

-------------------------------------------------------------------------------

testAlternatingWithCombined :: TestTree
testAlternatingWithCombined = localOption (mkTimeout $ 20*(10^6)) $
    testCase "testAlternatingWithCombined" $ do
        execute (piped (shell "chmod u+x tests/alternating.sh")) (pure ())
        r <- alternatingWithCombined  
        case r of 
            80000 -> return ()
            _ -> assertFailure $ "unexpected lines (1) " ++ show r
        r <- alternatingWithCombined2  
        case r of 
            (80000,80000) -> return ()
            _ -> assertFailure $ "unexpected lines (2) " ++ show r

alternatingWithCombined :: IO Integer
alternatingWithCombined = 
    execute
    (piped (proc "tests/alternating.sh" []))
    (foldOutErr (combined lp lp countLines))
  where
    lp = PT.lines PT.utf8x
    countLines = withCont $ P.sum . G.folds const () (const 1) . view T.lines


alternatingWithCombined2 :: IO (Integer,Integer)
alternatingWithCombined2 = 
    execute
    (piped (proc "tests/alternating.sh" []))
    (foldOutErr (combined lp lp (liftA2 (,) countLines countLines)))
  where
    lp = PT.lines PT.utf8x
    countLines = withCont $ P.sum . G.folds const () (const 1) . view T.lines

-------------------------------------------------------------------------------

testDecodeFailure :: TestTree
testDecodeFailure  = localOption (mkTimeout $ 20*(10^6)) $
    testCase "testDecodeFailure" $ do
        r <- decodeFailure
        case r of 
            Left _ -> return ()
            _ -> assertFailure "oops"

nonAscii :: BL.ByteString
nonAscii = TL.encodeUtf8 "\x4e2d"

decodeFailure :: IO (Either T.ByteString TL.Text)
decodeFailure = 
    executeFallibly 
    (piped (shell "cat"))
    (feedLazyBytes ("aaaaaaaa" <> nonAscii) *>
        foldOut (transduce1 (decoder T.decodeAscii) intoLazyText))

-------------------------------------------------------------------------------

testMultipleFeeds :: TestTree
testMultipleFeeds = testCase "testMultipleFeeds" $ do
    r <- multipleFeeds
    case r of
        "firstline1secondline2thirdline3" -> return ()
        _ -> assertFailure (show r)

multipleFeeds :: IO BL.ByteString
multipleFeeds = 
    execute
    (piped (shell "cat"))
    (feedBytes ["first","line1"] 
     *>
     feedBytes ["second","line2"] 
     *>
     feedBytes ["third","line3"] 
     *>
     foldOut intoLazyBytes)

testMultipleFeedsNoPiped :: TestTree
testMultipleFeedsNoPiped = localOption (mkTimeout $ 1*(10^6)) $ 
    testCase "testMultipleFeedsNoPiped" $ do
        r <- multipleFeedsNoPiped
        case r of
            "foo\n" -> return ()
            _ -> assertFailure (show r)

multipleFeedsNoPiped :: IO BL.ByteString
multipleFeedsNoPiped = 
    execute
    ((piped (shell "echo foo")) { std_in = Inherit })
    (feedBytes ["first","line1"] 
     *>
     feedBytes ["second","line2"] 
     *>
     feedBytes ["third","line3"] 
     *>
     foldOut intoLazyBytes)
