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
import System.IO.Error

-- stdout and stderr to different files, using pipes-safe
example1 :: IO (Either String (ExitCode,()))
example1 = execute2 "nohandle!" show create $ \(hout,herr) -> mapConcE_ consume' $
        [ (hout,"stdout.log"), (herr,"stderr.log") ]
    where
    create = set stream3 pipe2 $ proc "script1.bat" []
    consume' (h,file) = consume show h $ 
        safely $ useConsumer ignoreLeftovers $ 
            S.withFile file WriteMode toHandle

-- missing executable
example2 :: IO (Either String (ExitCode,()))
example2 = execute2 "nohandle!" show create $ \_ -> return $ Right ()
    where
    create = set stream3 pipe2 $ proc "asdfasdf.bat" []

---- stream to console the combined lines of stdout and stderr
example3 :: IO (Either String (ExitCode,()))
example3 = do
    execute2 "nohandle!" show create $ \(hout,herr) -> consumeCombinedLines show 
        [ (hout, decodeLines T.decodeIso8859_1 id, leftoverp)
        , (herr, decodeLines T.decodeIso8859_1 $ \x -> yield "errprefix: " *> x , leftoverp) 
        ]
        (safely $ useConsumer' $ S.withFile "combined.txt" WriteMode T.toHandle)
    where
    create = set stream3 pipe2 $ proc "script1.bat" []
    leftoverp = firstFailingBytes (const "badbytes")





