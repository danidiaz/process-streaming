
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- system processes.
--
-- Error conditions not directly related to IO are made explicit
-- in the types.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and various folds can
-- be used to consume the output streams of the external processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Process.Streaming ( 
        -- * Execution
          execute
        , executeFallibly
        -- * Piping Policies
        , PipingPolicy
        , nopiping
        , pipeo
        , pipee
        , pipeoe
        , pipeoec
        , pipei
        , pipeio
        , pipeie
        , pipeioe
        , pipeioec

        -- * Pumping bytes into stdin
        , Pump (..)
        , fromProducer
        , fromSafeProducer
        , fromFallibleProducer
        -- * Siphoning bytes out of stdout/stderr
        , Siphon
        , siphon
        , siphon'
        , fromFold
        , fromFold'
        , fromFold'_
        , fromConsumer
        , fromSafeConsumer
        , fromFallibleConsumer
        , fromParser
        , unwanted
        , DecodingFunction
        , encoded
        -- * Line handling
        , LinePolicy
        , linePolicy
        , tweakLines
        -- * Pipelines
        , executePipeline
        , executePipelineFallibly
        --, simplePipeline
        , Stage
        , stage
        , pipefail
        , inbound
        -- * Re-exports
        -- $reexports
        , module System.Process
    ) where

import Data.Maybe
import Data.Bifunctor
import Data.Functor.Identity
import Data.Either
import Data.Monoid
import Data.Foldable
import Data.Traversable
import Data.Tree
import Data.Text 
import Data.Text.Encoding 
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
import qualified Control.Monad.Catch as C
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
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.IO.Error
import System.Process
import System.Process.Lens
import System.Exit

execute :: PipingPolicy Void a -> CreateProcess -> IO (ExitCode,a)
execute pp cprocess = either absurd id <$> executeFallibly pp cprocess

{-|
   Executes an external process. The standard streams are piped and consumed in
a way defined by the 'PipingPolicy' argument. 

   This function re-throws any 'IOException's it encounters.

   If the consumption of the standard streams fails with @e@, the whole
computation is immediately aborted and @e@ is returned. (An exception is not
thrown in this case.).  

   If an error @e@ or an exception happens, the external process is
terminated.
 -}
executeFallibly :: PipingPolicy e a -> CreateProcess -> IO (Either e (ExitCode,a))
executeFallibly pp record = case pp of
      PPNone a -> executeInternal record nohandles $  
          \() -> (return . Right $ a,return ())
      PPOutput action -> executeInternal (record{std_out = CreatePipe}) handleso $
          \h->(action (fromHandle h),hClose h) 
      PPError action ->  executeInternal (record{std_err = CreatePipe}) handlese $
          \h->(action (fromHandle h),hClose h)
      PPOutputError action -> executeInternal (record{std_out = CreatePipe, std_err = CreatePipe}) handlesoe $
          \(hout,herr)->(action (fromHandle hout,fromHandle herr),hClose hout `finally` hClose herr)
      PPInput action -> executeInternal (record{std_in = CreatePipe}) handlesi $
          \h -> (action (toHandle h, hClose h), return ())
      PPInputOutput action -> executeInternal (record{std_in = CreatePipe,std_out = CreatePipe}) handlesio $
          \(hin,hout) -> (action (toHandle hin,hClose hin,fromHandle hout), hClose hout)
      PPInputError action -> executeInternal (record{std_in = CreatePipe,std_err = CreatePipe}) handlesie $
          \(hin,herr) -> (action (toHandle hin,hClose hin,fromHandle herr), hClose herr)
      PPInputOutputError action -> executeInternal (record{std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}) handlesioe $
          \(hin,hout,herr) -> (action (toHandle hin,hClose hin,fromHandle hout,fromHandle herr), hClose hout `finally` hClose herr)

