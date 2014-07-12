
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
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Streaming ( 
        -- * Execution
          execute
        , blendIOExceptions
        , blendExitFailure
        -- * Piping standard streams
        , PipingPolicy
        , nopiping
        , pipeoe
        , pipeioe

        -- * Separated stdout/stderr 
        , separated

        -- * Stdout/stderr combined as text
        , combined
        , LinePolicy
        , linePolicy

        -- * Decoding and leftovers 
        , encoded
        , LeftoverPolicy(..)
        , ignoreLeftovers
        , whenLeftovers 
        , fromFirstLeftovers
        -- * Construction of feeding/consuming functions
        , useConsumer
        , useProducer
        , surely
        , safely
        , fallibly
        , monoidally
        , nop

        , Siphon (..)
        , forkSiphon
        , SiphonL (..)
        , SiphonR (..)

        -- * Re-exports
        -- $reexports
        , module System.Process
    ) where

import Data.Maybe
import Data.Bifunctor
import Data.Profunctor
import Data.Functor.Identity
import Data.Either
import Data.Monoid
import Data.Traversable
import Data.Typeable
import Data.Text 
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Error
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
import qualified Pipes.Text as T
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.IO.Error
import System.Process
import System.Process.Lens
import System.Exit

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
execute :: PipingPolicy e a -> CreateProcess -> IO (Either e (ExitCode,a))
execute (PipingPolicy tr somePrism action) procSpec = mask $ \restore -> do
    (min,mout,merr,phandle) <- createProcess (tr procSpec)
    case getFirst . getConst . somePrism (Const . First . Just) $ (min,mout,merr) of
        Nothing -> 
            throwIO (userError "stdin/stdout/stderr handle unexpectedly null")
            `finally`
            terminateCarefully phandle 
        Just t -> 
            let (a, cleanup) = action t in 
            -- Handles must be closed *after* terminating the process, because a close
            -- operation may block if the external process has unflushed bytes in the stream.
            (restore (terminateOnError phandle a) `onException` terminateCarefully phandle) 
            `finally` 
            cleanup 

exitCode :: (ExitCode,a) -> Either Int a
exitCode (ec,a) = case ec of
    ExitSuccess -> Right a 
    ExitFailure i -> Left i

blendIOExceptions :: (IOError -> e) -> IO (Either e a) -> IO (Either e a)
blendIOExceptions exh task = join . bimap exh id <$> tryIOError task  

blendExitFailure :: (Int -> e) -> Either e (ExitCode,a) -> Either e a
blendExitFailure ech x = join $ bimap id (bimap ech id . exitCode) x 

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
     A 'PipingPolicy' specifies what standard streams of the external process
should be piped, and how to consume them.

     Values of type @a@ denote successful consumption of the streams, values of
type @e@ denote errors.
-}
data PipingPolicy e a = forall t. PipingPolicy (CreateProcess -> CreateProcess) (forall m. Applicative m => (t -> m t) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)) (t -> (IO (Either e a), IO ()))

instance Functor (PipingPolicy e) where
  fmap f (PipingPolicy cpf prsm func) = PipingPolicy cpf prsm $
       (fmap (bimap (fmap (fmap f)) id) func)

instance Bifunctor PipingPolicy where
  bimap f g (PipingPolicy cpf prsm func) = PipingPolicy cpf prsm $
       (fmap (bimap (fmap (bimap f g)) id) func)

{-|
    Do not pipe any standard stream. 
-}
nopiping :: PipingPolicy e ()
nopiping = PipingPolicy id nohandles (\() -> (return $ return (), return ()))  

{-|
    Pipe stderr and stdout.

    See also the 'separated' and 'combined' functions.
-}
pipeoe :: (Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a))
       -> PipingPolicy e a
pipeoe consumefunc = PipingPolicy changecp handlesoe handler  
    where handler (hout,herr) =
            (,) (consumefunc (fromHandle hout) (fromHandle herr))
                (hClose hout `finally` hClose herr)
          changecp cp = cp { std_out = CreatePipe 
                           , std_err = CreatePipe 
                           }

{-|
    Pipe stdin, stderr and stdout.

    See also the 'separated' and 'combined' functions.
-}
pipeioe :: (Show e, Typeable e)
        => (Consumer ByteString IO ()                              -> IO (Either e a))
        -> (Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e b))
        -> PipingPolicy e (a,b)
