
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- system processes.
--
-- Error conditions not directly related to IO are made explicit
-- in the types.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and various folds can
-- be used to consume the output streams of the external processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Process.Streaming.Tutorial ( 
    -- * Collecting @stdout@ as a lazy ByteString
    -- $collstdout
    ) where

{- $setup

>>> :set -XOverloadedStrings
>>> import Data.Bifunctor
>>> import Data.Monoid
>>> import Data.ByteString.Lazy as BL
>>> import qualified Data.Attoparsec.Text as A
>>> import Control.Applicative
>>> import Control.Monad
>>> import Control.Lens (view)
>>> import Pipes
>>> import qualified Pipes.ByteString as B
>>> import qualified Pipes.Prelude as P
>>> import qualified Pipes.Parse as P
>>> import qualified Pipes.Attoparsec as P
>>> import qualified Pipes.Text as T
>>> import qualified Pipes.Text.Encoding as T
>>> import qualified Pipes.Text.IO as T
>>> import qualified Pipes.Group as G
>>> import qualified Pipes.Safe as S
>>> import qualified Pipes.Safe.Prelude as S
>>> import System.IO
>>> import System.IO.Error
>>> import System.Exit
>>> import System.Process.Streaming

-}

{- $collstdout  

This example uses the 'toLazyM' fold from @pipes-bytestring@.

>>> execute (pipeo (fromFold B.toLazyM)) (shell "echo aaa")
(ExitSuccess,"aaa\n")

'Siphon's are functors, so if we wanted to collect the output as a strict
'ByteString', we could do

>>> execute (pipeo (BL.toStrict <$> fromFold B.toLazyM)) (shell "echo aaa")
(ExitSuccess,"aaa\n")

Of course, collecting the output in this way breaks streaming. But it is OK
if the output is small.
-}


