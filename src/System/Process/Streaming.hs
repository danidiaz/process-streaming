-- |
-- This module contains helper functions and types built on top of
-- "System.Process".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- external processes.
--
-- 'Consumer's from @pipes@, 'Parser's from @pipes-parse@ and 'Fold's from
-- @foldl@ can be used to consume the standard streams, by
-- means of the auxiliary 'Fold1' datatype which is re-exported from the
-- @pipes-transduce@ package.
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleInstances #-}


module System.Process.Streaming ( 
        -- * Execution
          execute
        , executeFallibly
        -- * CreateProcess helpers
        , pipedShell
        , pipedProc
        -- * The Streams Applicative
        , Streams
        -- * Feeding stdin
        , feedBytes
        , feedLazyBytes
        , feedUtf8
        , feedLazyUtf8
        , feedProducer
        , feedProducerM
        , feedSafeProducer
        , feedFallibleProducer
        , feedCont
        -- * Consuming stdout and stderr
        , foldOut
        , foldErr
        , Pipes.Transduce.ByteString.intoLazyBytes
        , foldOutErr
        -- * Handling exit codes
        , exitCode
        , validateExitCode
        , withExitCode
        -- * Re-exports
        -- $reexports
        , module System.Process
        , module Pipes.Transduce
    ) where

import qualified Data.ByteString.Lazy
import Data.Monoid
import Data.Foldable
import Data.Bifunctor
import Data.ByteString
import Data.Text 
import qualified Data.Text.Encoding 
import qualified Data.Text.Lazy
import qualified Data.Text.Lazy.Encoding
import Data.Void
import Data.Functor.Day 
import Data.Profunctor (Star(..))
import Control.Applicative
import Control.Applicative.Lift
import Control.Monad
import Control.Monad.Trans.Except
import Control.Exception (onException,catch,IOException,mask,finally,throwIO)
import Control.Concurrent
import Control.Concurrent.Conceit
import Pipes
import qualified Pipes.Prelude
import Pipes.ByteString (fromHandle,toHandle,fromLazy)
import Pipes.Concurrent
import Pipes.Safe (SafeT,runSafeT)
import Pipes.Transduce
import Pipes.Transduce.ByteString
import System.IO
import System.Process
import System.Exit

{-|
  Execute an external program described by the 'CreateProcess' record. 

  The 'Streams' Applicative is used to specify how to handle the standard
  streams and the exit code. Since 'Streams' is an Applicative, a simple
  invocation of 'execute' could be

>>> execute (pipedShell "echo foo") (pure ())

  which would discard the program's stdout and stderr, and ignore the exit
  code. To actually get the exit code:

>>> execute (pipedShell "echo foo") exitCode
ExitSuccess

  To get stdout as a lazy 'Data.ByteString.Lazy.ByteString', along with the
  exit code:

>>> execute (pipedShell "echo foo") (liftA2 (,) (foldOut intoLazyBytes) exitCode)
("foo\n",ExitSuccess)

  'execute' respects all the fields of the 'CreateProcess' record. If stdout is
  not piped, but a handler is defined for it, the handler will see an empty
  stream:

>>> execute ((pipedShell "echo foo"){ std_out = Inherit }) (foldOut intoLazyBytes)
foo
""

   No effort is made to catch exceptions thrown during execution:

>>> execute (pipedShell "echo foo") (foldOut (withCont (\_ -> throwIO (userError "oops"))))
*** Exception: user error (oops)

   However, care is taken to automatically terminate the external process if an 
   exception (including asynchronous ones) or other type of error happens. 
   This means we can terminate the external process by killing 
   the thread that is running 'execute':

>>> forkIO (execute (pipedShell "sleep infinity") (pure ())) >>= killThread

 -}
execute :: CreateProcess -> Streams Void a -> IO a
execute cprocess pp = either absurd id <$> executeFallibly cprocess pp


{-| Like 'execute', but allows the handlers in the 'Streams' Applicative to interrupt the execution of the external process by returning a 'Left' value, in addition to throwing exceptions. This is sometimes more convenient:

>>> executeFallibly (pipedShell "sleep infinity") (foldOut (withFallibleCont (\_ -> pure (Left "oops"))))
Left "oops"

>>> executeFallibly (pipedShell "exit 1") validateExitCode
Left 1

    The first type parameter of 'Streams' is the error type. If it is never used, it remain polymorphic and may unify with 'Void' (as required by 'execute').

-}
executeFallibly :: 
       CreateProcess 
    -> Streams e a
    -> IO (Either e a)
