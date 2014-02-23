
-- |
--
-----------------------------------------------------------------------------


module System.Process.Streaming.Tutorial ( 
    -- * Introduction
    -- $introduction
    -- * stdin and stderr to different files
    -- $stdinstderr
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
