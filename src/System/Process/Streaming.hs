
-- |
-- This module contains helper functions and types built on top of
-- @System.Process@.
--
-- See the functions 'execute' and 'execute3' for an entry point. Then the
-- functions 'separate' and 'combineLines' that handle the consumption of
-- stdout and stderr.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and folds from
-- "Pipes.Prelude" can be used to consume the output streams of the external
-- processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Streaming ( 
        -- * Execution helpers
        execute,
        execute3,
        executeX,
        exitCode,
        separate,
        -- * Execution with combined stdout/stderr
        LinePolicy,
        linePolicy,
        LeftoverPolicy,
        ignoreLeftovers,
        failOnLeftovers,
        combineLines,
        combineManyLines,
        -- * Constructing feeding/consuming functions
        useConsumer,
        useProducer,
        surely,
        safely,
        fallibly,
        monoidally,
        exceptionally,
        nop,
        encoding,
        -- * Concurrency helpers
        Conc (..),
        conc,
        mapConc,
        ForkProd (..),
        forkProd
    ) where

import Data.Maybe
import Data.Functor.Identity
import Data.Either
import Data.Either.Combinators
import Data.Monoid
import Data.Traversable
import Data.Typeable
import Data.Text 
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Trans.Either
import Control.Monad.Error
import Control.Monad.State
import Control.Monad.Morph
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
import qualified Pipes.Text as T
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.Process
import System.Process.Lens
import System.Exit

{-|
    This function takes a 'CreateProcess' record, an exception handler, and a
function to consume two 'Producers' associated to @stdout@ and @stderr@.  

    Data from the external process' output handles is continuosuly read and
buffered in memory, so the consuming function can have delays without risking
causing deadlocks in the external process due to full output buffers. 

    When the consuming function returns successfully with @a@, the `Handle`s
from the external process keeps being drained until the process closes them,
and /only then/ the result is returned. 

    If the consuming function fails with @e@, the whole computation is
immediately aborted and @e@ is returned.  

    'execute' tries to avoid launching exceptions, and represents all errors as
@e@ values.

   If an error or asynchronous exception happens, the external process is
terminated.

   This function sets the @std_out@ and @std_err@ fields in the 'CreateProcess'
record to 'CreatePipe'.
 -}
execute :: (Show e, Typeable e) 
        => CreateProcess 
        -> (IOException -> e)
        -> (Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a))
        -> IO (Either e (ExitCode,a))
execute spec ehandler consumefunc = do
    executeX handle2 spec' ehandler $ \(hout,herr) ->
        (,) (consumefunc (fromHandle hout) (fromHandle herr))
            (hClose hout `finally` hClose herr)
    where 
    spec' = spec { std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

{-|
    Like `execute3` but with an additional argument consisting in a /feeding/
function that takes the @stdin@ 'Consumer' and writes to it. 

    The feeding function can return a value.

   This function sets the @std_in@, @std_out@ and @std_err@ fields in the
'CreateProcess' record to 'CreatePipe'.
 -}
execute3 :: (Show e, Typeable e) 
         => CreateProcess 
         -> (IOException -> e)
         -> (Consumer ByteString IO ()                              -> IO (Either e a))
         -> (Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e b))
         -> IO (Either e (ExitCode,(a,b)))
execute3 spec ehandler feeder consumefunc = do
    executeX handle3 spec' ehandler $ \(hin,hout,herr) ->
        (,) (conc (feeder (toHandle hin) `finally` hClose hin) 
                  (consumefunc (fromHandle hout) (fromHandle herr)))
            (hClose hin `finally` hClose hout `finally` hClose herr)
    where 
    spec' = spec { std_in = CreatePipe
                 , std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

try' :: (IOException -> e) -> IO (Either e a) -> IO (Either e a)
try' handler action = try action >>= either (return . Left . handler) return

createProcess' :: CreateProcess 
               -> IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
createProcess' = try . createProcess

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
   Generic execution function out of which construct more specific execution