executeInternal :: CreateProcess -> (forall m. Applicative m => (t -> m t) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)) -> (t ->(IO (Either e a),IO ())) -> IO (Either e (ExitCode,a))
executeInternal record somePrism allocator = mask $ \restore -> do
    (min,mout,merr,phandle) <- createProcess record
    case getFirst . getConst . somePrism (Const . First . Just) $ (min,mout,merr) of
        Nothing -> 
            throwIO (userError "stdin/stdout/stderr handle unwantedly null")
            `finally`
            terminateCarefully phandle 
        Just t -> 
            let (action,cleanup) = allocator t in
            -- Handles must be closed *after* terminating the process, because a close
            -- operation may block if the external process has unflushed bytes in the stream.
            (restore (terminateOnError phandle action) `onException` terminateCarefully phandle) `finally` cleanup 

exitCode :: (ExitCode,a) -> Either Int a
exitCode (ec,a) = case ec of
    ExitSuccess -> Right a 
    ExitFailure i -> Left i

terminateCarefully :: ProcessHandle -> IO ()
terminateCarefully pHandle = do
    mExitCode <- getProcessExitCode pHandle   
    case mExitCode of 
        Nothing -> terminateProcess pHandle  
        Just _ -> return ()

terminateOnError :: ProcessHandle 
                 -> IO (Either e a)
                 -> IO (Either e (ExitCode,a))
terminateOnError pHandle action = do
    result <- action
    case result of
        Left e -> do    
            terminateCarefully pHandle
            return $ Left e
        Right r -> do 
            exitCode <- waitForProcess pHandle 
            return $ Right (exitCode,r)  

{-|
    A 'PipingPolicy' determines what standard streams will be piped and what to
do with them.

    The user doesn't need to manually set the 'std_in', 'std_out' and 'std_err'
fields of the 'CreateProcess' record to 'CreatePipe', this is done
automatically. 

    A 'PipingPolicy' is parametrized by the type @e@ of errors that can abort
the processing of the streams.
 -}
-- Knows that there is a stdin, stdout and a stderr,
-- but doesn't know anything about file handlers or CreateProcess.
data PipingPolicy e a = 
      PPNone a
    | PPOutput (Producer ByteString IO () -> IO (Either e a))
    | PPError (Producer ByteString IO () -> IO (Either e a))
    | PPOutputError ((Producer ByteString IO (),Producer ByteString IO ()) -> IO (Either e a))
    | PPInput ((Consumer ByteString IO (), IO ()) -> IO (Either e a))
    | PPInputOutput ((Consumer ByteString IO (), IO (),Producer ByteString IO ()) -> IO (Either e a))
    | PPInputError ((Consumer ByteString IO (), IO (), Producer ByteString IO ()) -> IO (Either e a))
    | PPInputOutputError ((Consumer ByteString IO (),IO (),Producer ByteString IO (),Producer ByteString IO ()) -> IO (Either e a))
    deriving (Functor)

instance Bifunctor PipingPolicy where
  bimap f g pp = case pp of
        PPNone a -> PPNone $ g a 
        PPOutput action -> PPOutput $ fmap (fmap (bimap f g)) action
        PPError action -> PPError $ fmap (fmap (bimap f g)) action
        PPOutputError action -> PPOutputError $ fmap (fmap (bimap f g)) action
        PPInput action -> PPInput $ fmap (fmap (bimap f g)) action
        PPInputOutput action -> PPInputOutput $ fmap (fmap (bimap f g)) action
        PPInputError action -> PPInputError $ fmap (fmap (bimap f g)) action
        PPInputOutputError action -> PPInputOutputError $ fmap (fmap (bimap f g)) action

{-|
    Do not pipe any standard stream. 
-}
nopiping :: PipingPolicy e ()
nopiping = PPNone ()

{-|
    Pipe @stdout@.
-}
pipeo :: Siphon ByteString e a -> PipingPolicy e a
pipeo (runSiphon -> siphonout) = PPOutput $ siphonout

{-|
    Pipe @stderr@.
-}
pipee :: Siphon ByteString e a -> PipingPolicy e a
pipee (runSiphon -> siphonout) = PPError $ siphonout

{-|
    Pipe @stdout@ and @stderr@.
-}
pipeoe :: Siphon ByteString e a -> Siphon ByteString e b -> PipingPolicy e (a,b)
pipeoe (runSiphon -> siphonout) (runSiphon -> siphonerr) = 
    PPOutputError $ uncurry $ separated siphonout siphonerr  

