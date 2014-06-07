
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide conceiturrent, buffered (to avoid deadlocks) streaming access to
-- the inputs and outputs of system processes.
--
-- There's also an emphasis in having error conditions explicit in the types,
-- instead of throwing exceptions.
--
-- See the functions 'execute' and 'executei' for an entry point. Then the
-- functions 'separate' and 'combined' that handle the consumption of
-- stdout and stderr.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and folds from
-- "Pipes.Prelude" (also folds @pipes-bytestring@ and @pipes-text@) can be used
-- to consume the output streams of the external processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Streaming ( 
        -- * Execution helpers
          execute
        , executei
        , exitCode
        , separated

        -- * Execution with combined stdout/stderr
        , LinePolicy
        , linePolicy
        , LeftoverPolicy
        , ignoreLeftovers
        , failOnLeftovers
        , combined

        -- * Constructing feeding/consuming functions
        , useConsumer
        , useProducer
        , surely
        , safely
        , fallibly
        , monoidally
        , nop
        , encoding

        -- * Conceiturrency helpers
        , Conceit (..)
        , conceit
        , mapConceit
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
import Data.Either.Combinators
import Data.Monoid
import Data.Traversable
import Data.Typeable
import Data.Text 
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
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
    This function takes as arguments a 'CreateProcess' record, an exception
handler, and a consuming function for two 'Producers' associated to @stdout@
and @stderr@, respectively.  

    'execute' tries to avoid launching exceptions, and represents all errors as
@e@ values.

    If the consuming function fails with @e@, the whole computation is
immediately aborted and @e@ is returned.  

   If an error or asynchronous exception happens, the external process is
terminated.

   This function sets the @std_out@ and @std_err@ fields in the 'CreateProcess'
record to 'CreatePipe'.
 -}
execute :: (Show e, Typeable e) 
        => CreateProcess 
        -> (Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a))
        -> IO (Either e (ExitCode,a))
execute spec consumefunc = do
    executeX handle2 spec' $ \(hout,herr) ->
        (,) (consumefunc (fromHandle hout) (fromHandle herr))
            (hClose hout `finally` hClose herr)
    where 
    spec' = spec { std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

{-|
    Like `executei` but with an additional argument consisting in a /feeding/
function that takes the @stdin@ 'Consumer' and writes to it. 

    Like the consuming function, the feeding function can return a value and
can also fail, terminating the process.

    The feeding function is executed /conceiturrently/ with the consuming
functions, not /before/ them.

   'executei' sets the @std_in@, @std_out@ and @std_err@ fields in the
'CreateProcess' record to 'CreatePipe'.
 -}
executei :: (Show e, Typeable e) 
         => CreateProcess 
         -> (Consumer ByteString IO ()                              -> IO (Either e a))
         -> (Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e b))
         -> IO (Either e (ExitCode,(a,b)))
executei spec feeder consumefunc = do
    executeX handle3 spec' $ \(hin,hout,herr) ->
        (,) (conceit (feeder (toHandle hin) `finally` hClose hin) 
                  (consumefunc (fromHandle hout) (fromHandle herr)))
            (hClose hin `finally` hClose hout `finally` hClose herr)
    where 
    spec' = spec { std_in = CreatePipe
                 , std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

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

executeX :: ((forall m. Applicative m => ((t, ProcessHandle) -> m (t, ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))) -> CreateProcess -> (t -> (IO (Either e a), IO())) -> IO (Either e (ExitCode,a))
executeX somePrism procSpec action = mask $ \restore -> do
    handles <- createProcess procSpec  
    case getFirst . getConst . somePrism (Const . First . Just) $ handles of
        Nothing -> 
            throwIO (userError "stdin/stdout/stderr handle unexpectedly null")
            `finally`
            let (_,_,_,phandle) = handles 
            in terminateCarefully phandle 
        Just (htuple,phandle) -> 
            let (a, cleanup) = action htuple in 
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
    'separate' should be used when we want to consume @stdout@ and @stderr@
conceiturrently and independently. It constructs a function that can be plugged
into 'execute' or 'executei'. 

    If the consuming functions return with @a@ and @b@, the corresponding
streams keep being drained until the end. The combined value is not returned
until both @stdout@ and @stderr@ are closed by the external process.

   However, if any of the consuming functions fails with @e@, the whole
computation fails immediately with @e@.
  -}
separated :: (Show e, Typeable e)
          => (Producer ByteString IO () -> IO (Either e a))
          -> (Producer ByteString IO () -> IO (Either e b))
          -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separated outfunc errfunc outprod errprod = 
    conceit (buffer_ outfunc outprod) (buffer_ errfunc errprod)

{-|
  Type synonym for a function that takes a method to "tear down" a FreeT-based
list of lines as first parameter, a 'ByteString' source as second parameter,
and returns a (possibly failing) computation. Presumably, the bytes are decoded
into text, the text split into lines, and the "tear down" function applied. 

See the @pipes-group@ package for utilities on how to manipulate these
FreeT-based lists. They allow you to handle individual lines without forcing
you to have a whole line in memory at any given time.

  See also 'linePolicy' and 'combined'.
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

  > (\x -> yield "prefix: " *> x)

    The third argument is a 'LeftoverPolicy' value that specifies how to handle
decoding failures. 
 -}

