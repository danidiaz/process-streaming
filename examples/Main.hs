{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Maybe
import Data.Functor.Identity
import Data.Either
import Data.Monoid
import Data.Traversable
import Data.Typeable
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Trans.Either
import Control.Monad.Error
import Control.Monad.Writer.Strict
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Control.Lens
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Lift
import Pipes.ByteString
import qualified Pipes.Text as T
import Pipes.Concurrent
import System.IO
import System.Process
import System.Exit

