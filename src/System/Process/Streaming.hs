
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide concurrent, buffered (to avoid deadlocks) streaming access to
-- the inputs and outputs of system processes.
--
-- There's also an emphasis in having error conditions explicit in the types,
-- instead of throwing exceptions.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and folds from
-- "Pipes.Prelude" (also folds from @pipes-bytestring@ and @pipes-text@) can be
-- used to consume the output streams of the external processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

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
        , useProducer
        , useSafeProducer
        , useFallibleProducer
        -- * Siphoning bytes out of stdout/stderr
        , Siphon (..)
        , useConsumer
        , useSafeConsumer
        , useFallibleConsumer
        , useFold
        , useParser
        , unexpected
        , encoded
        -- * Line handling
        , DecodingFunction
        , LinePolicy
        , linePolicy
        -- * Pipelines
        , executePipeline
        , executePipelineFallibly
        , Pipeline (..)
        , Stage (..)
        , SubsequentStage (..)
        , BetweenStages (..)
        , RootedArborescent (..)
        , Arborescent (..)
        , fromPipeline 
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
import Data.Typeable
import Data.Text 
import Data.Void
import Data.List.NonEmpty
import qualified Data.List.NonEmpty as N
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Writer.Strict
import qualified Control.Monad.Catch as C
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
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

   This fuction re-throws any 'IOException's it encounters.

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
            throwIO (userError "stdin/stdout/stderr handle unexpectedly null")
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

-- Knows that there is a stdin, stdout and stderr,
-- But doesn't know anything about file handles of CreateProcess
data PipingPolicy e a = 
      PPNone a
    | PPOutput (Producer ByteString IO () -> IO (Either e a))
    | PPError  (Producer ByteString IO () -> IO (Either e a))
    | PPOutputError ((Producer ByteString IO (),Producer ByteString IO ()) -> IO (Either e a))
    | PPInput ((Consumer ByteString IO (), IO ()) -> IO (Either e a))
    | PPInputOutput ((Consumer ByteString IO (), IO (),Producer ByteString IO ()) -> IO (Either e a))
    | PPInputError  ((Consumer ByteString IO (), IO (), Producer ByteString IO ()) -> IO (Either e a))
    | PPInputOutputError  ((Consumer ByteString IO (),IO (),Producer ByteString IO (),Producer ByteString IO ()) -> IO (Either e a))
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

pipeo :: (Show e,Typeable e) => Siphon ByteString e a -> PipingPolicy e a
pipeo (Siphon siphonout) = PPOutput $ siphonout

pipee :: (Show e,Typeable e) => Siphon ByteString e a -> PipingPolicy e a
pipee (Siphon siphonout) = PPError $ siphonout

{-|
    Pipe stderr and stdout.

    See also the 'separated' and 'combined' functions.
-}
pipeoe :: (Show e,Typeable e) => Siphon ByteString e a -> Siphon ByteString e b -> PipingPolicy e (a,b)
pipeoe (Siphon siphonout) (Siphon siphonerr) = 
    PPOutputError $ uncurry $ separated siphonout siphonerr  

pipeoec :: (Show e,Typeable e) => LinePolicy e -> LinePolicy e -> Siphon Text e a -> PipingPolicy e a
pipeoec policy1 policy2 (Siphon siphon) = 
    PPOutputError $ uncurry $ combined policy1 policy2 siphon  

pipei :: (Show e, Typeable e) => Pump ByteString e i -> PipingPolicy e i
pipei (Pump feeder) = PPInput $ \(consumer,cleanup) -> feeder consumer `finally` cleanup

pipeio :: (Show e, Typeable e)
        => Pump ByteString e i -> Siphon ByteString e a -> PipingPolicy e (i,a)
pipeio (Pump feeder) (Siphon siphonout) = PPInputOutput $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonout producer))

pipeie :: (Show e, Typeable e)
        => Pump ByteString e i -> Siphon ByteString e a -> PipingPolicy e (i,a)
pipeie (Pump feeder) (Siphon siphonerr) = PPInputError $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonerr producer))