{-|
    Pipe @stdout@ and @stderr@ and consume them combined as 'Text'.  
-}
pipeoec :: LinePolicy e -> LinePolicy e -> Siphon Text e a -> PipingPolicy e a
pipeoec policy1 policy2 (runSiphon -> siphon) = 
    PPOutputError $ uncurry $ combined policy1 policy2 siphon  

{-|
    Pipe @stdin@.
-}
pipei :: Pump ByteString e i -> PipingPolicy e i
pipei (Pump feeder) = PPInput $ \(consumer,cleanup) -> feeder consumer `finally` cleanup

{-|
    Pipe @stdin@ and @stdout@.
-}
pipeio :: Pump ByteString e i -> Siphon ByteString e a -> PipingPolicy e (i,a)
pipeio (Pump feeder) (runSiphon -> siphonout) = PPInputOutput $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonout producer))

{-|
    Pipe @stdin@ and @stderr@.
-}
pipeie :: Pump ByteString e i -> Siphon ByteString e a -> PipingPolicy e (i,a)
pipeie (Pump feeder) (runSiphon -> siphonerr) = PPInputError $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonerr producer))

{-|
    Pipe @stdin@, @stdout@ and @stderr@.
-}
pipeioe :: Pump ByteString e i -> Siphon ByteString e a -> Siphon ByteString e b -> PipingPolicy e (i,a,b)
pipeioe (Pump feeder) (runSiphon -> siphonout) (runSiphon -> siphonerr) = fmap flattenTuple $ PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (separated siphonout siphonerr outprod errprod))
    where
        flattenTuple (i, (a, b)) = (i,a,b)

{-|
    Pipe @stdin@, @stdout@ and @stderr@, consuming the last two combined as 'Text'.
-}
pipeioec :: Pump ByteString e i -> LinePolicy e -> LinePolicy e -> Siphon Text e a -> PipingPolicy e (i,a)
pipeioec (Pump feeder) policy1 policy2 (runSiphon -> siphon) = PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (combined policy1 policy2 siphon outprod errprod))

separated :: (Producer ByteString IO () -> IO (Either e a))
          -> (Producer ByteString IO () -> IO (Either e b))
          ->  Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separated outfunc errfunc outprod errprod = 
    conceit (outfunc outprod) (errfunc errprod)

{-|
    A configuration parameter used in functions that combine lines from
    multiple streams.
 -}

data LinePolicy e = LinePolicy 
    {
        teardown :: (forall r. Producer T.Text IO r -> Producer T.Text IO r)
                 -> (FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) 
                 -> Producer ByteString IO () -> IO (Either e ())
    ,   lineTweaker :: forall r. Producer T.Text IO r -> Producer T.Text IO r
    } 

instance Functor LinePolicy where
  fmap f (LinePolicy func lt) = LinePolicy (\x y z -> fmap (bimap f id) $ func x y z) lt


{-|
    Specifies a transformation that will be applied to each line of text,
    represented as a 'Producer'.

    Line prefixes are easy to add using applicative notation:

  > (\x -> yield "prefix: " *> x)
-}
tweakLines :: (forall r. Producer T.Text IO r -> Producer T.Text IO r) -> LinePolicy e -> LinePolicy e 
tweakLines lt' (LinePolicy tear lt) = LinePolicy tear (lt' . lt) 

{-|
    Constructs a 'LinePolicy' out of a 'DecodingFunction' and a 'Siphon'
    that specifies how to handle decoding failures. Passing @pure ()@ as
    the 'Siphon' will ignore any leftovers. Passing @unwanted ()@ will
    abort the computation if leftovers remain.
 -}
linePolicy :: DecodingFunction ByteString Text 
           -> Siphon ByteString e ()
           -> LinePolicy e 
linePolicy decoder lopo = LinePolicy
    (\tweaker teardown producer -> do
        let freeLines = transFreeT tweaker 
                      . viewLines 
                      . decoder
                      $ producer
            viewLines = getConst . T.lines Const
        teardown freeLines >>= runSiphon lopo)
    id 

-- http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here
combined :: LinePolicy e 
         -> LinePolicy e 
         -> (Producer T.Text IO () -> IO (Either e a))
         -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a)
