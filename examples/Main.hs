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
import qualified Pipes.Safe as S
import qualified Pipes.Safe.Prelude as S
import Pipes.Concurrent
import System.IO
import System.Process
import System.Process.Streaming
import System.Exit

example = execute2 show create $ \(stdout,stderr) -> runConcE $
        (,) <$> ConcE (consume show stdout $ useSafeConsumer $ writeFile' "stdout.log")
            <*> ConcE (consume show stderr $ useSafeConsumer $ writeFile' "stderr.log")
    where
    create = set stream3 pipe3 $ proc "script1.bat" []
    writeFile' file = S.withFile file WriteMode toHandle

    