{-|
    Pipe stdin, stderr and stdout.

    See also the 'separated' and 'combined' functions.
-}
pipeioe :: (Show e, Typeable e)
        => Pump ByteString e i -> Siphon ByteString e a -> Siphon ByteString e b -> PipingPolicy e (i,a,b)
pipeioe (Pump feeder) (Siphon siphonout) (Siphon siphonerr) = fmap flattenTuple $ PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (separated siphonout siphonerr outprod errprod))
    where
        flattenTuple (i, (a, b)) = (i,a,b)

pipeioec :: (Show e, Typeable e)
        => Pump ByteString e i -> LinePolicy e -> LinePolicy e -> Siphon Text e a -> PipingPolicy e (i,a)
pipeioec (Pump feeder) policy1 policy2 (Siphon siphon) = PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (combined policy1 policy2 siphon outprod errprod))

{-|
    'separate' should be used when we want to consume @stdout@ and @stderr@
concurrently and independently. It constructs a function that can be plugged
into functions like 'pipeoe'. 

    If the consuming functions return with @a@ and @b@, the corresponding
streams keep being drained until the end. The combined value is not returned
until both @stdout@ and @stderr@ are closed by the external process.

   However, if any of the consuming functions fails with @e@, the whole
computation fails immediately with @e@.
  -}
separated :: (Show e, Typeable e)
          => (Producer ByteString IO () -> IO (Either e a))
          -> (Producer ByteString IO () -> IO (Either e b))
          ->  Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separated outfunc errfunc outprod errprod = 
    conceit (buffer_ outfunc outprod) (buffer_ errfunc errprod)

{-|
   Defines how to decode a stream of bytes into text, manipulate each line of text, and handle leftovers.  
 -}
data LinePolicy e = LinePolicy ((FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> Producer ByteString IO () -> IO (Either e ()))

instance Functor LinePolicy where
  fmap f (LinePolicy func) = LinePolicy $ fmap (fmap (fmap (bimap f id))) func

{-|
    Constructs a 'LinePolicy'.

    The first argument is a function function that decodes 'ByteString' into
'T.Text'. See the section /Decoding Functions/ in the documentation for the
"Pipes.Text" module.  

    The second argument is a function that modifies each individual line. The
line is represented as a 'Producer' to avoid having to keep it wholly in
memory. If you want the lines unmodified, just pass @id@. Line prefixes are
easy to add using applicative notation:

  > (\x -> yield "prefix: " *> x)

    The third argument is a 'LeftoverPolicy' value that specifies how to handle
decoding failures. 
 -}

--linePolicy :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
linePolicy :: DecodingFunction ByteString Text 
           ->  Siphon ByteString e ()
           -> (forall r. Producer T.Text IO r -> Producer T.Text IO r)
           ->  LinePolicy e 
linePolicy decoder lopo transform = LinePolicy $ \teardown producer -> do
    let freeLines = transFreeT transform 
                  . viewLines 
                  . decoder
                  $ producer
        viewLines = getConst . T.lines Const
    teardown freeLines >>= runSiphon lopo

{-|
    The bytes from @stdout@ and @stderr@ are decoded into 'Text', splitted into
lines (maybe applying some transformation to each line) and then combined and
consumed by the function passed as argument.

    For both @stdout@ and @stderr@, a 'LinePolicy' must be supplied.

    Like with 'separated', the streams are drained to completion if no errors
happen, but the computation is aborted immediately if any error @e@ is
returned. 

    'combined' returns a function that can be plugged into funtions like 'pipeioe'.

    /Beware!/ 'combined' avoids situations in which a line emitted
in @stderr@ cuts a long line emitted in @stdout@, see
<http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here> for a description of the problem.  To avoid this, the combined text
stream is locked while writing each individual line. But this means that if the
external program stops writing to a handle /while in the middle of a line/,
lines coming from the other handles won't get printed, either!
 -}
combined :: (Show e, Typeable e) 
         => LinePolicy e 
         -> LinePolicy e 
         -> (Producer T.Text IO () -> IO (Either e a))
         -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a)
