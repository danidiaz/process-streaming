{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}

module System.Process.Streaming.Internal ( 
        Piping(..), 
        Piap(..), 
        Pump(..),
        Siphon(..),
        runSiphon,
        runSiphonDumb,
        Siphon_(..),
        exhaustive,
        Lines(..),
        combined,
        manyCombined,
        Stage(..)
    ) where

import Data.Bifunctor
import Data.Monoid
import Data.Text 
import Control.Applicative
import Control.Applicative.Lift
import Control.Monad
import Control.Monad.Trans.Free hiding (Pure)
import Control.Monad.Trans.Except
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Conceit
import Pipes
import qualified Pipes as P
import qualified Pipes.Prelude as P
import Pipes.ByteString
import qualified Pipes.Text as T
import Pipes.Concurrent
import System.Process
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


newtype Pump b e a = Pump { runPump :: Consumer b IO () -> IO (Either e a) } deriving Functor

{-| 
    'first' is useful to massage errors.
-}
instance Bifunctor (Pump b) where
  bimap f g (Pump x) = Pump $ fmap (liftM  (bimap f g)) x

instance Applicative (Pump b e) where
  pure = Pump . pure . pure . pure
  Pump fs <*> Pump as = 
      Pump $ \consumer -> do
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

instance (Monoid a) => Monoid (Pump b e a) where
   mempty = Pump . pure . pure . pure $ mempty
   mappend s1 s2 = (<>) <$> s1 <*> s2

-- instance IsString b => IsString (Pump b e ()) where 
--    fromString = fromProducer . P.yield . fromString 

{-|
    An alternative to `Piping` for defining what to do with the
    standard streams. 'Piap' is an instance of 'Applicative', unlike
    'Piping'. 

    With 'Piap', the standard streams are always piped. The values of
    @std_in@, @std_out@ and @std_err@ in the 'CreateProcess' record are
    ignored.
 -}
newtype Piap e a = Piap { runPiap :: (Consumer ByteString IO (), IO (), Producer ByteString IO (), Producer ByteString IO ()) -> IO (Either e a) } deriving (Functor)

instance Bifunctor Piap where
  bimap f g (Piap action) = Piap $ fmap (fmap (bimap f g)) action


{-| 
    'pure' creates a 'Piap' that writes nothing to @stdin@ and drains
    @stdout@ and @stderr@, discarding the data.

    '<*>' schedules the writes to @stdin@ sequentially, and the reads from
    @stdout@ and @stderr@ concurrently.
-}
instance Applicative (Piap e) where
  pure a = Piap $ \(consumer, cleanup, producer1, producer2) -> do
      let nullInput = runPump (pure ()) consumer `finally` cleanup
          drainOutput = runSiphonDumb (pure ()) producer1
          drainError = runSiphonDumb (pure ()) producer2
      runConceit $ 
          (\_ _ _ -> a)
          <$>
          Conceit nullInput
          <*>
          Conceit drainOutput
          <*>
          Conceit drainError

  (Piap fa) <*> (Piap fb) = Piap $ \(consumer, cleanup, producer1, producer2) -> do
        latch <- newEmptyMVar :: IO (MVar ())
        (ioutbox, iinbox, iseal) <- spawn' (bounded 1)
        (ooutbox, oinbox, oseal) <- spawn' (bounded 1)
        (eoutbox, einbox, eseal) <- spawn' (bounded 1)
        (ioutbox2, iinbox2, iseal2) <- spawn' (bounded 1)
        (ooutbox2, oinbox2, oseal2) <- spawn' (bounded 1)
        (eoutbox2, einbox2, eseal2) <- spawn' (bounded 1)
        let reroutei = runEffect (fromInput (iinbox <> iinbox2) >-> consumer)
                       `finally` atomically iseal 
                       `finally` atomically iseal2
                       `finally` cleanup
            rerouteo = runEffect (producer1 >-> toOutput (ooutbox <> ooutbox2))
                       `finally` atomically oseal 
                       `finally` atomically oseal2
            reroutee = runEffect (producer2 >-> toOutput (eoutbox <> eoutbox2))
                       `finally` atomically eseal 
                       `finally` atomically eseal2
            deceivedf = fa 
                (toOutput ioutbox, 
                 atomically iseal `finally` putMVar latch (), 
                 fromInput oinbox, 
                 fromInput einbox)
                 `finally` atomically iseal 
                 `finally` atomically oseal 
                 `finally` atomically eseal 
            deceivedx = fb 
                (liftIO (takeMVar latch) *> toOutput ioutbox2, 
                 atomically iseal2, 
                 fromInput oinbox2, 
                 fromInput einbox2)
                 `finally` atomically iseal2 
                 `finally` atomically oseal2 
                 `finally` atomically eseal2 
        runConceit $
            _Conceit reroutei 
            *>
            _Conceit rerouteo 
            *> 
            _Conceit reroutee 
            *> 
            (Conceit deceivedf <*> Conceit deceivedx)


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
            (outbox1,inbox1,seal1) <- spawn' (bounded 1)
            (outbox2,inbox2,seal2) <- spawn' (bounded 1)
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
        (outbox,inbox,seal) <- spawn' (bounded 1)
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



-- http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here
combined :: Lines e 
         -> Lines e 
         -> (Producer T.Text IO () -> IO (Either e a))
         -> Producer ByteString IO () 
         -> Producer ByteString IO () 
         -> IO (Either e a)
combined (Lines fun1 twk1) (Lines fun2 twk2) combinedConsumer prod1 prod2 = 
    manyCombined [fmap ($prod1) (fun1 twk1), fmap ($prod2) (fun2 twk2)] combinedConsumer 

manyCombined :: [(FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) -> IO (Either e ())]
             -> (Producer T.Text IO () -> IO (Either e a))
             -> IO (Either e a) 
manyCombined actions consumer = do
    (outbox, inbox, seal) <- spawn' (bounded 1)
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
    A configuration parameter used in functions that combine lines of text from
    multiple streams.
 -}

data Lines e = Lines 
    {
        teardown :: (forall r. Producer T.Text IO r -> Producer T.Text IO r)
                 -> (FreeT (Producer T.Text IO) IO (Producer ByteString IO ()) -> IO (Producer ByteString IO ())) 
                 -> Producer ByteString IO () -> IO (Either e ())
    ,   lineTweaker :: forall r. Producer T.Text IO r -> Producer T.Text IO r
    } 

-- | 'fmap' maps over the encoding error. 
instance Functor Lines where
  fmap f (Lines func lt) = Lines (\x y z -> fmap (bimap f id) $ func x y z) lt



{-|
   An individual stage in a process pipeline. 
 -}
data Stage e = Stage 
           {
             _processDefinition :: CreateProcess 
           , _stderrLines :: Lines e
           , _exitCodePolicy :: ExitCode -> Either e ()
           , _inbound :: forall r. Producer ByteString IO r 
                      -> Producer ByteString (ExceptT e IO) r 
           } 

instance Functor (Stage) where
    fmap f (Stage a b c d) = Stage a (fmap f b) (bimap f id . c) (hoist (mapExceptT $ liftM (bimap f id)) . d)




