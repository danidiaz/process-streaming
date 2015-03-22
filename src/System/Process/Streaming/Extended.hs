
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
    ,  sameStdin 
    ,  sameStdout
    ,  sameStderr
    ,  sameStreams
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

newtype Pap e a = Pap { runPap :: (Consumer ByteString IO (), IO (), Producer ByteString IO (), Producer ByteString IO ()) -> IO (Either e a) } deriving (Functor)

instance Bifunctor Pap where
  bimap f g (Pap action) = Pap $ fmap (fmap (bimap f g)) action

instance Applicative (Pap e) where
  pure a = Pap $ \(consumer, cleanup, producer1, producer2) -> do
      let nullInput = runPump (pure ()) consumer `finally` cleanup
          drainOutput = runSiphon (pure ()) producer1
          drainError = runSiphon (pure ()) producer2
      runConceit $ 
          (\_ _ _ -> a)
          <$>
          Conceit nullInput
          <*>
          Conceit drainOutput
          <*>
          Conceit drainError

  (Pap fa) <*> (Pap fb) = Pap $ \(consumer, cleanup, producer1, producer2) -> do
        latch <- newEmptyMVar :: IO (MVar ())
        (ioutbox, iinbox, iseal) <- spawn' Single
        (ooutbox, oinbox, oseal) <- spawn' Single
        (eoutbox, einbox, eseal) <- spawn' Single
        (ioutbox2, iinbox2, iseal2) <- spawn' Single
        (ooutbox2, oinbox2, oseal2) <- spawn' Single
        (eoutbox2, einbox2, eseal2) <- spawn' Single
        let reroutei = runEffect (fromInput (iinbox <> iinbox2) >-> consumer)
                       `finally` atomically iseal 
                       `finally` atomically iseal2
                       `finally` cleanup
            rerouteo = runEffect (producer1 >-> toOutput (ooutbox <> ooutbox2))
                       `finally` atomically oseal 
                       `finally` atomically oseal2
            reroutee = runEffect (producer2 >-> toOutput (eoutbox <> eoutbox2))
                       `finally` atomically eseal 
                       `finally` atomically eseal2
            deceivedf = fa 
                (toOutput ioutbox <* liftIO (putMVar latch ()), 
                 atomically iseal, 
                 fromInput oinbox, 
                 fromInput einbox)
                 `finally` atomically iseal 
                 `finally` atomically oseal 
                 `finally` atomically eseal 
            deceivedx = fb 
                (liftIO (takeMVar latch) *> toOutput ioutbox2, 
                 atomically iseal2, 
                 fromInput oinbox2, 
                 fromInput einbox2)
                 `finally` atomically iseal2 
                 `finally` atomically oseal2 
                 `finally` atomically eseal2 
        runConceit $
            _Conceit reroutei 
            *>
            _Conceit rerouteo 
            *> 
            _Conceit reroutee 
            *> 
            (Conceit deceivedf <*> Conceit deceivedx)

toPiping :: Pap e a -> Piping e a  
toPiping (Pap f) = undefined
toPiping (Pap f) = PPInputOutputError f

{-|
    Pipe @stdout@.
-}
papo :: Siphon ByteString e a -> Pap e a
papo _ = undefined
--papo (runSiphonDumb -> siphonout) = PPOutput $ siphonout

{-|
    Pipe @stderr@.
-}
pape :: Siphon ByteString e a -> Pap e a
pape _ = undefined

{-|
    Pipe @stdin@.
-}
papi :: Siphon ByteString e a -> Pap e a
papi _ = undefined

{-|
    Pipe @stdout@ and @stderr@ and consume them combined as 'Text'.  
-}
papoe :: Lines e -> Lines e -> Siphon Text e a -> Piping e a
papoe policy1 policy2 (runSiphonDumb -> siphon) = undefined

sameStdin :: Pap e ()
sameStdin = undefined

sameStdout :: Pap e ()
sameStdout = undefined

sameStderr :: Pap e ()
sameStderr = undefined

sameStreams :: Pap e ()
sameStreams = sameStdin *> sameStdout *> sameStderr

pumpFromHandle :: Handle -> Pump ByteString e ()
pumpFromHandle = undefined

siphonToHandle :: Handle -> Siphon ByteString e ()
siphonToHandle = undefined