combined (LinePolicy fun1) (LinePolicy fun2) combinedConsumer prod1 prod2 = 
    manyCombined [fmap (($prod1).buffer_) fun1, fmap (($prod2).buffer_) fun2] combinedConsumer 
    
manyCombined :: (Show e, Typeable e) 
             => [(FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> IO (Either e ())]
        	 -> (Producer T.Text IO () -> IO (Either e a))
        	 -> IO (Either e a) 
manyCombined actions consumer = do
    (outbox, inbox, seal) <- spawn' Unbounded
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

{-|
    Useful for constructing @stdout@ or @stderr@ consuming functions from a
'Consumer', to be plugged into 'separated' or 'combined'.

    You may need to use 'surely' for the types to fit.
 -}
useConsumer :: Consumer b IO () -> Siphon b e ()
useConsumer consumer = Siphon $ \producer -> fmap pure $ runEffect $ producer >-> consumer 

useSafeConsumer :: Consumer b (SafeT IO) () -> Siphon b e ()
useSafeConsumer consumer = Siphon $ safely $ \producer -> fmap pure $ runEffect $ producer >-> consumer 

useFallibleConsumer :: Consumer b (ExceptT e IO) () -> Siphon b e ()
useFallibleConsumer consumer = Siphon $ \producer -> runExceptT $ runEffect (hoist lift producer >-> consumer) 

useFold :: (Producer b IO () -> IO a) -> Siphon b e a 
useFold aFold = Siphon $ fmap (fmap pure) $ aFold 

useParser :: Parser b IO (Either e a) -> Siphon b e a 
useParser parser = Siphon $ Pipes.Parse.evalStateT parser 

{-|
    Useful for constructing @stdin@ feeding functions from a 'Producer'.

    You may need to use 'surely' for the types to fit.
 -}
useProducer :: Producer b IO () -> Pump b e ()
useProducer producer = Pump $ \consumer -> fmap pure $ runEffect (producer >-> consumer) 

useSafeProducer :: Producer b (SafeT IO) () -> Pump b e ()
useSafeProducer producer = Pump $ safely $ \consumer -> fmap pure $ runEffect (producer >-> consumer) 

useFallibleProducer :: Producer b (ExceptT e IO) () -> Pump b e ()
useFallibleProducer producer = Pump $ \consumer -> runExceptT $ runEffect (producer >-> hoist lift consumer) 

{-| 
  Useful when we want to plug in a handler that doesn't return an 'Either'. For
example folds from "Pipes.Prelude", or functions created from simple
'Consumer's with 'useConsumer'. 

  > surely = fmap (fmap Right)
 -}
surely :: (Functor f0, Functor f1) => f0 (f1 a) -> f0 (f1 (Either e a))
surely = fmap (fmap Right)

{-| 
  Useful when we want to plug in a handler that does its work in the 'SafeT'
transformer.
 -}
safely :: (MFunctor t, C.MonadMask m, MonadIO m) 
       => (t (SafeT m) l -> (SafeT m) x) 
       ->  t m         l -> m         x 
safely activity = runSafeT . activity . hoist lift 

-- fallibly :: (MFunctor t, Monad m, Error e) 
--          => (t (ErrorT e m) l -> (ErrorT e m) x) 
--          ->  t m            l -> m (Either e x) 
-- fallibly activity = runErrorT . activity . hoist lift 

buffer :: (Show e, Typeable e)
       =>  Siphon bytes e (a -> b)
       ->  Siphon text e a
       ->  Producer text  IO (Producer bytes IO ()) -> IO (Either e b)
buffer policy activity producer = do
    (outbox,inbox,seal) <- spawn' Unbounded
    r <- conceit 
              (do feeding <- async $ runEffect $ 
                        producer >-> (toOutput outbox >> P.drain)
                  Right <$> wait feeding `finally` atomically seal
              )
              (runSiphon activity (fromInput inbox) `finally` atomically seal)
    case r of 
        Left e -> return $ Left e
        Right (leftovers,a) -> runSiphon (fmap ($a) policy) leftovers

buffer_ :: (Show e, Typeable e) 
        => (Producer ByteString IO () -> IO (Either e a))
        ->  Producer ByteString IO () -> IO (Either e a)
buffer_ activity producer = do
    (outbox,inbox,seal) <- spawn' Unbounded
    runConceit $
        Conceit (do feeding <- async $ runEffect $ 
                        producer >-> (toOutput outbox >> P.drain)
                    Right <$> wait feeding `finally` atomically seal
                )
        *>
        Conceit (activity (fromInput inbox) `finally` atomically seal)

type DecodingFunction bytes text = forall r. Producer bytes IO r -> Producer text IO (Producer bytes IO r)

{-|
   Adapts a function that works with 'Producer's of decoded values so that it
works with 'Producer's of still undecoded values, by supplying a decoding
function and a 'LeftoverPolicy'.
 -}
encoded :: (Show e, Typeable e) 
        -- => (Producer bytes IO () -> Producer text IO (Producer bytes IO ()))
        => DecodingFunction bytes text
        -- => (forall r. Producer bytes IO r -> Producer text IO (Producer bytes IO r))
        -> Siphon bytes e (a -> b)
        -> Siphon text  e a 
        -> Siphon bytes e b
encoded decoder policy activity = Siphon $ \producer -> buffer policy activity $ decoder producer 


data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

newtype Conceit e a = Conceit { runConceit :: IO (Either e a) }

instance Functor (Conceit e) where
  fmap f (Conceit x) = Conceit $ fmap (fmap f) x

instance Bifunctor Conceit where
  bimap f g (Conceit x) = Conceit $ liftM (bimap f g) x

instance (Show e, Typeable e) => Applicative (Conceit e) where
  pure = Conceit . pure . pure
  Conceit fs <*> Conceit as =
    Conceit . revealError $ 
        uncurry ($) <$> concurrently (elideError fs) (elideError as)

instance (Show e, Typeable e) => Alternative (Conceit e) where
  empty = Conceit $ forever (threadDelay maxBound)
  Conceit as <|> Conceit bs =
    Conceit $ either id id <$> race as bs

instance (Show e, Typeable e, Monoid a) => Monoid (Conceit e a) where
   mempty = Conceit . pure . pure $ mempty
   mappend c1 c2 = (<>) <$> c1 <*> c2

conceit :: (Show e, Typeable e) 
        => IO (Either e a)
        -> IO (Either e b)
        -> IO (Either e (a,b))
conceit c1 c2 = runConceit $ (,) <$> Conceit c1 <*> Conceit c2

{-| 
      Works similarly to 'Control.Concurrent.Async.mapConcurrently' from the
@async@ package, but if any of the computations fails with @e@, the others are
immediately cancelled and the whole computation fails with @e@. 
 -}
mapConceit :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConceit f = revealError .  mapConcurrently (elideError . f)

newtype Pump b e a = Pump { runPump :: Consumer b IO () -> IO (Either e a) }

instance Functor (Pump b e) where
  fmap f (Pump x) = Pump $ fmap (fmap (fmap f)) x

instance Bifunctor (Pump b) where
  bimap f g (Pump x) = Pump $ fmap (liftM  (bimap f g)) x

instance (Show e, Typeable e) => Applicative (Pump b e) where
  pure = Pump . pure . pure . pure
  Pump fs <*> Pump as = 
      Pump $ \consumer -> do
          (outbox1,inbox1,seal1) <- spawn' Unbounded
          (outbox2,inbox2,seal2) <- spawn' Unbounded
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
                         return $ pure ()
                      )

