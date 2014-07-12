
-- |
--
-----------------------------------------------------------------------------


module System.Process.Streaming.Tutorial ( 
    -- * Introduction
    -- $introduction
  
    -- * Stdin and stderr to different files
    -- $stdinstderr
    
    -- * Missing executable
    -- $missingexec

    -- * Combining stdout and stderr
    -- $combinelines

    -- * Running two parsers in parallel 
    -- $forkProd
    
    -- * Aborting an execution
    -- $fastExit

    -- * Feeding stdin, collecting stdout as text
    -- $cat

    -- * Collecting stdout and stderr as bytestring
    -- $bscollect

    -- * Counting words
    -- $wordcount

    -- * ghci
    -- $ghci
    ) where

{- $introduction 
These examples require the @OverloadedStrings@ extension. 

Some preliminary imports: 

> module Main where
> 
> import Data.Bifunctor
> import Data.Monoid
> import qualified Data.Attoparsec.Text as A
> import Control.Applicative
> import Control.Monad
> import Control.Lens (view)
> import Pipes
> import qualified Pipes.ByteString as B
> import qualified Pipes.Prelude as P
> import qualified Pipes.Parse as P
> import qualified Pipes.Attoparsec as P
> import qualified Pipes.Text as T
> import qualified Pipes.Text.Encoding as T
> import qualified Pipes.Text.IO as T
> import qualified Pipes.Group as G
> import qualified Pipes.Safe as S
> import qualified Pipes.Safe.Prelude as S
> import System.IO
> import System.IO.Error
> import System.Exit
> import System.Process.Streaming

-}


{- $stdinstderr
 
Using 'separated' to consume @stdout@ and @stderr@ concurrently, and functions
from @pipes-safe@ to write the files.

> example1 :: IO (Either String ((),()))
> example1 = simpleSafeExecute
>          (pipeoe $ separated (consume "stdout.log") (consume "stderr.log"))
>          (shell "{ echo ooo ; echo eee 1>&2 ; }")
>      where
>      consume file = surely . safely . useConsumer $
>          S.withFile file WriteMode B.toHandle

-}


{- $missingexec
 
Missing executables and other 'IOException's are converted to an error type @e@
and returned in the 'Left' of an 'Either':

> example2 :: IO (Either String ())
> example2 = simpleSafeExecute nopiping (proc "fsdfsdf" [])

Returns:

>>> Left "fsdfsdf: createProcess: runInteractiveProcess: exec: does not exist (No such file or directory)"

-}


{- $combinelines
 
Here we use 'combined' to process 'stdout' and 'stderr' together.

Notice that they are consumed together as 'Text'. We have to specify a decoding
function for each stream, and a 'LeftoverPolicy' as well.

We also add a prefix to the lines coming from @stderr@.

> example3 :: IO (Either String ())
> example3 = simpleSafeExecute
>        (pipeoe $ combined
>            (linePolicy T.decodeIso8859_1 id policy)
>            (linePolicy T.decodeIso8859_1 annotate policy)
>            (surely . safely . useConsumer $
>                S.withFile "combined.txt" WriteMode T.toHandle))
>        (shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ; }")
>     where
>         policy = failOnLeftovers $ \_ _->"badbytes"
>         annotate x = P.yield "errprefix: " *> x

-}


{- $forkProd

Plugging parsers from @pipes-parse@ into 'separated' or 'combined' is easy
because running 'evalStateT' on a parser returns a function that consumes a
'Producer'.

In this example we define two Attoparsec Text parsers and we convert them to
Pipes parsers using function 'parse' from package @pipes-attoparsec@. 

Stdout is decoded to Text and parsed by the two parsers in parallel using the
auxiliary 'forkSiphon' function. The results are aggregated in a tuple.

Stderr is ignored using the 'nop' function.

> parseChars :: Char -> A.Parser [Char] 
> parseChars c = fmap mconcat $ 
>     many (A.notChar c) *> A.many1 (some (A.char c) <* many (A.notChar c))
> 
> parser1 = parseChars 'o'
>
> parser2 = parseChars 'a'
> 
> example4 ::IO (Either String (([Char], [Char]),()))
> example4 = simpleSafeExecute
>        (pipeoe $ separated
>            (encoding T.decodeIso8859_1 (failOnLeftovers $ \_ _->"badbytes") $
>                forkSiphon (adapt parser1) (adapt parser2))
>            nop)
>        (shell "{ echo ooaaoo ; echo aaooaoa; }")
>     where
>        adapt p = P.evalStateT $ do
>            r <- P.parse p
>            return $ case r of
>                Just (Right r') -> Right r'
>                _ -> Left "parse error"

Returns:

>>> Right (("ooooooo","aaaaaa"),())

-}


{- $fastExit

If any function consuming a standard stream returns with an error value @e@,
the external program is terminated and the computation returns immediately with
@e@.

> example5 ::IO (Either String ((),()))
> example5 = simpleSafeExecute
>         (pipeoe $ separated (\_ -> return $ Left "fast return!") nop)
>         (shell "sleep 10s")

Returns:

>>> Left "fast return!"

If we change the stdout consuming function to 'nop', 'example5' waits 10
seconds. 
-}


{- $cat

In this example we invoke the @cat@ command, feeding its input stream with a
'ByteString'.

We decode stdout to Text and collect the whole output using a fold from
@pipes-text@. 

Plugging folds defined in "Pipes.Prelude" (or @pipes-bytestring@ or
@pipes-text@) into 'separated' or 'combined' is easy because the folds
return functions that consume 'Producer's. 

Notice that @stdin@ is written concurrently with the reading of @stdout@. It is
not the case that @sdtin@ is written first and then @stdout@ is read. 

> example6 = simpleSafeExecute
>         (pipeioe
>             (surely . useProducer $ yield "aaaaaa\naaaaa")
>             (separated
>                 (encoding T.decodeIso8859_1 ignoreLeftovers $ surely $ T.toLazyM)
>                 nop))
>         (shell "cat")

Returns:

>>> Right ((),("aaaaaa\naaaaa",()))

-}

{- $bscollect
 
In this example we collect @stdout@ and @stderr@ as lazy bytestrings, using a
fold defined in @pipes-bytestring@.

> example7 = simpleSafeExecute
>         (pipeoe $ separated (surely B.toLazyM) (surely B.toLazyM))
>         (shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ; }")

Returns:

>>> Right ("ooo\nppp\n","eee\nffff\n")
-}


{- $wordcount
 
  In this example we count words emitted to @stdout@ in a streaming fashion,
without having to keep whole words in memory.

  We use a lens from @pipes-text@ to split the text into words, and a trivial
fold from @pipes-group@ to create a 'Producer' of 'Int' values. Then we sum the
ints using a fold from "Pipes.Prelude".
 
> example8 = simpleSafeExecute
>         (pipeoe $ separated
>              (encoding T.decodeIso8859_1 ignoreLeftovers $ surely $
>                   P.sum . G.folds const () (const 1) . view T.words)
>              nop)
>         (shell "{ echo aaa ; echo bbb ; echo ccc ; }")

-}

{- $ghci

Sometimes it's useful to launch external programs during a ghci session, like
this:

>>> a <- async $ execute (pipeoe (separated nop nop)) (proc "xeyes" [])

Cancelling the async causes the termination of the external program:

>>> cancel a

Waiting for the async returns the result:

>>> wait a

-}