linePolicy :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
           -> (forall r. Producer T.Text IO r -> Producer T.Text IO r)
           -> (LeftoverPolicy () ByteString e)
           -> LinePolicy e 
linePolicy decoder transform lopo teardown producer = do
    teardown freeLines >>= runLeftoverPolicy lopo ()
    where
    freeLines = transFreeT transform 
              . viewLines 
              . decoder
              $ producer
    viewLines = getConst . T.lines Const

{-|
    In the Pipes ecosystem, leftovers from decoding operations are often stored
in the result value of 'Producer's (often as 'Producer's themselves). This is a
type synonym for a function that receives a value @a@ and some leftovers @l@,
and may modify the value or fail outright, depending of what the leftovers are.
 -}
data LeftoverPolicy a l e = LeftoverPolicy { runLeftoverPolicy :: a -> Producer l IO () -> IO (Either e a) }

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
failOnLeftovers :: (a -> b -> e) -> LeftoverPolicy a b e 
failOnLeftovers errh = LeftoverPolicy $ \a remainingBytes -> do
    r <- next remainingBytes
    return $ case r of 
        Left () -> Right a
        Right (somebytes,_) -> Left $ errh a somebytes 

{-|
    The bytes from @stdout@ and @stderr@ are decoded into 'Text', splitted into
lines (maybe applying some transformation to each line) and then combined and
consumed by the function passed as argument.

    For both @stdout@ and @stderr@, a 'LinePolicy' must be supplied.

    Like with 'separate', the streams are drained to completion if no errors
happen, but the computation is aborted immediately if any error @e@ is
returned. 

    'combined' returns a function that can be plugged into 'execute' or
'executei'. 

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
combined fun1 fun2 combinedConsumer prod1 prod2 = 
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
    Useful for constructing @stdin@ feeding functions from a 'Producer', to be
plugged into 'executei'.

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
       => (t (SafeT m) l -> (SafeT m) x) -> t m l -> m x 
safely activity = runSafeT . activity . hoist lift 

fallibly :: (MFunctor t, Monad m, Error e) 
         => (t (ErrorT e m) l -> (ErrorT e m) x) -> t m l -> m (Either e x) 
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

{-|
    Value to plug into a 'separate' or 'combined' function when we are not
interested in doing anything with the handle. It returns immediately with @()@. 

    Notice that even if 'nop' returns immediately,  'separate' and
'combined' drain the streams to completion before returning.
  -}
nop :: (MFunctor t, Monad m) => t m l -> m (Either e ()) 
nop = \_ -> return $ Right () 

buffer :: (Show e, Typeable e)
       => LeftoverPolicy a l e
       -> (Producer b IO () -> IO (Either e a))
       -> Producer b IO (Producer l IO r) -> IO (Either e a)
buffer policy activity producer = do
    (outbox,inbox,seal) <- spawn' Unbounded
    let producer = fmap (fmap $ const ()) producer
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
        -> Producer ByteString IO () -> IO (Either e a)
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
   Adapts a function that works with 'Producer's of decoded values so that it works with 'Producer's of still undecoded values, by supplying a decoding function and a 'LeftoverPolicy'.
 -}
encoding :: (Show e, Typeable e) 
         => (Producer b IO r -> Producer t IO (Producer b IO r))
         -> LeftoverPolicy x b e
         -> (Producer t IO () -> IO (Either e x))
         -> Producer b IO r -> IO (Either e x)
encoding decoder policy activity producer = buffer policy activity $ decoder producer 


data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

{-| 
    'Conceit' is very similar to 'Control.Conceiturrent.Async.Conceiturrently' from the
@async@ package, but it has an explicit error type @e@.

   The 'Applicative' instance is used to run actions conceiturrently, wait until
they finish, and combine their results. 

   However, if any of the actions fails with @e@ the other actions are
immediately cancelled and the whole computation fails with @e@. 

    To put it another way: 'Conceit' behaves like 'Conceiturrently' for successes and
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
      Works similarly to 'Control.Conceiturrent.Async.mapConceiturrently' from the
@async@ package, but if any of the computations fails with @e@, the others are
immediately cancelled and the whole computation fails with @e@. 
 -}
mapConceit :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConceit f = revealError .  mapConcurrently (elideError . f)

{-| 
    'Siphon' is a newtype around a function that does something with a
'Producer'. The applicative instance fuses the functions, so that each one
receives its own copy of the 'Producer' and runs conceiturrently with the others.
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
           -> (Producer b IO () -> IO (Either e (x,y)))
forkSiphon c1 c2 = runSiphon $ (,) <$> Siphon c1 <*> Siphon c2

newtype SiphonR e b a = SiphonR { runSiphonR :: Producer b IO () -> IO (Either e a) }

instance Profunctor (SiphonR e) where
     dimap ab cd (SiphonR pf) = SiphonR $ \p -> liftM (fmap cd) $ pf $ p >-> P.map ab

newtype SiphonL a b e = SiphonL { runSiphonL :: Producer b IO () -> IO (Either e a) }

instance Profunctor (SiphonL e) where
     dimap ab cd (SiphonL pf) = SiphonL $ \p -> liftM (bimap cd id) $ pf $ p >-> P.map ab


{- $reexports
 
"System.Process" is re-exported for convenience.

-} 