combined (LinePolicy fun1 twk1) (LinePolicy fun2 twk2) combinedConsumer prod1 prod2 = 
    manyCombined [fmap ($prod1) (fun1 twk1), fmap ($prod2) (fun2 twk2)] combinedConsumer 
  where     
    manyCombined :: [(FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> IO (Either e ())]
                 -> (Producer T.Text IO () -> IO (Either e a))
                 -> IO (Either e a) 
    manyCombined actions consumer = do
        (outbox, inbox, seal) <- spawn' Single
        mVar <- newMVar outbox
        runConceit $ 
            Conceit (mapConceit ($ iterTLines mVar) actions `finally` atomically seal)
            *>
            Conceit (consumer (fromInput inbox) `finally` atomically seal)
        where 
        iterTLines mvar = iterT $ \textProducer -> do
            -- the P.drain bit was difficult to figure out!!!
            join $ withMVar mvar $ \output -> do
                runEffect $ (textProducer <* P.yield (singleton '\n')) >-> (toOutput output >> P.drain)

fromProducer :: Producer b IO r -> Pump b e ()
fromProducer producer = Pump $ \consumer -> fmap pure $ runEffect (mute producer >-> consumer) 

fromSafeProducer :: Producer b (SafeT IO) r -> Pump b e ()
fromSafeProducer producer = Pump $ safely $ \consumer -> fmap pure $ runEffect (mute producer >-> consumer) 

fromFallibleProducer :: Producer b (ExceptT e IO) r -> Pump b e ()
fromFallibleProducer producer = Pump $ \consumer -> runExceptT $ runEffect (mute producer >-> hoist lift consumer) 

{-| 
  Useful when we want to plug in a handler that does its work in the 'SafeT'
transformer.
 -}
safely :: (MFunctor t, C.MonadMask m, MonadIO m) 
       => (t (SafeT m) l -> (SafeT m) x) 
       ->  t m         l -> m         x 
safely activity = runSafeT . activity . hoist lift 

{-|
    See the section /Non-lens decoding functions/ in the documentation for the
@pipes-text@ package.  
-}
type DecodingFunction bytes text = forall r. Producer bytes IO r -> Producer text IO (Producer bytes IO r)

{-|
    Constructs a 'Siphon' that works on encoded values out of a 'Siphon' that
works on decoded values. 
   
    The two first arguments are a decoding function and a 'Siphon' that
determines how to handle leftovers. Pass @pure id@ to ignore leftovers. Pass
@unwanted id@ to abort the computation if leftovers remain.
 -}
encoded :: DecodingFunction bytes text
        -> Siphon bytes e (a -> b)
        -> Siphon text  e a 
        -> Siphon bytes e b
encoded decoder (Siphon policy) (Siphon activity) = 
    Siphon (Other (encodedI decoder (unLift policy) (unLift activity)))

encodedI :: DecodingFunction bytes text
         -> SiphonI bytes e (a -> b)
         -> SiphonI text  e a 
         -> SiphonI bytes e b
encodedI decoder policy activity = 
    Exhaustive $ \producer ->
        runExceptT $ do
            (a,leftovers) <- ExceptT $ exhaustive activity $ decoder producer 
            (f,r) <- ExceptT $ exhaustive policy leftovers 
            pure (f a,r)

newtype Pump b e a = Pump { runPump :: Consumer b IO () -> IO (Either e a) } deriving Functor

instance Bifunctor (Pump b) where
  bimap f g (Pump x) = Pump $ fmap (liftM  (bimap f g)) x

instance Applicative (Pump b e) where
  pure = Pump . pure . pure . pure
  Pump fs <*> Pump as = 
      Pump $ \consumer -> do
          (outbox1,inbox1,seal1) <- spawn' Single
          (outbox2,inbox2,seal2) <- spawn' Single
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

instance (Monoid a) => Monoid (Pump b e a) where
   mempty = Pump . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

{-| 
    A 'Siphon' represents a computation that completely drains a producer, but
may fail early with an error of type @e@. 

    'pure' creates a 'Siphon' that does nothing besides draining the
'Producer'. 

    '<*>' executes its arguments concurrently. The 'Producer' is forked so
    that each argument receives its own copy of the data.
 -}
newtype Siphon b e a = Siphon (Lift (SiphonI b e) a) deriving (Functor,Applicative)

data SiphonI b e a = 
         Exhaustive (forall r. Producer b IO r -> IO (Either e (a,r)))
       | Nonexhaustive (Producer b IO () -> IO (Either e a))
       deriving (Functor)

instance Applicative (SiphonI b e) where
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
                Conceit ((fmap pure $ runEffect $ 
                              producer >-> P.tee (toOutput outbox1 >> P.drain) 
                                       >->       (toOutput outbox2 >> P.drain))   
                         `finally` atomically seal1 `finally` atomically seal2
                        ) 

nonexhaustive :: SiphonI b e a -> Producer b IO () -> IO (Either e a)
nonexhaustive (Exhaustive e) = \producer -> liftM (fmap fst) (e producer)
nonexhaustive (Nonexhaustive u) = u

exhaustive :: SiphonI b e a -> Producer b IO r -> IO (Either e (a,r))
exhaustive s = case s of 
    Exhaustive e -> e
    Nonexhaustive activity -> \producer -> do 
        (outbox,inbox,seal) <- spawn' Single
        runConceit $ 
            (,) 
            <$>
            Conceit (activity (fromInput inbox) `finally` atomically seal)
            <*>
            Conceit ((fmap pure $ runEffect $ 
                            producer >-> (toOutput outbox >> P.drain))
                     `finally` atomically seal
                    )

runSiphonI :: SiphonI b e a -> Producer b IO () -> IO (Either e a)
runSiphonI s = nonexhaustive $ case s of 
    Exhaustive _ -> s
    Nonexhaustive _ -> Exhaustive (exhaustive s)

runSiphon :: Siphon b e a -> Producer b IO () -> IO (Either e a)
runSiphon (Siphon l) = runSiphonI (unLift l)

instance Bifunctor (SiphonI b) where
  bimap f g s = case s of
      Exhaustive u -> Exhaustive $ fmap (liftM  (bimap f (bimap g id))) u
      Nonexhaustive h -> Nonexhaustive $ fmap (liftM  (bimap f g)) h

instance Bifunctor (Siphon b) where
  bimap f g (Siphon s) = Siphon $ case s of
      Pure a -> Pure (g a)
      Other o -> Other (bimap f g o)

instance (Monoid a) => Monoid (Siphon b e a) where
   mempty = pure mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

fromConsumer :: Consumer b IO r -> Siphon b e ()
fromConsumer consumer = siphon $ \producer -> fmap pure $ runEffect $ producer >-> mute consumer 

fromSafeConsumer :: Consumer b (SafeT IO) r -> Siphon b e ()
fromSafeConsumer consumer = siphon $ safely $ \producer -> fmap pure $ runEffect $ producer >-> mute consumer 

fromFallibleConsumer :: Consumer b (ExceptT e IO) r -> Siphon b e ()
fromFallibleConsumer consumer = siphon $ \producer -> runExceptT $ runEffect (hoist lift producer >-> mute consumer) 

{-| 
  Turn a 'Parser' from @pipes-parse@ into a 'Sihpon'.
 -}
fromParser :: Parser b IO (Either e a) -> Siphon b e a 
fromParser parser = siphon $ Pipes.Parse.evalStateT parser 

{-| 
   Builds a 'Siphon' out of a computation that does something with
   a 'Producer', but may fail with an error of type @e@.
   
   Even if the original computation doesn't completely drain the 'Producer',
   the constructed 'Siphon' will.
-}
siphon :: (Producer b IO () -> IO (Either e a))
       -> Siphon b e a 
siphon = Siphon . Other . Nonexhaustive


{-| 
   Builds a 'Siphon' out of a computation that drains a 'Producer' completely,
but may fail with an error of type @e@.
-}
siphon' :: (forall r. Producer b IO r -> IO (Either e (a,r))) -> Siphon b e a 
siphon' f = Siphon (Other (Exhaustive f))

{-| 
    Useful in combination with 'Pipes.Text.toLazyM' from @pipes-text@ and
    'Pipes.ByteString.toLazyM' from @pipes-bytestring@, when the user
    wants to collect all the output. 
-}
fromFold :: (Producer b IO () -> IO a) -> Siphon b e a 
fromFold aFold = siphon $ fmap (fmap pure) $ aFold 

{-| 
   Builds a 'Siphon' out of a computation that folds a 'Producer' and drains it completely.
-}
fromFold' :: (forall r. Producer b IO r -> IO (a,r)) -> Siphon b e a 
fromFold' aFold = siphon' $ fmap (fmap pure) aFold

fromFold'_ :: (forall r. Producer b IO r -> IO r) -> Siphon b e () 
fromFold'_ aFold = fromFold' $ fmap (fmap ((,) ())) aFold

{-|
  Constructs a 'Siphon' that aborts the computation if the underlying
'Producer' produces anything.
 -}
unwanted :: a -> Siphon b b a
unwanted a = siphon' $ \producer -> do
    n <- next producer  
    return $ case n of 
        Left r -> Right (a,r)
        Right (b,_) -> Left b

executePipeline :: PipingPolicy Void a -> Tree (Stage Void) -> IO a 
executePipeline pp pipeline = either absurd id <$> executePipelineFallibly pp pipeline


{-|
    Similar to 'executeFallibly', but instead of a single process it
    executes a (possibly branching) pipeline of external processes. 

    The 'PipingPolicy' argument views the pipeline as a synthetic process
    for which @stdin@ is the @stdin@ of the first stage, @stdout@ is the
    @stdout@ of the leftmost terminal stage among those closer to the root,
    and @stderr@ is a combination of the @stderr@ streams of all the
    stages.

    The combined @stderr@ stream always has UTF-8 encoding.

    This function has a limitation compared to the standard UNIX pipelines.
    If a downstream process terminates early without error, the upstream
    processes are not notified and keep going. There is no SIGPIPE-like
    functionality, in other words. 
 -}
executePipelineFallibly :: PipingPolicy e a -> Tree (Stage e) -> IO (Either e a)
executePipelineFallibly policy (Node (Stage cp lpol ecpol _) []) = case policy of
          PPNone a -> blende ecpol <$> executeFallibly policy cp 
          PPOutput action -> blende ecpol <$> executeFallibly policy cp 
          PPError action -> do
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action $ fromInput einbox)
                    <*
                    (Conceit $ blende ecpol <$> executeFallibly (pipee (errf lpol)) cp `finally` atomically eseal)
          PPOutputError action -> do 
                (outbox, inbox, seal) <- spawn' Single
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action $ (fromInput inbox,fromInput einbox))
                    <* 
                    (Conceit $ blende ecpol <$> executeFallibly
                                    (pipeoe (fromConsumer.toOutput $ outbox) (errf lpol)) cp
                               `finally` atomically seal `finally` atomically eseal
                    )
          PPInput action -> blende ecpol <$> executeFallibly policy cp
          PPInputOutput action -> blende ecpol <$> executeFallibly policy cp
          PPInputError action -> do
                (outbox, inbox, seal) <- spawn' Single
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action (toOutput outbox,atomically seal,fromInput einbox))
                    <* 
                    (Conceit $ blende ecpol <$> executeFallibly
                                    (pipeie (fromProducer . fromInput $ inbox) (errf lpol)) cp
                               `finally` atomically seal `finally` atomically eseal
                    )
          PPInputOutputError action -> do
                (ioutbox, iinbox, iseal) <- spawn' Single
                (ooutbox, oinbox, oseal) <- spawn' Single
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action (toOutput ioutbox,atomically iseal,fromInput oinbox,fromInput einbox))
                    <* 
                    (Conceit $ blende ecpol <$> executeFallibly
                                    (pipeioe (fromProducer . fromInput $ iinbox) 
                                            (fromConsumer . toOutput $ ooutbox) 
                                            (errf lpol) 
                                    )
                                    cp
                               `finally` atomically iseal `finally` atomically oseal `finally` atomically eseal
                    )