functions are constructed.

   The first argument is 'Prism' that matches against the tuple returned by
'createProcess' and removes the 'Maybe's that wrap the 'Handle's. 

   The second argument is a CreateProcess record.

   The third argument is an error callback for exceptions thrown when launching
the process, or while waiting for it to complete.  

   The fourth argument is a computation that depends of what the prism matches
(some subset of the handles) and may fail with error @e@. The result of the
computation must come with a cleanup action. 

   If an exception is thrown while this function executes, the external process
is terminated. 
 -}
executeX :: ((forall m. Applicative m => ((t, ProcessHandle) -> m (t, ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))) -> CreateProcess -> (IOException -> e) -> (t -> (IO (Either e a), IO())) -> IO (Either e (ExitCode,a))
executeX somePrism procSpec exHandler action = mask $ \restore -> runEitherT $ do
    maybeHtuple <- bimapEitherT exHandler id $ EitherT $ createProcess' procSpec  
    EitherT $ try' exHandler $ 
        case getFirst . getConst . somePrism (Const . First . Just) $ maybeHtuple of
            Nothing -> 
                throwIO (userError "stdin/stdout/stderr handle unexpectedly null")
                `finally`
                let (_,_,_,phandle) = maybeHtuple 
                in terminateCarefully phandle 
            Just (htuple,phandle) -> let (a, cleanup) = action htuple in 
                -- Handles must be closed *after* terminating the process, because a close
                -- operation may block if the external process has unflushed bytes in the stream.
                (terminateOnError phandle $ restore a `onException` terminateCarefully phandle) 
                `finally` 
                cleanup 

{-|
    Convenience function that merges 'ExitFailure' values into the @e@ value.

    The @e@ value is created from the exit code. 

    Usually composed with the @execute@ functions. 
  -}
exitCode :: Functor c => (Int -> e) -> c (Either e (ExitCode,a)) -> c (Either e a)
exitCode f m = conversion <$> m 
    where
    conversion r = case r of
        Left e -> Left e   
        Right (code,a) -> case code of
            ExitSuccess	-> Right a
            ExitFailure i -> Left $ f i 

{-|
   When we want to process @stdout@ and @stderr@ concurrently and
independently. The resulting function can be plugged into 'execute' or
'execute3'. 
  -}
separate :: (Show e, Typeable e)
         => (Producer ByteString IO () -> IO (Either e a))
         -> (Producer ByteString IO () -> IO (Either e b))
         -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separate outfunc errfunc outprod errprod = 
    conc (buffer outfunc outprod)
         (buffer errfunc errprod)

{-|
  Type synonym for a function that takes a 'ByteString' producer, decodes it
into 'T.Text', and returns a streamed effectful list of line producers. See the
@pipes-group@ package for utilities on how to manipulate these streamed
effectful lists. They allow you to handle individual lines without forcing you
to have a whole line in memory at any given time.

    The final @Producer ByteString IO ()@ return value holds the bytes
following the first decoding error. If there are no decoding errors, it will be
an empty producer.
 -} 
type LinePolicy e = (FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> Producer ByteString IO () -> IO (Either e ())

{-|
    Constructs a 'LinePolicy'.

    The first argument is a function function that decodes 'ByteString' into
'T.Text'. See the section /Decoding Functions/ in the documentation for the
"Pipes.Text" module.  

    The second argument is a function that modifies each individual line. The
line is represented as a 'Producer' to avoid having to keep it wholly in
memory. If you want the lines unmodified, just pass @id@. Line prefixes are
easy to add using applicative notation:

  > linePolicy utf8 (\x -> yield "prefix: " *> x)
 -}
--linePolicy :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
--            -> (forall r. Producer T.Text IO r -> Producer T.Text IO r) 
--            -> LinePolicy
--linePolicy decoder transform =  transFreeT transform 
--                               . viewLines 
--                               . decoder
--    where 
--    viewLines = getConst . T.lines Const

linePolicy :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
           -> (forall r. Producer T.Text IO r -> Producer T.Text IO r)
           -> (LeftoverPolicy (Producer ByteString IO ()) e ())
           -> LinePolicy e 
linePolicy decoder transform lopo teardown producer = do
    teardown freeLines >>= lopo ()
    where
    freeLines =  transFreeT transform 
               . viewLines 
               . decoder
               $ producer
    viewLines = getConst . T.lines Const

{-|
    In the Pipes ecosystem, leftovers from decoding operations are often stored
in the result value of 'Producer's (often as 'Producer's themselves). This is a
type synonym for a function that examines these results values, and may fail
depending on what it encounters.
 -}
type LeftoverPolicy l e a = a -> l -> IO (Either e a)

{-|
    Never fails for any leftover.
 -}
ignoreLeftovers :: LeftoverPolicy l e a
ignoreLeftovers a _ =  return $ Right a

{-|
    For 'ByteString' leftovers, fails if it encounters any leftover and
constructs the error out of the first undedcoded bytes. 
 -}
failOnLeftovers :: (a -> b -> e) -> LeftoverPolicy (Producer b IO ()) e a
failOnLeftovers errh a remainingBytes = do
    r <- next remainingBytes
    return $ case r of 
        Left () -> Right a
        Right (somebytes,_) -> Left $ errh a somebytes 

{-|
    @stdout@ and @stderr@ are decoded into 'Text', splitted into lines (maybe
applying some transformation to each line) and then combined and consumed by
the function passed as argument.

    For both @stdout@ and @stderr@, a 'LinePolicy' must be supplied, along
with a 'LeftoverPolicy'.

    'combineLines' returns a function that can be plugged into 'execute' or
'execute3'. 

    /Beware!/ 'combineLines' avoids situations in which a line emitted
in @stderr@ cuts a long line emitted in @stdout@, see
<http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here> for a description of the problem.  To avoid this, the combined text
stream is locked while writing each individual line. But this means that if the
external program stops writing to a handle /while in the middle of a line/,
lines coming from the other handles won't get printed, either!
 -}
combineLines :: (Show e, Typeable e) 
             => LinePolicy e 
             -> LinePolicy e 
        	 -> (Producer T.Text IO () -> IO (Either e a))
             -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a)
combineLines fun1 fun2 combinedConsumer prod1 prod2 = 
    combineManyLines [fmap (($prod1).buffer) fun1, fmap (($prod2).buffer) fun2] combinedConsumer 
    
    --combineManyLines [(prod1,ld1,lop1),(prod2,ld2,lop2)] combinedConsumer 


{-|
  A more general version of 'combineLines'.   
  -}
combineManyLines :: (Show e, Typeable e) 
                 => [((FreeT (Producer T.Text IO) IO (Producer ByteString IO ())) -> IO (Producer ByteString IO ())) -> IO (Either e ())]
        	     -> (Producer T.Text IO () -> IO (Either e a))
        	     -> IO (Either e a) 
combineManyLines actions consumer = do
    (outbox, inbox, seal) <- spawn' Unbounded
    mVar <- newMVar outbox
    r <- conc (mapConc ($ iterTLines mVar) actions `finally` atomically seal)
              (consumer (fromInput inbox) `finally` atomically seal)
    return $ snd <$> r
    where 
--    produce mVar (producer,lineDec,leftoverp) = 
 --       (iterTLines mVar . lineDec $ producer) >>= leftoverp ()
    iterTLines mvar = iterT $ \textProducer -> do
        -- the P.drain bit was difficult to figure out!!!
        join $ withMVar mvar $ \output -> do
            runEffect $ (textProducer <* P.yield (singleton '\n')) >-> (toOutput output >> P.drain)

{-|
    Useful for constructing @stdout@ or @stderr@ consuming functions.

    You may need to use 'surely' for the types to fit.
 -}
useConsumer :: Monad m => Consumer b m () -> Producer b m () -> m ()
useConsumer consumer producer = runEffect $ producer >-> consumer 

{-|
    Useful for constructing @stdin@ feeding functions.

    You may need to use 'surely' for the types to fit.
 -}
useProducer :: Monad m => Producer b m () -> Consumer b m () -> m ()
useProducer producer consumer = runEffect (producer >-> consumer) 

{-| 
  Useful when we want to plug in a handler that doesn't return an 'Either'. For
example folds from "Pipes.Prelude", or functions created from simple
'Consumer's with 'useConsumer'. 

  > surely = fmap (fmap Right)
 -}
surely :: (Functor f, Functor f') => f (f' a) -> f (f' (Either e a))
surely = fmap (fmap Right)

{-| 
  Useful when we want to plug in a handler that does its work in the 'SafeT'
transformer.
 -}
safely :: (MFunctor t, C.MonadCatch m, MonadIO m) 
       => (t (SafeT m) l -> (SafeT m) x) 
       -> t m l -> m x 
safely activity = runSafeT . activity . hoist lift 

fallibly :: (MFunctor t, Monad m, Error e) 
         => (t (ErrorT e m) l -> (ErrorT e m) x) 
         -> t m l -> m (Either e x) 
fallibly activity = runErrorT . activity . hoist lift 

{-|
  Usually, it is better to use a fold form "Pipes.Prelude" instead of this
function.  But this function has the ability to return the monoidal result
accumulated up until the error happened. 

 The first argument is a function that combines the initial error with the
monoidal result to build the definitive error value. If you want to discard the
results, use 'const' as the first argument.  
 -}
monoidally :: (MFunctor t,Monad m,Monoid w, Error e') 
           => (e' -> w -> e) 
           -> (t (ErrorT e' (WriterT w m)) l -> ErrorT e' (WriterT w m) ())
           -> t m l -> m (Either e w)
monoidally errh activity proxy = do
    (r,w) <- runWriterT . runErrorT . activity . hoist (lift.lift) $ proxy
    return $ case r of
        Left e' -> Left $ errh e' w    
        Right () -> Right $ w

exceptionally :: (IOException -> e) 
              -> (x -> IO (Either e a))
              -> (x -> IO (Either e a)) 
exceptionally handler operation x = try' handler (operation x) 

{-|
    Value to plug into a 'separate' or 'combineLines' function when we are not
interested in doing anything with the handle.
  -}
nop :: (MFunctor t, Monad m) => t m l -> m (Either e ()) 
nop = \_ -> return $ Right () 

{-|
    'Producers' that represent the results of decoding operations store
leftovers in their result values. But many functions in this module
('useConsumer', 'forkProd', and others) work only with 'Producer's that return
@()@. The 'leftover' function augments these functions with a 'LeftoverPolicy'
and lets them work with the result of a decoding. 

    It may happen that the argument function returns successfully but leftovers
exist, indicating a decoding failure. The first argument of 'leftover' lets you
store the results in the message error.
 -}
leftovers :: (Show e, Typeable e)
          => LeftoverPolicy l e a
          -> (Producer b IO () -> IO (Either e a))
          -> Producer b IO l -> IO (Either e a)
leftovers policy activity producer = do
    (outbox,inbox,seal) <- spawn' Unbounded
    r <- conc (do feeding <- async $ runEffect $ 
                      producer >-> (toOutput outbox >> P.drain)
                  Right <$> wait feeding `finally` atomically seal
              )
              (activity (fromInput inbox) `finally` atomically seal)
    -- Possible problem: if the "activity" returns early with a value, the
    -- decoding keeps going on even if the data is never used. And a decoding
    -- error might be found.
    case r of 
        Left e -> return $ Left e
        Right (lp,r') -> policy r' lp

encoding :: (Show e, Typeable e) 
         => (Producer b IO r -> Producer t IO (Producer b IO r))
         -> LeftoverPolicy (Producer b IO r) e x
         -> (Producer t IO () -> IO (Either e x))
         -> Producer b IO r -> IO (Either e x)
encoding decoder policy activity producer = leftovers policy activity $ decoder producer 

--encoding_ :: (Show e, Typeable e) 
--          => (Producer b IO r -> Producer t IO (Producer b IO r))
--          -> LeftoverPolicy (Producer b IO r) e 
--          -> (Producer t IO () -> IO (Either e x))
--          -> Producer b IO r -> IO (Either e x)
--encoding_ decoder = encoding decoder const 

buffer :: (Show e, Typeable e) 
       => (Producer ByteString IO () -> IO (Either e a))
       -> Producer ByteString IO () -> IO (Either e a)
buffer = leftovers ignoreLeftovers


data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

{-| 
    'Conc' is very similar to 'Control.Concurrent.Async.Concurrently' from the
@async@ package, but it has an explicit error type @e@.

    The 'Applicative' instance is used to run actions concurrently and combine their results. 

   If any of the actions fails with @e@ the other actions are immediately
cancelled and the whole computation fails with @e@. 
-}
newtype Conc e a = Conc { runConc :: IO (Either e a) }

instance Functor (Conc e) where
  fmap f (Conc x) = Conc $ fmap (fmap f) x

instance (Show e, Typeable e) => Applicative (Conc e) where
  pure = Conc . pure . pure
  Conc fs <*> Conc as =
    Conc . revealError $ 
        uncurry ($) <$> concurrently (elideError fs) (elideError as)

instance (Show e, Typeable e) => Alternative (Conc e) where
  empty = Conc $ forever (threadDelay maxBound)
  Conc as <|> Conc bs =
    Conc $ either id id <$> race as bs

conc :: (Show e, Typeable e) 
     => IO (Either e a)
     -> IO (Either e b)
     -> IO (Either e (a,b))
conc c1 c2 = runConc $ (,) <$> Conc c1
                           <*> Conc c2

{-| 
      Works similarly to 'Control.Concurrent.Async.mapConcurrently' from the
@async@ package, but if any of the computations fails with @e@, the others are
immediately cancelled and the whole computation fails with @e@. 
 -}
mapConc :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConc f = revealError .  mapConcurrently (elideError . f)

{-| 
    'ForkProd' is a newtype around a function that does something with a
'Producer'. The applicative instance fuses the functions, so that each one
receives its own copy of the 'Producer' and runs concurrently with the others.
Like with 'Conc', if any of the functions fails with @e@ the others are
immediately cancelled and the whole computation fails with @e@.   

    'ForkProd' and its accompanying functions are useful to run multiple
parsers from "Pipes.Parse" in parallel over the same 'Producer'.
 -}
newtype ForkProd b e a = ForkProd { runForkProd :: Producer b IO () -> IO (Either e a) }

instance Functor (ForkProd b e) where
  fmap f (ForkProd x) = ForkProd $ fmap (fmap (fmap f)) x

instance (Show e, Typeable e) => Applicative (ForkProd b e) where
  pure = ForkProd . pure . pure . pure
  ForkProd fs <*> ForkProd as = 
      ForkProd $ \producer -> do
          (outbox1,inbox1,seal1) <- spawn' Unbounded
          (outbox2,inbox2,seal2) <- spawn' Unbounded
          r <- conc (do
                       feeding <- async $ runEffect $ 
                           producer >-> P.tee (toOutput outbox1 >> P.drain) 
                                    >->       (toOutput outbox2 >> P.drain)   
                       sealing <- async $ wait feeding `finally` atomically seal1 
                                                       `finally` atomically seal2
                       return $ Right ()
                    )
                    (fmap (uncurry ($)) <$> conc ((fs $ fromInput inbox1) 
                                                    `finally` atomically seal1) 
                                                 ((as $ fromInput inbox2) 
                                                    `finally` atomically seal2) 
                    )
          return $ fmap snd r

forkProd :: (Show e, Typeable e) 
         => (Producer b IO () -> IO (Either e x))
         -> (Producer b IO () -> IO (Either e y))
         -> (Producer b IO () -> IO (Either e (x,y)))
forkProd c1 c2 = runForkProd $ (,) <$> ForkProd c1
                                   <*> ForkProd c2

