
{-|
 @process-streaming@ reuses the 'CreateProcess' record from @process@ to
 describe the external program. The difference is that the user doesn't
 need to set the 'std_in', 'std_out' and 'std_err' fields, as these are
 set automatically according to the 'Piping'.

 'Piping' is a datatype that specifies what streams to pipe and what to
 do with them. It has many constructors, one for each possible
 combination of streams.

 Constructors for 'Piping' usually take 'Siphon's as parameters.
 A 'Siphon' specifies what to do with a particular stream.

 'Siphon's can be built from each of the typical ways of consuming
 a 'Producer' in the @pipes@ ecosystem:

 * Regular 'Consumer's (with 'fromConsumer', 'fromConsumerM').
       
 * Folds from the @pipes@ 'Pipes.Prelude' or specialized folds from
 @pipes-bytestring@ or @pipes-text@ (with 'fromFold', 'fromFold'').
 
 * 'Parser's from @pipes-parse@ (with 'fromParser' and 'fromParserM').
 
 * 'Applicative' folds from the @foldl@ package (with 'fromFoldl',
 'fromFoldlIO' and 'fromFoldlM').
 
 * In general, any computation that does something with a 'Producer' (with
 'siphon' and 'siphon''). 

 'Siphon's have an explicit error type; when a 'Siphon' reading one of the
 standard streams fails, the external program is immediately terminated and
 the error value is returned.

 A 'Siphon' reading a stream always consumes the whole stream. If the user
 wants to interrupt the computation early, he can return a failure (or
 throw an exception).
-}

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

import System.Process.Streaming

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

Of course, collecting the output in this way breaks streaming. But this is OK
if the output is small.
-}