instance (Show e, Typeable e, Monoid a) => Monoid (Pump b e a) where
   mempty = Pump . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

{-| 
    'Siphon' is a newtype around a function that does something with a
'Producer'. The applicative instance fuses the functions, so that each one
receives its own copy of the 'Producer' and runs concurrently with the others.
Like with 'Conceit', if any of the functions fails with @e@ the others are
immediately cancelled and the whole computation fails with @e@.   

    'Siphon' and its accompanying functions are useful to run multiple
parsers from "Pipes.Parse" in parallel over the same 'Producer'.
 -}
newtype Siphon b e a = Siphon { runSiphon :: Producer b IO () -> IO (Either e a) }

instance Functor (Siphon b e) where
  fmap f (Siphon x) = Siphon $ fmap (fmap (fmap f)) x

instance Bifunctor (Siphon b) where
  bimap f g (Siphon x) = Siphon $ fmap (liftM  (bimap f g)) x

instance (Show e, Typeable e) => Applicative (Siphon b e) where
  pure = Siphon . pure . pure . pure
  Siphon fs <*> Siphon as = 
      Siphon $ \producer -> do
          (outbox1,inbox1,seal1) <- spawn' Unbounded
          (outbox2,inbox2,seal2) <- spawn' Unbounded
          runConceit $
              Conceit (do
                         -- mmm who cancels these asyncs ??
                         feeding <- async $ runEffect $ 
                             producer >-> P.tee (toOutput outbox1 >> P.drain) 
                                      >->       (toOutput outbox2 >> P.drain)   
                         -- is these async neccessary ??
                         sealing <- async $ wait feeding `finally` atomically seal1 
                                                         `finally` atomically seal2
                         return $ pure ()
                      )
              *>
              Conceit (fmap (uncurry ($)) <$> conceit ((fs $ fromInput inbox1) 
                                                      `finally` atomically seal1) 
                                                      ((as $ fromInput inbox2) 
                                                      `finally` atomically seal2) 
                      )