pipeioe feeder consumefunc = PipingPolicy changecp handlesioe handler  
    where handler (hin,hout,herr) =
            (,) (conceit (feeder (toHandle hin) `finally` hClose hin) 
                         (consumefunc (fromHandle hout) (fromHandle herr)))
                (hClose hin `finally` hClose hout `finally` hClose herr)
          changecp cp = cp { std_in = CreatePipe
                           , std_out = CreatePipe 
                           , std_err = CreatePipe 
                           }

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

linePolicy :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
           -> (forall r. Producer T.Text IO r -> Producer T.Text IO r)
           -> (LeftoverPolicy () ByteString e)
           -> LinePolicy e 
linePolicy decoder transform lopo = LinePolicy $ \teardown producer -> do
    let freeLines = transFreeT transform 
                  . viewLines 
                  . decoder
                  $ producer
        viewLines = getConst . T.lines Const
    teardown freeLines >>= runLeftoverPolicy lopo ()

{-|
    In the Pipes ecosystem, leftovers from decoding operations are often stored
in the result value of 'Producer's (as 'Producer's themselves). 

    A 'LeftoverPolicy' receives a value @a@ and a producer of lefovers of type
@l@. Analyzing the producer, it may modify the value @a@ or fail outright,
depending of what the leftovers are. 
 -}
data LeftoverPolicy a l e = LeftoverPolicy { runLeftoverPolicy :: a -> Producer l IO () -> IO (Either e a) }

instance Functor (LeftoverPolicy a l) where
  fmap f (LeftoverPolicy x) = LeftoverPolicy $ fmap (fmap (fmap (bimap f id))) x

instance Profunctor (LeftoverPolicy a) where
     dimap ab cd (LeftoverPolicy pf) = LeftoverPolicy $ \a p -> liftM (bimap cd id) $ pf a $ p >-> P.map ab

{-|
    Never fails for any leftover.
 -}
ignoreLeftovers :: LeftoverPolicy a l e
ignoreLeftovers =  LeftoverPolicy $ pure . pure . pure

{-|
    Fails if it encounters any leftover, and constructs the error out of the
first undedcoded data. 

    For simple error handling, just ignore the @a@ and the undecoded data:

    > (failOnLeftvoers (\_ _->"badbytes")) :: LeftoverPolicy (Producer b IO ()) String a

    For more detailed error handling, you may want to include the result until
the error @a@ and/or the first undecoded values @b@ in your custom error
datatype.
 -}
fromFirstLeftovers ::  (a -> l -> e) -> LeftoverPolicy a l e 
fromFirstLeftovers errh = LeftoverPolicy $ \a remainingBytes -> do
    r <- next remainingBytes
    return $ case r of 
        Left () -> Right a
        Right (somebytes,_) -> Left $ errh a somebytes 

whenLeftovers :: e -> LeftoverPolicy a l e 
whenLeftovers e = fromFirstLeftovers $ \_ _ -> e



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
             => [((FreeT (Producer T.Text IO) IO (Producer ByteString IO ())) -> IO (Producer ByteString IO ())) -> IO (Either e ())]
        	 -> (Producer T.Text IO () -> IO (Either e a))
        	 -> IO (Either e a) 
manyCombined actions consumer = do
    (outbox, inbox, seal) <- spawn' Unbounded
    mVar <- newMVar outbox
    r <- conceit (mapConceit ($ iterTLines mVar) actions `finally` atomically seal)
              (consumer (fromInput inbox) `finally` atomically seal)
    return $ snd <$> r
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
useConsumer :: Monad m => Consumer b m () -> Producer b m () -> m ()
useConsumer consumer producer = runEffect $ producer >-> consumer 

