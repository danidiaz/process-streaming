{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}


module System.Process.Streaming.Internal ( 
        Piping(..)
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
