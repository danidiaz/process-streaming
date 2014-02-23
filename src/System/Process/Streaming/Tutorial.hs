
-- |
--
-----------------------------------------------------------------------------


module System.Process.Streaming.Tutorial ( 
    -- * Introduction
    -- $introduction
  
    -- * stdin and stderr to different files
    -- $stdinstderr
    
    -- * Missing executable
    -- $missingexec

    -- * Combining stdout and stderr
    -- $combinelines
    ) where

{- $introduction 
These examples require the @OverloadedStrings@ extension. 

Some preliminary imports: 

> module Main where
> 
> import Data.Bifunctor
> import Data.Either
> import qualified Data.Attoparsec.Text as A
> import Control.Applicative
> import Control.Monad
> import Control.Monad.Writer.Strict
> import Control.Concurrent (threadDelay)
> import Pipes
> import Pipes.ByteString
> import qualified Pipes.Prelude as P
> import qualified Pipes.Parse as P
> import qualified Pipes.Attoparsec as P
> import qualified Pipes.Text as T
> import qualified Pipes.Text.Encoding as T
> import qualified Pipes.Text.IO as T
> import qualified Pipes.Safe as S
> import qualified Pipes.Safe.Prelude as S
> import System.IO
> import System.Process
> import System.Process.Streaming

-}


{- $stdinstderr
 
Using 'separate' to consume @stdout@ and @stderr@ concurrently, and functions
from @pipes-safe@ to write the files.

> example1 :: IO (Either String ((),()))
> example1 = exitCode show $
>     execute program show $ separate 
>         (consume "stdout.log")
>         (consume "stderr.log")
>     where
>     consume file = surely . safely . useConsumer $
>         S.withFile file WriteMode toHandle
>     program = shell "{ echo ooo ; echo eee 1>&2 ; }"
-}


{- $missingexec
 
Missing executables and other 'IOException's are converted to an error type @e@
and returned in the 'Left' of an 'Either':

> example2 :: IO (Either String ((),()))
> example2 = exitCode show $ 
>     execute (proc "fsdfsdf" []) show $ separate 
>         nop
>         nop 

Returns:

>>> Left "fsdfsdf: createProcess: runInteractiveProcess: exec: does not exist (No such file or directory)"

-}


{- $combinelines
 
Here we use 'combineLines' to process 'stdout' and 'stderr' together.

Notice that they are consumed together as 'Text'. We have to specify a decoding
function for each stream, and a 'LeftoverPolicy' as well.

We also add a prefix to the lines coming from @stderr@.

> example3 :: IO (Either String ())
> example3 = exitCode show $ 
>    execute program show $ combineLines
>        (linePolicy T.decodeIso8859_1 id policy)
>        (linePolicy T.decodeIso8859_1 annotate policy)
>        (surely . safely . useConsumer $ 
>            S.withFile "combined.txt" WriteMode T.toHandle)
>     where
>     policy = failOnLeftovers $ \_ _->"badbytes"
>     annotate x = P.yield "errprefix: " *> x
>     program = shell "{ echo ooo ; echo eee 1>&2 ; echo ppp ;  echo ffff 1>&2 ;}"

-}