executeFallibly record (Streams streams) = mask $ \restore -> do
    (mstdin,mstdout,mstderr,phandle) <- createProcess record
    let (clientx,cleanupx) = case mstdin of
            Nothing -> (pure (),pure ())
            Just handle -> (toHandle handle,hClose handle) 
        (producer1x,cleanup1) = case mstdout of
            Nothing -> (pure (),pure())
            Just handle -> (fromHandle handle,hClose handle)
        (producer2x,cleanup2) = case mstderr of
            Nothing -> (pure (),pure ())
            Just handle -> (fromHandle handle,hClose handle)
        streams' = 
              dap
            . trans1
                ( 
                  flip catchE (\e -> liftIO (terminateCarefully phandle) *> throwE e)
                . ExceptT
                . runConceit
                . dap
                . trans1 (\f -> Conceit (feed1Fallibly f clientx `finally` cleanupx))
                . trans2 (\f -> Conceit (fmap (fmap (\(x,_,_) -> x)) (Pipes.Transduce.fold2Fallibly f producer1x producer2x)))
                )
            . trans2 (\exitCodeHandler -> do 
                 c <- liftIO (waitForProcess phandle)
                 runStar exitCodeHandler c)
            $ streams 
    latch <- newEmptyMVar
    let innerAction = _runConceit $
            (_Conceit (takeMVar latch >> runExceptT streams'))
            <|>   
            (_Conceit (onException (putMVar latch () >> _runConceit Control.Applicative.empty) 
                                   (terminateCarefully phandle))) 
    (restore innerAction `onException` terminateCarefully phandle) `finally` cleanup1 `finally` cleanup2

terminateCarefully :: ProcessHandle -> IO ()
terminateCarefully pHandle = do
    mExitCode <- getProcessExitCode pHandle   
    case mExitCode of 
        Nothing -> catch 
            (terminateProcess pHandle) 
            (\(_::IOException) -> return ())
        Just _ -> return ()

{-| Same as 'System.Proces.shell', but sets 'std_in', 'std_out' and 'std_err' to 'CreatePipe'.		

-}
pipedShell :: String -> CreateProcess
pipedShell cmd = (shell cmd) { std_in = CreatePipe,
                               std_out = CreatePipe,
                               std_err = CreatePipe }

{-| Same as 'System.Proces.proc', but sets 'std_in', 'std_out' and 'std_err' to 'CreatePipe'.		

-}
pipedProc :: FilePath -> [String] -> CreateProcess
pipedProc path cmd = (proc path cmd) { std_in = CreatePipe,
                                       std_out = CreatePipe,
                                       std_err = CreatePipe }

{-|
   Executes an external process. The standard streams are piped and consumed in
a way defined by the 'Piping' argument. 

   This function re-throws any 'IOException's it encounters.

   Besides exceptions, if the consumption of the standard streams fails
   with @e@, the whole computation is immediately aborted and @e@ is
   returned. 

   If an exception or an error @e@ happen, the external process is
terminated.
 -}

newtype Feed1 b e a = Feed1 (Lift (Feed1_ b e) a) deriving (Functor)

newtype Feed1_ b e a = Feed1_ { runFeed1_ :: Consumer b IO () -> IO (Either e a) } deriving Functor

instance Bifunctor (Feed1_ b) where
  bimap f g (Feed1_ x) = Feed1_ $ fmap (liftM  (bimap f g)) x

{-| 
    'first' is useful to massage errors.
-}
instance Bifunctor (Feed1 b) where
    bimap f g (Feed1 x) = Feed1 (case x of
        Pure a -> Pure (g a)
        Other o -> Other (bimap f g o))

instance Applicative (Feed1 b e) where
    pure a = Feed1 (pure a)
    Feed1 fa <*> Feed1 a = Feed1 (fa <*> a)

{-| 
    'pure' writes nothing to @stdin@.
    '<*>' sequences the writes to @stdin@.
-}
instance Applicative (Feed1_ b e) where
  pure = Feed1_ . pure . pure . pure
  Feed1_ fs <*> Feed1_ as = 
      Feed1_ $ \consumer -> do
          (outbox1,inbox1,seal1) <- spawn' (bounded 1)
          (outbox2,inbox2,seal2) <- spawn' (bounded 1)
          runConceit $ 
              Conceit (runExceptT $ do
                           r1 <- ExceptT $ (fs $ toOutput outbox1) 
                                               `finally` atomically seal1
                           r2 <- ExceptT $ (as $ toOutput outbox2) 
                                               `finally` atomically seal2
                           return $ r1 r2 
                      )
              <* 
              Conceit (do
                         (runEffect $
                             (fromInput inbox1 >> fromInput inbox2) >-> consumer)
                            `finally` atomically seal1
                            `finally` atomically seal2
                         runExceptT $ pure ()
                      )

instance (Monoid a) => Monoid (Feed1 b e a) where
   mempty = pure mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

feed1Fallibly :: Feed1 b e a -> Consumer b IO () -> IO (Either e a)
feed1Fallibly (Feed1 (unLift -> s)) = runFeed1_ s

feedBytes :: Foldable f => f ByteString -> Streams e ()
feedBytes = feedProducer . each

feedLazyBytes :: Data.ByteString.Lazy.ByteString -> Streams e ()
feedLazyBytes = feedProducer . fromLazy 

feedUtf8 :: Foldable f => f Text -> Streams e ()
feedUtf8 = feedProducer . (\p -> p >-> Pipes.Prelude.map Data.Text.Encoding.encodeUtf8) . each

feedLazyUtf8 :: Data.Text.Lazy.Text -> Streams e ()
feedLazyUtf8 = feedProducer . fromLazy . Data.Text.Lazy.Encoding.encodeUtf8

feedProducer :: Producer ByteString IO () -> Streams e ()
feedProducer producer = liftFeed1 . Feed1 . Other . Feed1_ $ \consumer -> fmap pure $ runEffect (void producer >-> consumer) 
feedProducerM :: MonadIO m => (m () -> IO (Either e a)) -> Producer ByteString m r -> Streams e a
feedProducerM whittle producer = liftFeed1 . Feed1 . Other . Feed1_ $ \consumer -> whittle $ runEffect (void producer >-> hoist liftIO consumer) 

feedSafeProducer :: Producer ByteString (SafeT IO) () -> Streams e ()
feedSafeProducer = feedProducerM (fmap pure . runSafeT)

feedFallibleProducer :: Producer ByteString (ExceptT e IO) () -> Streams e ()
feedFallibleProducer = feedProducerM runExceptT

feedCont :: (Consumer ByteString IO () -> IO (Either e a)) -> Streams e a
feedCont = liftFeed1 . Feed1 . Other . Feed1_

foldOut :: Fold1 ByteString e r -> Streams e r
foldOut =  liftFold2 . Pipes.Transduce.liftFirst

foldErr :: Fold1 ByteString e r -> Streams e r
foldErr =  liftFold2 . Pipes.Transduce.liftSecond

foldOutErr :: Fold2 ByteString ByteString e r -> Streams e r
foldOutErr =  liftFold2

exitCode :: Streams e ExitCode
exitCode  = liftExitCodeValidation (Star pure)

validateExitCode :: Streams Int ()
validateExitCode =  liftExitCodeValidation . Star . fmap ExceptT . fmap pure $ validation
    where
    validation ExitSuccess = Right ()
    validation (ExitFailure i) = Left i

withExitCode :: (ExitCode -> IO (Either e a)) -> Streams e a
withExitCode =  liftExitCodeValidation . Star . fmap ExceptT

liftFeed1 :: Feed1 ByteString e a -> Streams e a
liftFeed1 f = Streams $
    day 
        (day (const . const <$> f)
             (pure ()))
        (pure ())

liftFold2 :: Fold2 ByteString ByteString e a -> Streams e a
liftFold2 f2 = Streams $
    day 
        (day (pure const)
             f2)
        (pure ())

liftExitCodeValidation :: (Star (ExceptT e IO) ExitCode a) -> Streams e a
liftExitCodeValidation v = Streams $ 
    swapped
        (day 
            (const <$> v)
            (pure ()))

newtype Streams e r = Streams (Day (Day (Feed1 ByteString e) (Fold2 ByteString ByteString e)) (Star (ExceptT e IO) ExitCode) r) deriving (Functor)

instance Bifunctor Streams where
    bimap f g (Streams d)  = Streams $ fmap g $
          trans1
            (  trans1 (first f)
             . trans2 (first f)
            )
        . trans2 (\(Star starfunc) -> Star (withExceptT f <$> starfunc))
        $ d


instance Applicative (Streams e) where
    pure a = Streams (pure a)

    Streams f <*> Streams x = Streams (f <*> x)

instance (Monoid a) => Monoid (Streams e a) where
   mempty = pure mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

{- $reexports
 
"System.Process" is re-exported in its entirety.

"Pipes.Transduce" from the @pipes-transduce@ package is re-exported in its entirety.

-} 