executePipelineFallibly policy (Node s (s':ss)) = 
      let pipeline = CreatePipeline s $ s' :| ss 
      in case policy of 
          PPNone a -> fmap (fmap (const a)) $
               executePipelineInternal 
                    (\o _ -> mute $ pipeo o) 
                    (\i o _ -> mute $ pipeio i o) 
                    (\i _ -> mute $ pipei i) 
                    (\i _ -> mute $ pipei i) 
                    pipeline
          PPOutput action -> do
                (outbox, inbox, seal) <- spawn' Single
                runConceit $  
                    (Conceit $ action $ fromInput inbox)
                    <* 
                    (Conceit $ executePipelineInternal 
                                    (\o _ -> pipeo o)
                                    (\i o _ -> mute $ pipeio i o) 
                                    (\i _ -> mute $ pipeio i (fromConsumer . toOutput $ outbox)) 
                                    (\i _ -> mute $ pipei i)
                                    pipeline
                               `finally` atomically seal
                    ) 
          PPError action -> do
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action $ fromInput einbox)
                    <*
                    (Conceit $ executePipelineInternal 
                                (\o l -> mute $ pipeoe o (errf l)) 
                                (\i o l -> mute $ pipeioe i o (errf l)) 
                                (\i l -> mute $ pipeie i (errf l)) 
                                (\i l -> mute $ pipeie i (errf l))
                                pipeline
                                `finally` atomically eseal)
          PPOutputError action -> do
                (outbox, inbox, seal) <- spawn' Single
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action $ (fromInput inbox,fromInput einbox))
                    <* 
                    (Conceit $ executePipelineInternal 
                                    (\o l -> mute $ pipeoe o (errf l))
                                    (\i o l -> mute $ pipeioe i o (errf l)) 
                                    (\i l -> mute $ pipeioe i (fromConsumer . toOutput $ outbox) (errf l)) 
                                    (\i l -> mute $ pipeie i (errf l))
                                    pipeline
                               `finally` atomically seal `finally` atomically eseal
                    )
          PPInput action -> do
                (outbox, inbox, seal) <- spawn' Single
                runConceit $  
                    (Conceit $ action (toOutput outbox,atomically seal))
                    <* 
                    (Conceit $ executePipelineInternal 
                                    (\o _ -> mute $ pipeio (fromProducer . fromInput $ inbox) o)
                                    (\i o _ -> mute $ pipeio i o) 
                                    (\i _ -> mute $ pipei i) 
                                    (\i _ -> mute $ pipei i) 
                                    pipeline
                               `finally` atomically seal
                    )
          PPInputOutput action -> do
                (ioutbox, iinbox, iseal) <- spawn' Single
                (ooutbox, oinbox, oseal) <- spawn' Single
                runConceit $  
                    (Conceit $ action (toOutput ioutbox,atomically iseal,fromInput oinbox))
                    <* 
                    (Conceit $ executePipelineInternal 
                                    (\o _ -> mute $ pipeio (fromProducer . fromInput $ iinbox) o)
                                    (\i o _ -> mute $ pipeio i o) 
                                    (\i _ -> mute $ pipeio i (fromConsumer . toOutput $ ooutbox)) 
                                    (\i _ -> mute $ pipei i) 
                                    pipeline
                               `finally` atomically iseal `finally` atomically oseal
                    )
          PPInputError action -> do
                (outbox, inbox, seal) <- spawn' Single
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action (toOutput outbox,atomically seal,fromInput einbox))
                    <* 
                    (Conceit $ executePipelineInternal 
                                    (\o l -> mute $ pipeioe (fromProducer . fromInput $ inbox) o (errf l))
                                    (\i o l -> mute $ pipeioe i o (errf l)) 
                                    (\i l -> mute $ pipeie i (errf l)) 
                                    (\i l -> mute $ pipeie i (errf l)) 
                                    pipeline
                               `finally` atomically seal `finally` atomically eseal
                    )
          PPInputOutputError action -> do
                (ioutbox, iinbox, iseal) <- spawn' Single
                (ooutbox, oinbox, oseal) <- spawn' Single
                (eoutbox, einbox, eseal) <- spawn' Single
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action (toOutput ioutbox,atomically iseal,fromInput oinbox,fromInput einbox))
                    <* 
                    (Conceit $ executePipelineInternal 
                                    (\o l -> mute $ pipeioe (fromProducer . fromInput $ iinbox) o (errf l))
                                    (\i o l -> mute $ pipeioe i o (errf l)) 
                                    (\i l -> mute $ pipeioe i (fromConsumer . toOutput $ ooutbox) (errf l)) 
                                    (\i l -> mute $ pipeie i (errf l))  
                                    pipeline
                               `finally` atomically iseal `finally` atomically oseal `finally` atomically eseal
                    )

