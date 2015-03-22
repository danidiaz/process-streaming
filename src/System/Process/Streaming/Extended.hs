
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

newtype Pap e a = Pap { runPap :: (Consumer ByteString IO (), IO (), Producer ByteString IO (), Producer ByteString IO ()) -> IO (Either e a) } deriving (Functor)

instance Bifunctor Pap where
  bimap f g (Pap action) = Pap $ fmap (fmap (bimap f g)) action

instance Applicative (Pap e) where
  pure a = undefined
  (Pap fa) <*> (Pap fb) = undefined

