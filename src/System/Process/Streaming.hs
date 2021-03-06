-- |
-- This module contains helper functions and types built on top of
-- "System.Process".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- external processes.
--
-- 'Consumer's from @pipes@, 'Parser's from @pipes-parse@ and 'Fold's from
-- @foldl@ can be used to consume the standard streams, by
-- means of the auxiliary 'Fold1' datatype from @pipes-transduce@.
--
-- The entirety of "System.Process" and "Pipes.Transduce" is re-exported for
-- convenience.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE CPP #-}


module System.Process.Streaming ( 
        -- * Execution
          execute
        , executeFallibly
        -- ** Unbuffered stdin
        , executeInteractive
        , executeInteractiveFallibly
        -- * CreateProcess helpers
        , piped
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
        -- $folds
        , foldOut
        , foldErr
        , Pipes.Transduce.ByteString.intoLazyBytes
        , foldOutErr
        -- * Handling exit codes
        , exitCode
        , validateExitCode
        , withExitCode
        -- * A GHCi idiom
        -- $ghci
        , module System.Process
        , module Pipes.Transduce
    ) where

import qualified Data.ByteString.Lazy
import qualified Data.Semigroup as S
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
import Control.Exception (onException,catch,IOException,mask,finally)
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

{- $setup

>>> :set -XOverloadedStrings
>>> import Control.Exception (throwIO)
>>> import qualified System.Process.Streaming.Text as PT

-}

{-|
  Execute an external program described by the 'CreateProcess' record. 

  The 'Streams' Applicative specifies how to handle the standard
  streams and the exit code. Since 'Streams' is an Applicative, a simple
  invocation of 'execute' could be

>>> execute (piped (shell "echo foo")) (pure ())

  which would discard the program's stdout and stderr, and ignore the exit
  code. To actually get the exit code:

>>> execute (piped (shell "echo foo")) exitCode
ExitSuccess

  To collect stdout as a lazy 'Data.ByteString.Lazy.ByteString' along with the
  exit code:

>>> execute (piped (shell "echo foo")) (liftA2 (,) (foldOut intoLazyBytes) exitCode)
("foo\n",ExitSuccess)

  'execute' respects all the fields of the 'CreateProcess' record. If stdout is
  not piped, but a handler is defined for it, the handler will see an empty
  stream:

>>> execute ((shell "echo foo"){ std_out = Inherit }) (foldOut intoLazyBytes)
foo
""

   No effort is made to catch exceptions thrown during execution:

>>> execute (piped (shell "echo foo")) (foldOut (withCont (\_ -> throwIO (userError "oops"))))
*** Exception: user error (oops)

   However, care is taken to automatically terminate the external process if an 
   exception (including asynchronous ones) or other type of error happens. 
   This means we can terminate the external process by killing 
   the thread that is running 'execute':

>>> forkIO (execute (piped (shell "sleep infinity")) (pure ())) >>= killThread

 -}
execute :: CreateProcess -> Streams Void a -> IO a
execute cprocess pp = either absurd id <$> executeFallibly cprocess pp

{-| Like 'execute', but 'std_in' will be unbuffered if piped.		

-}
executeInteractive :: CreateProcess -> Streams Void a -> IO a
executeInteractive cprocess pp = either absurd id <$> executeInteractiveFallibly cprocess pp

{-| Like 'execute', but allows the handlers in the 'Streams' Applicative to interrupt the execution of the external process by returning a 'Left' value, in addition to throwing exceptions. This is sometimes more convenient:

>>> executeFallibly (piped (shell "sleep infinity")) (foldOut (withFallibleCont (\_ -> pure (Left "oops"))))
Left "oops"

>>> executeFallibly (piped (shell "exit 1")) validateExitCode
Left 1

    The first type parameter of 'Streams' is the error type. If it is never used, it remains polymorphic and may unify with 'Void' (as required by 'execute').

-}
executeFallibly :: 
       CreateProcess 
    -> Streams e a
    -> IO (Either e a)
executeFallibly = executeFalliblyInternal (\_ -> return ())

{-| Like 'executeFallibly', but 'std_in' will be unbuffered if piped.		

-}
executeInteractiveFallibly :: 
       CreateProcess 
    -> Streams e a
    -> IO (Either e a)
