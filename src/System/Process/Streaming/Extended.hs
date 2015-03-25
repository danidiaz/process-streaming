
{-|
-}

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Process.Streaming.Extended ( 
       Piap
    ,  piapi
    ,  piapo
    ,  piape
    ,  piapoe
    ,  samei
    ,  sameo
    ,  samee
    ,  sameioe
    ,  toPiping
    ,  pumpFromHandle 
    ,  siphonToHandle 
    ,  module System.Process.Streaming
    ) where

import Data.Text 
import Control.Applicative
import Control.Exception
import Control.Concurrent.Conceit
import Pipes.ByteString
import System.IO

import System.Process.Streaming
import System.Process.Streaming.Internal

toPiping :: Piap e a -> Piping e a  
toPiping (Piap f) = PPInputOutputError f

{-|
    Do stuff with @stdout@.
-}
piapo :: Siphon ByteString e a -> Piap e a
piapo s = Piap $ \(consumer, cleanup, producer1, producer2) -> do
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
piape :: Siphon ByteString e a -> Piap e a
piape s = Piap $ \(consumer, cleanup, producer1, producer2) -> do
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
piapi :: Pump ByteString e a -> Piap e a
piapi p = Piap $ \(consumer, cleanup, producer1, producer2) -> do
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
piapoe :: Lines e -> Lines e -> Siphon Text e a -> Piap e a
piapoe policy1 policy2 s = Piap $ \(consumer, cleanup, producer1, producer2) -> do
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
samei :: Piap e ()
samei = piapi $ pumpFromHandle System.IO.stdin

{-|
    Pipe the created process' @stdout@ to @stdout@.
-}
sameo :: Piap e ()
sameo = piapo $ siphonToHandle System.IO.stdout

{-|
    Pipe the created process' @stderr@ to @stderr@.
-}
samee :: Piap e ()
samee = piape $ siphonToHandle System.IO.stderr

sameioe :: Piap e ()
sameioe = samei *> sameo *> samee

pumpFromHandle :: Handle -> Pump ByteString e ()
pumpFromHandle = fromProducer . fromHandle

siphonToHandle :: Handle -> Siphon ByteString e ()
siphonToHandle = fromConsumer . toHandle
