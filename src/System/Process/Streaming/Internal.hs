{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}

module System.Process.Streaming.Internal ( 
        Piping(..), 
        Siphon(..),
        runSiphon,
        runSiphonDumb,
        Siphon_(..),
        exhaustive,
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

{-|
    A 'Piping' determines what standard streams will be piped and what to
do with them.

    The user doesn't need to manually set the 'std_in', 'std_out' and 'std_err'
fields of the 'CreateProcess' record to 'CreatePipe', this is done
automatically. 

    A 'Piping' is parametrized by the type @e@ of errors that can abort
the processing of the streams.
 -}
-- Knows that there is a stdin, stdout and a stderr,
-- but doesn't know anything about file handlers or CreateProcess.
data Piping e a = 
      PPNone a
    | PPOutput 
        (Producer ByteString IO () 
         -> 
         IO (Either e a))
    | PPError 
        (Producer ByteString IO () 
         -> 
         IO (Either e a))
    | PPOutputError 
        ((Producer ByteString IO ()
         ,Producer ByteString IO ()) 
         -> 
         IO (Either e a))
    | PPInput 
        ((Consumer ByteString IO ()
         ,IO ()) 
         -> 
         IO (Either e a))
    | PPInputOutput 
        ((Consumer ByteString IO ()
         ,IO ()
         ,Producer ByteString IO ()) 
         -> 
         IO (Either e a))
    | PPInputError 
        ((Consumer ByteString IO ()
         ,IO () 
         ,Producer ByteString IO ()) 
         -> 
         IO (Either e a))
    | PPInputOutputError 
        ((Consumer ByteString IO ()
         ,IO ()
         ,Producer ByteString IO ()
         ,Producer ByteString IO ()) 
         -> 
         IO (Either e a))
    deriving (Functor)


{-| 
    'first' is useful to massage errors.
-}
instance Bifunctor Piping where
  bimap f g pp = case pp of
        PPNone a -> PPNone $ 
            g a 
        PPOutput action -> PPOutput $ 
            fmap (fmap (bimap f g)) action
        PPError action -> PPError $ 
            fmap (fmap (bimap f g)) action
        PPOutputError action -> PPOutputError $ 
            fmap (fmap (bimap f g)) action
        PPInput action -> PPInput $ 
            fmap (fmap (bimap f g)) action
        PPInputOutput action -> PPInputOutput $ 
            fmap (fmap (bimap f g)) action
        PPInputError action -> PPInputError $ 
            fmap (fmap (bimap f g)) action
        PPInputOutputError action -> PPInputOutputError $ 
            fmap (fmap (bimap f g)) action

{-| 
    A 'Siphon' represents a computation that completely drains a producer, but
may fail early with an error of type @e@. 

 -}
newtype Siphon b e a = Siphon (Lift (Siphon_ b e) a) deriving (Functor)


{-| 
    'pure' creates a 'Siphon' that does nothing besides draining the
'Producer'. 

    '<*>' executes its arguments concurrently. The 'Producer' is forked so
    that each argument receives its own copy of the data.
-}
instance Applicative (Siphon b e) where
    pure a = Siphon (pure a)
    (Siphon fa) <*> (Siphon a) = Siphon (fa <*> a)

data Siphon_ b e a = 
         Exhaustive (forall r. Producer b IO r -> IO (Either e (a,r)))
       | Nonexhaustive (Producer b IO () -> IO (Either e a))
       deriving (Functor)


instance Applicative (Siphon_ b e) where
    pure a = Exhaustive $ \producer -> do
        r <- runEffect (producer >-> P.drain)
        pure (pure (a,r))
    s1 <*> s2 = bifurcate (nonexhaustive s1) (nonexhaustive s2)  
      where 
        bifurcate fs as = Exhaustive $ \producer -> do
            (outbox1,inbox1,seal1) <- spawn' Single
            (outbox2,inbox2,seal2) <- spawn' Single
            runConceit $
                (,)
                <$>
                Conceit (fmap (uncurry ($)) <$> conceit ((fs $ fromInput inbox1) 
                                                        `finally` atomically seal1) 
                                                        ((as $ fromInput inbox2) 
                                                        `finally` atomically seal2) 
                        )
                <*>
                _Conceit ((runEffect $ 
                              producer >-> P.tee (toOutput outbox1 >> P.drain) 
                                       >->       (toOutput outbox2 >> P.drain))   
                          `finally` atomically seal1 `finally` atomically seal2
                         ) 

nonexhaustive :: Siphon_ b e a -> Producer b IO () -> IO (Either e a)
nonexhaustive (Exhaustive e) = \producer -> liftM (fmap fst) (e producer)
nonexhaustive (Nonexhaustive u) = u

exhaustive :: Siphon_ b e a -> Producer b IO r -> IO (Either e (a,r))
exhaustive s = case s of 
    Exhaustive e -> e
    Nonexhaustive activity -> \producer -> do 
        (outbox,inbox,seal) <- spawn' Single
        runConceit $ 
            (,) 
            <$>
            Conceit (activity (fromInput inbox) `finally` atomically seal)
            <*>
            _Conceit (runEffect (producer >-> (toOutput outbox >> P.drain)) 
                      `finally` atomically seal
                     )

runSiphon :: Siphon b e a -> Producer b IO r -> IO (Either e (a,r))
runSiphon (Siphon (unLift -> s)) = exhaustive s

runSiphonDumb :: Siphon b e a -> Producer b IO () -> IO (Either e a)
runSiphonDumb (Siphon (unLift -> s)) = nonexhaustive $ case s of 
    Exhaustive _ -> s
    Nonexhaustive _ -> Exhaustive (exhaustive s)


instance Bifunctor (Siphon_ b) where
  bimap f g s = case s of
      Exhaustive u -> Exhaustive $ fmap (liftM  (bimap f (bimap g id))) u
      Nonexhaustive h -> Nonexhaustive $ fmap (liftM  (bimap f g)) h

{-| 
    'first' is useful to massage errors.
-}
instance Bifunctor (Siphon b) where
  bimap f g (Siphon s) = Siphon $ case s of
      Pure a -> Pure (g a)
      Other o -> Other (bimap f g o)

instance (Monoid a) => Monoid (Siphon b e a) where
   mempty = pure mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2