errorSiphonUTF8 :: MVar (Output ByteString) -> LinePolicy e -> Siphon ByteString e ()
errorSiphonUTF8 mvar (LinePolicy fun twk) = siphon (fun twk iterTLines)
  where     
    iterTLines = iterT $ \textProducer -> do
        -- the P.drain bit was difficult to figure out!!!
        join $ withMVar mvar $ \output -> do
            runEffect $     (textProducer <* P.yield (singleton '\n')) 
                        >->  P.map Data.Text.Encoding.encodeUtf8 
                        >-> (toOutput output >> P.drain)

mute :: Functor f => f a -> f ()
mute = fmap (const ())

{-|
   An individual stage in a process pipeline. 
 -}
data Stage e = Stage 
           {
             processDefinition' :: CreateProcess 
           , stderrLinePolicy' :: LinePolicy e
           , exitCodePolicy' :: ExitCode -> Either e ()
           , inbound' :: forall r. Producer ByteString IO r -> Producer ByteString (ExceptT e IO) r 
           } 

instance Functor (Stage) where
    fmap f (Stage a b c d) = Stage a (fmap f b) (bimap f id . c) (hoist (mapExceptT $ liftM (bimap f id)) . d)

{-|
    Builds a 'Stage' out of a 'LinePolicy' that specifies how to handle
    @stderr@ when piped, a function that determines whether an
    'ExitCode' represents an error (some programs return non-standard exit
    codes) and a process definition. 
-}
stage :: LinePolicy e -> (ExitCode -> Either e ()) -> CreateProcess -> Stage e       
stage lp ec cp = Stage cp lp ec (hoist lift) 