executeInteractiveFallibly = executeFalliblyInternal (\h -> hSetBuffering h NoBuffering)

executeFalliblyInternal :: 
       (Handle -> IO ())
    -> CreateProcess 
    -> Streams e a
    -> IO (Either e a)
executeFalliblyInternal adapter record (Streams streams) = mask $ \restore -> do
    (mstdin,mstdout,mstderr,phandle) <- createProcess record
    forM_ mstdin adapter
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
    -- The following is a workaround for the fact that, in Windows, IO actions
    -- are not interruptible: https://ghc.haskell.org/trac/ghc/ticket/7353
    --
    -- This is annoying because we want to kill the external process in case
    -- of an asynchronous exception.
    --
    -- What we do is create a thread with the sole purpose of being a "soft
    -- target" for the asychronous exception. That thread installs an exception
    -- handler that kills the external process.
    -- 
    -- We must be sure that the handler is installed before anything is read
    -- form a standard stream, that's why we use the a MVar.
    latch <- newEmptyMVar
    let killable = _runConceit $
            (_Conceit (takeMVar latch >> runExceptT streams'))
            <|>   
            (_Conceit (onException (putMVar latch () >> _runConceit Control.Applicative.empty) 
                                   (terminateCarefully phandle))) 
    -- Handles must be closed *after* terminating the process, because a close
    -- operation may block if the external process has unflushed bytes in the stream.
    (restore killable `onException` terminateCarefully phandle) `finally` cleanup1 `finally` cleanup2

terminateCarefully :: ProcessHandle -> IO ()
terminateCarefully pHandle = do
    mExitCode <- getProcessExitCode pHandle   
    case mExitCode of 
        Nothing -> catch 
            (terminateProcess pHandle) 
            (\(_::IOException) -> return ())
        Just _ -> return ()

{-| Sets 'std_in', 'std_out' and 'std_err' in the 'CreateProcess' record to
    'CreatePipe'. 

    Any unpiped stream will appear to the 'Streams' handlers as empty.		

-}
piped :: CreateProcess -> CreateProcess
piped cmd = cmd { std_in = CreatePipe,
                  std_out = CreatePipe,
                  std_err = CreatePipe }

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


instance (S.Semigroup a) => S.Semigroup (Feed1 b e a) where
     s1 <> s2 = (S.<>) <$> s1 <*> s2

#if !(MIN_VERSION_base(4,11,0))
instance (Monoid a,S.Semigroup a) => Monoid (Feed1 b e a) where
#else
instance (Monoid a) => Monoid (Feed1 b e a) where
#endif
   mempty = pure mempty
#if !(MIN_VERSION_base(4,11,0))
   mappend = (S.<>)
#endif

feed1Fallibly :: Feed1 b e a -> Consumer b IO () -> IO (Either e a)
feed1Fallibly (Feed1 (unLift -> s)) = runFeed1_ s

{-| Feed any 'Foldable' container of strict 'Data.ByteString's to @stdin@.		

-}
feedBytes :: Foldable f => f ByteString -> Streams e ()
feedBytes = feedProducer . each

{-| Feed a lazy 'Data.Lazy.ByteString' to @stdin@.		

-}
feedLazyBytes :: Data.ByteString.Lazy.ByteString -> Streams e ()
feedLazyBytes = feedProducer . fromLazy 

{-| Feed any 'Foldable' container of strict 'Data.Texts's to @stdin@, encoding
    the texts as UTF8.		

-}
feedUtf8 :: Foldable f => f Text -> Streams e ()
feedUtf8 = feedProducer . (\p -> p >-> Pipes.Prelude.map Data.Text.Encoding.encodeUtf8) . each

{-| Feed a lazy 'Data.Lazy.Text' to @stdin@, encoding it as UTF8.		

-}
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


{-| Feed @stdin@ by running a pipes 'Consumer'. This allows bracketing
    functions like 'withFile' inside the handler.		

-}
feedCont :: (Consumer ByteString IO () -> IO (Either e a)) -> Streams e a
feedCont = liftFeed1 . Feed1 . Other . Feed1_

{- $folds

    These functions take as parameters the 'Pipes.Transduce.Fold1' and
    'Pipes.Transduce.Fold2' datatypes defined in the @pipes-transduce@ package.

    A convenience 'intoLazyBytes' 'Pipes.Transduce.Fold1' that collects a stream into a 
    lazy 'Data.ByteString.Lazy.ByteString' is re-exported.
-}

{-| Consume standard output.		

-}
foldOut :: Fold1 ByteString e r -> Streams e r
foldOut =  liftFold2 . Pipes.Transduce.liftFirst

{-| Consume standard error.		

-}
foldErr :: Fold1 ByteString e r -> Streams e r
foldErr =  liftFold2 . Pipes.Transduce.liftSecond

{-| Consume standard output and error together. This enables combining them in a single stream. See also 'System.Process.Streaming.Text.bothAsUtf8x' and 'System.Process.Streaming.Text.combinedLines'.

-}
foldOutErr :: Fold2 ByteString ByteString e r -> Streams e r
foldOutErr =  liftFold2

{-| Simply returns the 'ExitCode'.		

-}
exitCode :: Streams e ExitCode
exitCode  = liftExitCodeValidation (Star pure)


{-| Fails with the error code when 'ExitCode' is not 'ExitSuccess'.

-}
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

{-| The type of handlers that write to piped @stdin@, consume piped @stdout@ and
    @stderr@, and work with the process exit code, eventually returning a value of
    type @r@, except when an error @e@ interrups the execution.

    Example of a complex handler:

>>> :{ 
    execute (piped (shell "{ cat ; sleep 1 ; echo eee 1>&2 ; }")) $ 
        (\_ _ ob eb et oet c -> (ob,eb,et,oet,c)) 
        <$>
        feedBytes (Just "aaa") 
        <*> 
        feedBytes (Just "bbb") 
        <*> 
        foldOut intoLazyBytes 
        <*>
        foldErr intoLazyBytes 
        <*>
        foldErr (PT.asUtf8x PT.intoLazyText)
        <*>
        foldOutErr (PT.bothAsUtf8x (PT.combinedLines PT.intoLazyText))
        <*>
        exitCode
    :}
("aaabbb","eee\n","eee\n","aaabbb\neee\n",ExitSuccess)

-}
newtype Streams e r = 
    Streams (Day (Day (Feed1 ByteString e) 
                      (Fold2 ByteString ByteString e)) 
                 (Star (ExceptT e IO) ExitCode) 
                 r) 
    deriving (Functor)

{-| 'first' is useful to massage errors.		

-}
instance Bifunctor Streams where
    bimap f g (Streams d)  = Streams $ fmap g $
          trans1
            (  trans1 (first f)
             . trans2 (first f)
            )
        . trans2 (\(Star starfunc) -> Star (withExceptT f <$> starfunc))
        $ d


{-| 
    'pure' writes nothing to @stdin@, discards the data coming from @stdout@ and @stderr@, and ignores the exit code.

    '<*>' combines handlers by sequencing the writes to @stdin@, and making concurrent reads from @stdout@ and @stderr@.
-}
instance Applicative (Streams e) where
    pure a = Streams (pure a)

    Streams f <*> Streams x = Streams (f <*> x)

instance (S.Semigroup a) => S.Semigroup (Streams e a) where
   (<>) s1 s2 = (S.<>) <$> s1 <*> s2

#if !(MIN_VERSION_base(4,11,0))
instance (Monoid a,S.Semigroup a) => Monoid (Streams e a) where
#else
instance (Monoid a) => Monoid (Streams e a) where
#endif
   mempty = pure mempty
#if !(MIN_VERSION_base(4,11,0))
   mappend = (S.<>)
#endif

{- $ghci

Within GHCi, it's easy to use this module to launch external programs.

If the program is long-running, do it in a new thread to avoid locking GHCi,
and keep track of the thread id:

@
ghci> r <- forkIO $ execute (piped (proc "C:\/Program Files (x86)\/Vim\/vim74\/gvim.exe" [])) (pure ())
@

Kill the thread to kill the long-running process:

@
ghci> killThread r
@

-} 

 
