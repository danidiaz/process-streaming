{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Data.Maybe
import Data.Functor.Identity
import Data.Bifunctor
import Data.Either
import Data.Monoid
import Data.Traversable
import Data.Typeable
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Trans.Either
import Control.Monad.Error
--import Control.Monad.State
import Control.Monad.Writer.Strict
import Control.Exception
import Control.Concurrent
import Control.Lens
import Pipes
import qualified Pipes.Prelude as P
import qualified Pipes.Parse as P
import Pipes.Lift
import Pipes.ByteString
import qualified Pipes.Group as P
import qualified Pipes.Text as T
import qualified Pipes.Text.Encoding as T
import qualified Pipes.Text.IO as T
import qualified Pipes.Safe as S
import qualified Pipes.Safe.Prelude as S
import Pipes.Concurrent
import System.IO
import System.Process
import System.Process.Streaming
import System.Exit
import System.IO.Error

import qualified Data.Attoparsec.Text as A
import Data.Attoparsec.Combinator
import qualified Pipes.Attoparsec as P

-- stdout and stderr to different files, using pipes-safe.
example1 :: IO (Either String ((),()))
example1 = exitCode show $
    execute (proc "script1.bat" []) show $ separate 
        (consume "stdout.log")
        (consume "stderr.log")
    where
    consume file = surely . safely . useConsumer $
                       S.withFile file WriteMode toHandle

-- Error becasue of missing executable.
example2 :: IO (Either String ((),()))
example2 = exitCode show $ 
    execute (proc "asdfasdf.bat" []) show $ separate 
        purge 
        purge 

---- Stream to a file the combined lines of stdout and stderr.
example3 :: IO (Either String ())
example3 = exitCode show $ 
   execute (proc "script1.bat" []) show $ combineLines
       (decodeLines T.decodeIso8859_1 id,       policy)
       (decodeLines T.decodeIso8859_1 annotate, policy)
       (surely . safely . useConsumer $ 
           S.withFile "combined.txt" WriteMode T.toHandle)
    where
    policy = failOnLeftovers $ \_ _->"badbytes"
    annotate x = P.yield "errprefix: " *> x

-- Ignore stderr, run two attoparsec parsers concurrently on stdout.
parseChars :: Char -> A.Parser [Char] 
parseChars c = fmap mconcat $ 
    many (A.notChar c) *> many1 (some (A.char c) <* many (A.notChar c))

parser1 = parseChars 'o'
parser2 = parseChars 'a'

example4 ::IO (Either String (([Char], [Char]),()))
example4 = exitCode show $ 
    execute (proc "script2.bat" []) show $ separate
        (encoding T.decodeIso8859_1 (failOnLeftovers $ \_ _->"badbytes") $  
            forkProd (P.evalStateT $ adapt parser1)
                     (P.evalStateT $ adapt parser2))
        purge 
    where
    adapt p = bimap (const "parse error") id <$> P.parse p

 
-- Gets a list of lines for both stdout and stderr (breaks streaming)
example5 ::IO (Either String ([T.Text], [T.Text]))
example5 = exitCode show $  
    execute (proc "script1.bat" []) show $ separate activity activity
    where
    activity = encoding T.decodeIso8859_1 ignoreLeftovers . surely $ 
        P.toListM . P.folds (<>) "" id . view T.lines

-- Checking that trying to terminate an already dead process doesn't cause exceptions.
example6 ::IO (Either String ((),()))
example6 = exitCode show $ 
    execute (proc "ruby" ["script4.rb"]) show $ separate
            purge
            (\_ -> threadDelay (2*10^6) >> (return $ Left "slow return!"))

-- Checking that returning a Left exits the process early.
example7 ::IO (Either String ((),()))
example7 = exitCode show $  
    execute (proc "ruby" ["script3.rb"]) show $ separate
            purge
            (\_ -> return $ Left "fast return!")