instance (Show e, Typeable e, Monoid a) => Monoid (Siphon b e a) where
   mempty = Siphon . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

unexpected :: a -> Siphon b b a
unexpected a = Siphon $ \producer -> do
    r <- next producer  
    return $ case r of 
        Left () -> Right a
        Right (b,_) -> Left b


executePipeline :: PipingPolicy Void () -> Pipeline Void -> IO ()
executePipeline pp pipeline = either absurd id <$> executePipelineFallibly pp pipeline

executePipelineFallibly :: (Show e,Typeable e) => PipingPolicy e () -> Pipeline e -> IO (Either e ())
executePipelineFallibly policy pipeline = case policy of 
      PPNone () -> 
           executePipelineInternal pipeo 
                                pipeio 
                                pipei 
                                pipeline
      PPOutput action -> do
            (outbox, inbox, seal) <- spawn' Unbounded
            runConceit $  
                (Conceit $ action $ fromInput inbox)
                *>
                (Conceit $ executePipelineInternal pipeo 
                                                pipeio 
                                                (fmap snd . flip pipeio (useConsumer . toOutput $ outbox))
                                                pipeline
                )
      PPError action -> undefined
      PPOutputError action -> undefined
      PPInput action -> do
            (outbox, inbox, seal) <- spawn' Unbounded
            runConceit $  
                (Conceit $ action (toOutput outbox,atomically seal))
                *>
                (Conceit $ executePipelineInternal (fmap fst . pipeio (useProducer . fromInput $ inbox))
                                                pipeio 
                                                pipei 
                                                pipeline
                )
      PPInputOutput action -> do
            (ioutbox, iinbox, iseal) <- spawn' Unbounded
            (ooutbox, oinbox, oseal) <- spawn' Unbounded
            runConceit $  
                (Conceit $ action (toOutput ioutbox,atomically iseal,fromInput oinbox))
                *>
                (Conceit $ executePipelineInternal (fmap fst . pipeio (useProducer . fromInput $ iinbox))
                                                pipeio 
                                                (fmap snd . flip pipeio (useConsumer . toOutput $ ooutbox))
                                                pipeline
                )
      PPInputError action -> undefined
      PPInputOutputError action -> undefined

executePipelineInternal :: (Show e,Typeable e) 
                     => (Siphon ByteString e () -> PipingPolicy e ())
                     -> (Pump ByteString e () -> Siphon ByteString e () -> PipingPolicy e ((),()))
                     -> (Pump ByteString e () -> PipingPolicy e ())
                     -> Pipeline e 
                     -> IO (Either e ())
executePipelineInternal ppinitial ppmiddle ppend (Pipeline initialStage (liftA2 (,) N.init N.last -> (stages, finalStage))) = 
        initial initialStage $ Data.Foldable.foldr foldy (final finalStage) stages 
    where   
