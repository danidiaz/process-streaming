{-# LANGUAGE OverloadedStrings #-}

import Test.Tasty
import Test.Tasty.HUnit

import Data.Bifunctor
import Data.Monoid
import qualified Data.Attoparsec.Text as A
import Control.Applicative
import Control.Monad
import Control.Lens (view)
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
import System.Process.Streaming

main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" []
--tests = testGroup "Tests" [properties, unitTests]

