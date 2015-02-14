
{-|
 @process-streaming@ uses the 'CreateProcess' record to describe the
 program to be executed. The user doesn't need to set the 'std_in',
 'std_out' and 'std_err' fields, as these are set automatically according
 to the 'Piping'.

 'Piping' is a datatype that specifies what standard streams to pipe and
 what to do with them. It has many constructors, one for each possible
 combination of streams.

 Constructors for 'Piping' usually take 'Siphon's as parameters.
 A 'Siphon' specifies what to do with a particular standard stream.

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

 'Siphon's have an 'Applicative' instance. 'pure' creates a 'Siphon' that
 drains a stream but does nothing with the data.
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
    
    -- * Collecting @stdout@ and @stderr@ independently
    -- $collstdoutstderr

    -- * Collecting @stdout@ as a lazy Text
    -- $collstdouttext

    -- * Consuming @stdout@ and @stderr@ combined as Text
    -- $collstdoutstderrtext
    
    -- * Feeding @stdin@, consuming @stdout@
    -- $feedstdincollstdout

    -- * Early termination
    -- $earlytermination
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

>>> execute (pipeo (fromFold B.toLazyM)) (shell "echo ooo")
(ExitSuccess,"ooo\n")

'Siphon's are functors, so if we wanted to collect the output as a strict
'ByteString', we could do

>>> execute (pipeo (BL.toStrict <$> fromFold B.toLazyM)) (shell "echo ooo")
(ExitSuccess,"ooo\n")

Of course, collecting the output in this way breaks streaming. But this is OK
if the output is small.
-}



{- $collstdoutstderr

We can use 'pipeoe' collect @stdout@ and @stderr@ concurrently:

>>> execute (pipeoe (fromFold B.toLazyM) (fromFold B.toLazyM)) (shell "{ echo ooo ; echo eee 1>&2 ; }")
(ExitSuccess,("ooo\n","eee\n"))

-}


{- $collstdouttext  

If we want to consume @stdout@ as text, we need to use the 'encoded'
function. 'encoded' takes as parameters a decoding function (the example
uses one from @pipes-text@) and a 'Siphon' that specifies how to handle the
leftovers. It returns a function that converts a 'Siphon' for text
into a 'Siphon' for bytes.

In the example we pass @pure id@ as the leftover-handling 'Siphon'. This
means "drain all the undecoded data remaining in the stream and return
unchanged the result of @(fromFold T.toLazyM)@". In other words: ignore any
leftovers.

>>> execute (pipeo (encoded T.decodeUtf8 (pure id) (fromFold T.toLazyM))) (shell "echo ooo")
(ExitSuccess,"ooo\n")

But suppose we want to interrupt the execution of the program when we
encounter a decoding error. In that case, we can pass @unwanted id@ as the
leftover-handling 'Siphon'. 'unwanted' constructs a 'Siphon' that fails
when the stream produces any output at all, meaning it will fail if any
leftovers remain. 'unwanted' uses the first leftovers that apear in the
stream as the error value. So, in this example the error type will be
'ByteString':

>>> executeFallibly (pipeo (encoded T.decodeUtf8 (unwanted id) (fromFold T.toLazyM))) (shell "echo ooo")
Right (ExitSuccess,"ooo\n")

Notice also that we had to switch from 'execute' to 'executeFallibly'. This
is because, for the first time in the tutorial, we actually have a need for
the error type. 'execute' only works when the error type is 'Void'.

Beware: even if the error type is 'Void', exceptions can still be thrown.
-}


{- $collstdoutstderrtext

Sometimes we want to consume both @stdout@ and @stderr@, not independently,
but combined into a single stream. We can use 'pipeoec' for that.

'pipeoec' takes as parameter a 'Siphon' for text, and two 'Lines' values
that know how to decode the bytes coming from @stdout@ and @stderr@ into
lines of text.

>>> :{ 
   let 
      lin = toLines T.decodeUtf8 (pure ()) 
      program = shell "{ echo ooo ; sleep 1 ; echo eee 1>&2 ; }"
   in execute (pipeoec lin lin (fromFold T.toLazyM)) program
   :}
(ExitSuccess,"ooo\neee\n")

We may wish to tag each line in the combined stream with its provenance. This can be done by using 'tweakLines' to modify each 'Lines' argument.

>>> :{ 
   let 
      lin = toLines T.decodeUtf8 (pure ()) 
      lin_stdout = tweakLines (\p -> P.yield "O" *> p) lin 
      lin_stderr = tweakLines (\p -> P.yield "E" *> p) lin 
      program = shell "{ echo ooo ; sleep 1 ; echo eee 1>&2 ; }"
   in execute (pipeoec lin_stdout lin_stderr (fromFold T.toLazyM)) program
   :}
(ExitSuccess,"Oooo\nEeee\n")

-}

{- $feedstdincollstdout

We can feed bytes to @stdin@ while we read @stdout@ or @stderr@. We use the
'Pump' datatype for that.

>>> execute (pipeio (fromProducer (yield "iii")) (fromFold B.toLazyM)) (shell "cat")
(ExitSuccess,((),"iii"))
-}


{- $earlytermination

An example of how returning a failure from a 'Siphon' interrupts the whole
computation and terminates the external program.

>>> executeFallibly (pipeo (siphon (\_ -> return (Left "oops")))) (shell "sleep infinity")
Left "oops"
-}