{-|
    Useful for constructing @stdin@ feeding functions from a 'Producer'.

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

fallibly :: (MFunctor t, Monad m, Error e) 
         => (t (ErrorT e m) l -> (ErrorT e m) x) 
         ->  t m            l -> m (Either e x) 
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
           ->  t m                         l -> m                       (Either e w)
monoidally errh activity proxy = do
    (r,w) <- runWriterT . runErrorT . activity . hoist (lift.lift) $ proxy
    return $ case r of
        Left e' -> Left $ errh e' w    
        Right () -> Right $ w

{-|
    Value to plug into 'separated' or 'combined' when we are not interested in
doing anything with the stream. It returns immediately with @()@. 

    Notice that even if 'nop' returns immediately,  'separate' and
'combined' drain the streams to completion before returning.
  -}
nop :: Applicative m => i -> m (Either e ()) 
nop = pure . pure . pure $ ()

buffer :: (Show e, Typeable e)
       => LeftoverPolicy a l e
       -> (Producer b IO ()                 -> IO (Either e a))
       ->  Producer b IO (Producer l IO ()) -> IO (Either e a)
buffer policy activity producer = do
    (outbox,inbox,seal) <- spawn' Unbounded
    r <- conceit 
              (do feeding <- async $ runEffect $ 
                        producer >-> (toOutput outbox >> P.drain)
                  Right <$> wait feeding `finally` atomically seal
              )
              (activity (fromInput inbox) `finally` atomically seal)
    case r of 
        Left e -> return $ Left e
        Right (lp,r') -> runLeftoverPolicy policy r' lp

buffer_ :: (Show e, Typeable e) 
        => (Producer ByteString IO () -> IO (Either e a))
        ->  Producer ByteString IO () -> IO (Either e a)
buffer_ activity producer = do
    (outbox,inbox,seal) <- spawn' Unbounded
    r <- conceit 
              (do feeding <- async $ runEffect $ 
                        producer >-> (toOutput outbox >> P.drain)
                  Right <$> wait feeding `finally` atomically seal
              )
              (activity (fromInput inbox) `finally` atomically seal)
    return $ fmap snd r 

{-|
   Adapts a function that works with 'Producer's of decoded values so that it
works with 'Producer's of still undecoded values, by supplying a decoding
function and a 'LeftoverPolicy'.
 -}
encoded :: (Show e, Typeable e) 
         => (Producer b IO () -> Producer t IO (Producer b IO ()))
         -> LeftoverPolicy a b e
         -> (Producer t IO () -> IO (Either e a))
         ->  Producer b IO () -> IO (Either e a)
encoded decoder policy activity producer = buffer policy activity $ decoder producer 


data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

{-| 
    'Conceit' is very similar to 'Control.Concurrent.Async.Concurrently' from the
@async@ package, but it has an explicit error type @e@.

   The 'Applicative' instance is used to run actions concurrently, wait until
they finish, and combine their results. 

   However, if any of the actions fails with @e@ the other actions are
immediately cancelled and the whole computation fails with @e@. 

    To put it another way: 'Conceit' behaves like 'Concurrently' for successes and
like 'race' for errors.  
-}
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
          r <- conceit (do
                          feeding <- async $ runEffect $ 
                              producer >-> P.tee (toOutput outbox1 >> P.drain) 
                                       >->       (toOutput outbox2 >> P.drain)   
                          sealing <- async $ wait feeding `finally` atomically seal1 
                                                          `finally` atomically seal2
                          return $ Right ()
                       )
                       (fmap (uncurry ($)) <$> conceit ((fs $ fromInput inbox1) 
                                                       `finally` atomically seal1) 
                                                       ((as $ fromInput inbox2) 
                                                       `finally` atomically seal2) 
                       )
          return $ fmap snd r

instance (Show e, Typeable e, Monoid a) => Monoid (Siphon b e a) where
   mempty = Siphon . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

forkSiphon :: (Show e, Typeable e) 
           => (Producer b IO () -> IO (Either e x))
           -> (Producer b IO () -> IO (Either e y))
           ->  Producer b IO () -> IO (Either e (x,y))
forkSiphon c1 c2 = runSiphon $ (,) <$> Siphon c1 <*> Siphon c2

newtype SiphonL a b e = SiphonL { runSiphonL :: Producer b IO () -> IO (Either e a) }

instance Profunctor (SiphonL e) where
     dimap ab cd (SiphonL pf) = SiphonL $ \p -> liftM (bimap cd id) $ pf $ p >-> P.map ab

newtype SiphonR e b a = SiphonR { runSiphonR :: Producer b IO () -> IO (Either e a) }

instance Profunctor (SiphonR e) where
     dimap ab cd (SiphonR pf) = SiphonR $ \p -> liftM (fmap cd) $ pf $ p >-> P.map ab

{- $reexports
 
"System.Process" is re-exported for convenience.

-} 