--        initial :: (Show e,Typeable e) 
--                =>  Stage e
--                -> (Producer ByteString IO () -> IO (Either e ()))
--                ->  IO (Either e ())
        initial (Stage cp lpol ecpol) previous = 
            blende ecpol <$> executeFallibly (ppinitial (Siphon previous)) cp

--        foldy :: (Show e,Typeable e)  
--              => (BetweenStages e, Stage e) 
--              -> (Producer ByteString IO () -> IO (Either e ()))
--              ->  Producer ByteString IO () -> IO (Either e ())
        foldy (SubsequentStage (BetweenStages pipe) (Stage cp lpol ecpol)) previous producer =
             -- beware when contructing this siphon
             blende ecpol <$> executeFallibly (fmap (const ()) $ ppmiddle (useFallibleProducer $ hoist lift producer >-> pipe) (Siphon previous)) cp

--        final :: (BetweenStages e, Stage e) 
--              -> Producer ByteString IO () 
--              -> IO (Either e ())  
        final (SubsequentStage (BetweenStages pipe) (Stage cp lpol ecpol)) producer = 
            blende ecpol <$> executeFallibly (ppend (useFallibleProducer $ hoist lift producer >-> pipe)) cp

blende :: (Int -> Maybe e) -> Either e (ExitCode,()) -> Either e ()
blende f (Right (ExitFailure i,())) = case f i of
    Nothing -> Right ()
    Just e -> Left e
blende _ (Right (ExitSuccess,())) = Right () 
blende _ (Left e) = Left e

data Pipeline e = Pipeline (Stage e) (NonEmpty (SubsequentStage e)) deriving (Functor)

data Stage e = Stage 
           {
             processDefinition :: CreateProcess 
           , stderrLinePolicy :: LinePolicy e
           , exitCodePolicy :: Int -> Maybe e
           } deriving (Functor)

data SubsequentStage e = SubsequentStage (BetweenStages e) (Stage e) deriving (Functor)

data BetweenStages e = BetweenStages (forall a.Pipe ByteString ByteString (ExceptT e IO) a)

instance Functor BetweenStages where
    fmap f (BetweenStages bs) = BetweenStages $ hoist (mapExceptT $ liftM (bimap f id)) bs

data RootedArborescent e =  RootedArborescent (Stage e) (Arborescent e) deriving (Functor)

data Arborescent e =
        Branches (NonEmpty (SubsequentStage e, Arborescent e))
      | Tip (SubsequentStage e)
      deriving (Functor)

fromPipeline :: Pipeline e -> RootedArborescent e
fromPipeline (Pipeline root (liftA2 (,) N.init N.last -> (stages, finalStage))) = 
    (RootedArborescent root arborescent)
        where arborescent = Data.Foldable.foldr (curry $ Branches . pure) (Tip finalStage) stages

runArborescent :: (Show e,Typeable e) 
               => (Pump ByteString e () -> Siphon ByteString e () -> PipingPolicy e ((),()))
               -> (Pump ByteString e () -> PipingPolicy e ())
               -> (Pump ByteString e () -> PipingPolicy e ())
               -> Arborescent e 
               -> Siphon ByteString e ()
runArborescent ppmiddle ppend ppend' a = case a of
    Branches (b :| bs) -> foo ppend ppend' b <* Prelude.foldr (<*) (pure ()) (foo ppend' ppend' <$> bs) 
    Tip (SubsequentStage (BetweenStages pipe) (Stage cp lpol ecpol)) -> Siphon $ \producer ->
        blende ecpol <$> executeFallibly (ppend (useFallibleProducer $ hoist lift producer >-> pipe)) cp
  where 
    foo ppend ppend' (SubsequentStage (BetweenStages pipe) (Stage cp lpol ecpol), a) = Siphon $ \producer ->
         blende ecpol <$> executeFallibly (fmap (const ()) $ ppmiddle (useFallibleProducer $ hoist lift producer >-> pipe) (runArborescent ppmiddle ppend ppend' a)) cp

{- $reexports
 
"System.Process" is re-exported for convenience.

-} 