{-|
   Applies a transformation to the stream of bytes flowing into a stage from previous stages.

   This function is ignored for first stages.
-}
inbound :: (forall r. Producer ByteString (ExceptT e IO) r -> Producer ByteString (ExceptT e IO) r)
        -> Stage e -> Stage e 
inbound f (Stage a b c d) = Stage a b c (f . d)

data CreatePipeline e =  CreatePipeline (Stage e) (NonEmpty (Tree (Stage e))) deriving (Functor)

executePipelineInternal :: (Siphon ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> (Pump ByteString e () -> Siphon ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> (Pump ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> (Pump ByteString e () -> LinePolicy e -> PipingPolicy e ())
                        -> CreatePipeline e 
                        -> IO (Either e ())
executePipelineInternal ppinitial ppmiddle ppend ppend' (CreatePipeline (Stage cp lpol ecpol _) a) =      
    blende ecpol <$> executeFallibly (ppinitial (runNonEmpty ppend ppend' a) lpol) cp
  where 
    runTree ppend ppend' (Node (Stage cp lpol ecpol pipe) forest) = case forest of
        [] -> siphon $ \producer ->
            blende ecpol <$> executeFallibly (ppend (fromFallibleProducer $ pipe producer) lpol) cp
        c1 : cs -> siphon $ \producer ->
           blende ecpol <$> executeFallibly (ppmiddle (fromFallibleProducer $ pipe producer) (runNonEmpty ppend ppend' (c1 :| cs)) lpol) cp

    runNonEmpty ppend ppend' (b :| bs) = 
        runTree ppend ppend' b <* Prelude.foldr (<*) (pure ()) (runTree ppend' ppend' <$> bs) 
    
blende :: (ExitCode -> Either e ()) -> Either e (ExitCode,a) -> Either e a
blende f r = r >>= \(ec,a) -> f ec *> pure a

{-|
  Converts any 'ExitFailure' to the left side of an 'Either'. 
-}
pipefail :: ExitCode -> Either Int ()
pipefail ec = case ec of
    ExitSuccess -> Right ()
    ExitFailure i -> Left i

{- $reexports
 
"System.Process" is re-exported for convenience.

-} 

