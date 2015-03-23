
{-|
-}

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Process.Streaming.Extended ( 
       Pap
    ,  papi
    ,  papo
    ,  pape
    ,  papoe
    ,  samei
    ,  sameo
    ,  samee
    ,  sameioe
    ,  toPiping
    ,  pumpFromHandle 
    ,  siphonToHandle 
    ,  module System.Process.Streaming
    ) where

import Data.Maybe
import qualified Data.ByteString.Lazy as BL
import Data.Bifunctor
import Data.Functor.Identity
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Either
import Data.Monoid
import Data.Foldable
import Data.Traversable
import Data.Tree
import Data.String
import qualified Data.Text.Lazy as TL
import Data.Text 
import Data.Text.Encoding hiding (decodeUtf8)
import Data.Void
import Data.List.NonEmpty
import qualified Data.List.NonEmpty as N
import Control.Applicative
import Control.Applicative.Lift
import Control.Monad
import Control.Monad.Trans.Free hiding (Pure)
import Control.Monad.Trans.Except
import Control.Monad.Trans.State
import Control.Monad.Trans.Writer.Strict
import qualified Control.Foldl as L
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Conceit
import Pipes
import qualified Pipes as P
import qualified Pipes.Prelude as P
import Pipes.Lift
import Pipes.ByteString
import Pipes.Parse
import qualified Pipes.Text as T
import Pipes.Text.Encoding (decodeUtf8)
import qualified Pipes.Text.Encoding as T
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.IO.Error
import System.Process
import System.Process.Lens
import System.Exit

import System.Process.Streaming
import System.Process.Streaming.Internal

toPiping :: Pap e a -> Piping e a  
toPiping (Pap f) = PPInputOutputError f

{-|
    Do stuff with @stdout@.
-}
papo :: Siphon ByteString e a -> Pap e a
papo s = Pap $ \(consumer, cleanup, producer1, producer2) -> do
    let nullInput = runPump (pure ()) consumer `finally` cleanup
        drainOutput = runSiphonDumb s producer1 
        drainError = runSiphonDumb (pure ()) producer2
    runConceit $ 
        (\_ r _ -> r)
        <$>
        Conceit nullInput
        <*>
        Conceit drainOutput
        <*>
        Conceit drainError

{-|
    Do stuff with @stderr@.
-}
pape :: Siphon ByteString e a -> Pap e a
pape s = Pap $ \(consumer, cleanup, producer1, producer2) -> do
    let nullInput = runPump (pure ()) consumer `finally` cleanup
        drainOutput = runSiphonDumb (pure ()) producer1 
        drainError = runSiphonDumb s producer2
    runConceit $ 
        (\_ _ r -> r)
        <$>
        Conceit nullInput
        <*>
        Conceit drainOutput
        <*>
        Conceit drainError

{-|
    Do stuff with @stdin@.
-}
papi :: Pump ByteString e a -> Pap e a
papi p = Pap $ \(consumer, cleanup, producer1, producer2) -> do
    let nullInput = runPump p consumer `finally` cleanup
        drainOutput = runSiphonDumb (pure ()) producer1 
        drainError = runSiphonDumb (pure ()) producer2
    runConceit $ 
        (\r _ _ -> r)
        <$>
        Conceit nullInput
        <*>
        Conceit drainOutput
        <*>
        Conceit drainError

{-|
    Do stuff with @stdout@ and @stderr@ combined as 'Text'.  
-}
papoe :: Lines e -> Lines e -> Siphon Text e a -> Pap e a
papoe policy1 policy2 s = Pap $ \(consumer, cleanup, producer1, producer2) -> do
    let nullInput = runPump (pure ()) consumer `finally` cleanup
        combination = combined policy1 policy2 (runSiphonDumb s) producer1 producer2 
    runConceit $ 
        (\_ r -> r)
        <$>
        Conceit nullInput
        <*>
        Conceit combination

{-|
    Pipe @stdin@ to the created process' @stdin@.
-}
samei :: Pap e ()
samei = papi $ pumpFromHandle System.IO.stdin

{-|
    Pipe the created process' @stdout@ to @stdout@.
-}
sameo :: Pap e ()
sameo = papo $ siphonToHandle System.IO.stdout

{-|
    Pipe the created process' @stderr@ to @stderr@.
-}
samee :: Pap e ()
samee = pape $ siphonToHandle System.IO.stderr

sameioe :: Pap e ()
sameioe = samei *> sameo *> samee

pumpFromHandle :: Handle -> Pump ByteString e ()
pumpFromHandle = fromProducer . fromHandle

siphonToHandle :: Handle -> Siphon ByteString e ()
siphonToHandle = fromConsumer . toHandle

-- not sure how to do this
-- siphonThrowIO :: Exception ex => (e -> ex) -> Siphon b e a -> Siphon b e' a
-- siphonThrowIO exgen = 
--   let elide f = \producer -> do
--          result <- f producer
--          case result of
--              Left e -> throwIO $ exgen e 
--              Right a -> return $ Right a
--   in Siphon . Other . Exhaustive . elide . runSiphon 
