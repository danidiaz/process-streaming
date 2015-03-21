
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- system processes.
--
-- Error conditions other than 'IOException's are made explicit
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
{-# LANGUAGE FlexibleInstances #-}


module System.Process.Streaming ( 
        -- * Execution
          executeFallibly
        , execute
        -- * Piping Policies
        , Piping
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
        , fromProducerM
        , fromSafeProducer
        , fromFallibleProducer
        , fromFoldable
        , fromEnumerable
        , fromLazyBytes
        -- * Siphoning bytes out of stdout/stderr
        , Siphon
        , siphon
        , siphon'
        , fromFold
        , fromFold'
        , fromFold'_
        , fromFoldl
        , fromFoldlIO
        , fromFoldlM
        , fromConsumer
        , fromConsumerM
        , fromSafeConsumer
        , fromFallibleConsumer
        , fromParser
        , fromParserM 
        , unwanted
        , intoLazyBytes
        , intoLazyText 
        , DecodingFunction
        , encoded
        , SiphonOp (..)
        -- * Line handling
        , Lines
        , toLines
        , tweakLines
        , prefixLines
        -- * Pipelines
        , executePipelineFallibly
        , executePipeline
        --, simplePipeline
        , Stage
        , stage
        , pipefail
        , inbound
        -- * Re-exports
        -- $reexports
        , module System.Process
        , T.decodeUtf8 
        -- * Deprecated
        -- $deprecated
        , PipingPolicy
        , LinePolicy
        , linePolicy 
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
import qualified Pipes.Text.Encoding as T
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.IO.Error
import System.Process
import System.Process.Lens
import System.Exit

{-|
  A simplified version of 'executeFallibly' for when the error type is `Void`.
  Note however that this function may still throw exceptions.
 -}
execute :: Piping Void a -> CreateProcess -> IO (ExitCode,a)
execute pp cprocess = either absurd id <$> executeFallibly pp cprocess

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
executeFallibly :: Piping e a -> CreateProcess -> IO (Either e (ExitCode,a))
executeFallibly pp record = case pp of
      PPNone a -> executeInternal 
          record 
          nohandles   
          (\() -> (return . Right $ a,return ()))
      PPOutput action -> executeInternal 
          (record{std_out = CreatePipe}) 
          handleso 
          (\h->(action (fromHandle h),hClose h)) 
      PPError action ->  executeInternal 
          (record{std_err = CreatePipe}) 
          handlese 
          (\h->(action (fromHandle h),hClose h))
      PPOutputError action -> executeInternal 
          (record{std_out = CreatePipe, std_err = CreatePipe}) 
          handlesoe 
          (\(hout,herr)->(action (fromHandle hout
                                 ,fromHandle herr)
                         ,hClose hout `finally` hClose herr))
      PPInput action -> executeInternal 
          (record{std_in = CreatePipe}) 
          handlesi 
          (\h -> (action (toHandle h, hClose h), return ()))
      PPInputOutput action -> executeInternal 
          (record{std_in = CreatePipe,std_out = CreatePipe}) 
          handlesio 
          (\(hin,hout) -> (action (toHandle hin,hClose hin,fromHandle hout)
                          ,hClose hout))
      PPInputError action -> executeInternal 
          (record{std_in = CreatePipe,std_err = CreatePipe}) 
          handlesie 
          (\(hin,herr) -> (action (toHandle hin,hClose hin,fromHandle herr)
                          ,hClose herr))
      PPInputOutputError action -> executeInternal 
          (record{std_in = CreatePipe
                 ,std_out = CreatePipe
                 ,std_err = CreatePipe}) 
          handlesioe 
          (\(hin,hout,herr) -> (action (toHandle hin
                                       ,hClose hin
                                       ,fromHandle hout
                                       ,fromHandle herr)
                               ,hClose hout `finally` hClose herr))

executeInternal :: CreateProcess 
                -> (forall m. Applicative m => (t -> m t) 
                                            -> (Maybe Handle
                                               ,Maybe Handle
                                               ,Maybe Handle) 
                                            -> m (Maybe Handle
                                                 ,Maybe Handle
                                                 ,Maybe Handle)) 
                -> (t ->(IO (Either e a),IO ())) 
                -> IO (Either e (ExitCode,a))
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

{-|
    Do not pipe any standard stream. 
-}
nopiping :: Piping e ()
nopiping = PPNone ()

{-|
    Pipe @stdout@.
-}
pipeo :: Siphon ByteString e a -> Piping e a
pipeo (runSiphon -> siphonout) = PPOutput $ siphonout

{-|
    Pipe @stderr@.
-}
pipee :: Siphon ByteString e a -> Piping e a
pipee (runSiphon -> siphonout) = PPError $ siphonout

{-|
    Pipe @stdout@ and @stderr@.
-}
pipeoe :: Siphon ByteString e a -> Siphon ByteString e b -> Piping e (a,b)
pipeoe (runSiphon -> siphonout) (runSiphon -> siphonerr) = 
    PPOutputError $ uncurry $ separated siphonout siphonerr  

{-|
    Pipe @stdout@ and @stderr@ and consume them combined as 'Text'.  
-}
pipeoec :: Lines e -> Lines e -> Siphon Text e a -> Piping e a
pipeoec policy1 policy2 (runSiphon -> siphon) = 
    PPOutputError $ uncurry $ combined policy1 policy2 siphon  

{-|
    Pipe @stdin@.
-}
pipei :: Pump ByteString e i -> Piping e i
pipei (Pump feeder) = PPInput $ \(consumer,cleanup) -> feeder consumer `finally` cleanup

{-|
    Pipe @stdin@ and @stdout@.
-}
pipeio :: Pump ByteString e i -> Siphon ByteString e a -> Piping e (i,a)
pipeio (Pump feeder) (runSiphon -> siphonout) = PPInputOutput $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonout producer))

{-|
    Pipe @stdin@ and @stderr@.
-}
pipeie :: Pump ByteString e i -> Siphon ByteString e a -> Piping e (i,a)
pipeie (Pump feeder) (runSiphon -> siphonerr) = PPInputError $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonerr producer))

{-|
    Pipe @stdin@, @stdout@ and @stderr@.
-}
pipeioe :: Pump ByteString e i -> Siphon ByteString e a -> Siphon ByteString e b -> Piping e (i,a,b)
pipeioe (Pump feeder) (runSiphon -> siphonout) (runSiphon -> siphonerr) = fmap flattenTuple $ PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (separated siphonout siphonerr outprod errprod))
    where
        flattenTuple (i, (a, b)) = (i,a,b)

{-|
    Pipe @stdin@, @stdout@ and @stderr@, consuming the last two combined as 'Text'.
-}
pipeioec :: Pump ByteString e i -> Lines e -> Lines e -> Siphon Text e a -> Piping e (i,a)
pipeioec (Pump feeder) policy1 policy2 (runSiphon -> siphon) = PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (combined policy1 policy2 siphon outprod errprod))

separated :: (Producer ByteString IO () -> IO (Either e a))
          -> (Producer ByteString IO () -> IO (Either e b))
          ->  Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separated outfunc errfunc outprod errprod = 
    conceit (outfunc outprod) (errfunc errprod)

-- http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here
combined :: Lines e 
         -> Lines e 
         -> (Producer T.Text IO () -> IO (Either e a))
         -> Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e a)
combined (Lines fun1 twk1) (Lines fun2 twk2) combinedConsumer prod1 prod2 = 
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

instance IsString b => IsString (Pump b e ()) where 
   fromString = fromProducer . P.yield . fromString 

fromProducer :: Producer b IO r -> Pump b e ()
fromProducer producer = Pump $ \consumer -> fmap pure $ runEffect (mute producer >-> consumer) 

fromProducerM :: MonadIO m => (m () -> IO (Either e a)) -> Producer b m r -> Pump b e a 
fromProducerM whittle producer = Pump $ \consumer -> whittle $ runEffect (mute producer >-> hoist liftIO consumer) 

fromSafeProducer :: Producer b (SafeT IO) r -> Pump b e ()
fromSafeProducer = fromProducerM (fmap pure . runSafeT)

fromFallibleProducer :: Producer b (ExceptT e IO) r -> Pump b e ()
fromFallibleProducer = fromProducerM runExceptT

fromFoldable :: Foldable f => f b -> Pump b e ()
fromFoldable = fromProducer . each

fromEnumerable :: Enumerable t => t IO b -> Pump b e ()
fromEnumerable = fromProducer . every

fromLazyBytes :: BL.ByteString -> Pump ByteString e () 
fromLazyBytes = fromProducer . fromLazy 

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
        (outbox,inbox,seal) <- spawn' Single
        runConceit $ 
            (,) 
            <$>
            Conceit (activity (fromInput inbox) `finally` atomically seal)
            <*>
            _Conceit (runEffect (producer >-> (toOutput outbox >> P.drain)) 
                      `finally` atomically seal
                     )

runSiphon :: Siphon b e a -> Producer b IO () -> IO (Either e a)
runSiphon (Siphon (unLift -> s)) = nonexhaustive $ case s of 
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

newtype SiphonOp e a b = SiphonOp { getSiphonOp :: Siphon b e a } 

-- | 'contramap' carn turn a 'SiphonOp' for bytes into a 'SiphonOp' for text.
instance Contravariant (SiphonOp e a) where
    contramap f (SiphonOp (Siphon s)) = SiphonOp . Siphon $ case s of
        Pure p -> Pure p
        Other o -> Other $ case o of
            Exhaustive e -> Exhaustive $ \producer ->
                e $ producer >-> P.map f
            Nonexhaustive ne -> Nonexhaustive $ \producer ->
                ne $ producer >-> P.map f

-- | 'divide' builds a 'SiphonOp' for a composite out of the 'SiphonOp's
-- for the parts.
instance Monoid a => Divisible (SiphonOp e a) where
    divide divider siphonOp1 siphonOp2 = contramap divider . SiphonOp $ 
        (getSiphonOp (contramap fst siphonOp1)) 
        `mappend`
        (getSiphonOp (contramap snd siphonOp2))
    conquer = SiphonOp (pure mempty)

-- | 'choose' builds a 'SiphonOp' for a sum out of the 'SiphonOp's
-- for the branches.
instance Monoid a => Decidable (SiphonOp e a) where
    choose chooser (SiphonOp s1) (SiphonOp s2) = 
        contramap chooser . SiphonOp $ 
            (contraPipeMapL s1) 
            `mappend`
            (contraPipeMapR s2)
      where
        contraPipeMapL (Siphon s) = Siphon $ case s of
            Pure p -> Pure p
            Other o -> Other $ case o of
                Exhaustive e -> Exhaustive $ \producer ->
                    e $ producer >-> allowLefts
                Nonexhaustive ne -> Nonexhaustive $ \producer ->
                    ne $ producer >-> allowLefts
        contraPipeMapR (Siphon s) = Siphon $ case s of
            Pure p -> Pure p
            Other o -> Other $ case o of
                Exhaustive e -> Exhaustive $ \producer ->
                    e $ producer >-> allowRights
                Nonexhaustive ne -> Nonexhaustive $ \producer ->
                    ne $ producer >-> allowRights
        allowLefts = do
            e <- await
            case e of 
                Left l -> Pipes.yield l >> allowLefts
                Right _ -> allowLefts
        allowRights = do
            e <- await
            case e of 
                Right r -> Pipes.yield r >> allowRights
                Left _ -> allowRights
    lose f = SiphonOp . Siphon . Other . Nonexhaustive $ \producer -> do
        n <- next producer  
        return $ case n of 
            Left () -> Right mempty
            Right (b,_) -> Right (absurd (f b))

allowLefts :: Monad m => Pipe (Either b a) b m r
allowLefts = do
    e <- await
    case e of 
        Left l -> Pipes.yield l >> allowLefts
        Right _ -> allowLefts
                                           
allowRights :: Monad m => Pipe (Either b a) a m r
allowRights = do
    e <- await
    case e of 
        Right r -> Pipes.yield r >> allowRights
        Left _ -> allowRights
                                           
intoLazyBytes :: Siphon ByteString e BL.ByteString 
intoLazyBytes = fromFold toLazyM  

intoLazyText :: Siphon Text e TL.Text
intoLazyText = fromFold T.toLazyM  

{-| 
   Builds a 'Siphon' out of a computation that does something with
   a 'Producer', but may fail with an error of type @e@.
   
   Even if the original computation doesn't completely drain the 'Producer',
   the constructed 'Siphon' will.
-}
siphon :: (Producer b IO () -> IO (Either e a))
       -> Siphon b e a 
siphon f = Siphon (Other (Nonexhaustive f))

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
   Builds a 'Siphon' out of a computation that folds a 'Producer' and
   drains it completely.
-}
fromFold' :: (forall r. Producer b IO r -> IO (a,r)) -> Siphon b e a 
fromFold' aFold = siphon' $ fmap (fmap pure) aFold

fromFold'_ :: (forall r. Producer b IO r -> IO r) -> Siphon b e () 
fromFold'_ aFold = fromFold' $ fmap (fmap ((,) ())) aFold


{-| 
   Builds a 'Siphon' out of a pure fold from the @foldl@ package.
-}
fromFoldl :: L.Fold b a -> Siphon b e a 
fromFoldl aFold = fromFold' $ L.purely P.fold' aFold

{-| 
   Builds a 'Siphon' out of a monadic fold from the @foldl@ package that
   works in the IO monad.
-}
fromFoldlIO :: L.FoldM IO b a -> Siphon b e a 
fromFoldlIO aFoldM = fromFold' $ L.impurely P.foldM' aFoldM


{-| 
   Builds a 'Siphon' out of a monadic fold from the @foldl@ package.
-}
fromFoldlM :: MonadIO m 
           => (forall r. m (a,r) -> IO (Either e (c,r))) 
           -> L.FoldM m b a 
           -> Siphon b e c 
fromFoldlM whittle aFoldM = siphon' $ \producer -> 
    whittle $ L.impurely P.foldM' aFoldM (hoist liftIO producer)

fromConsumer :: Consumer b IO r -> Siphon b e ()
fromConsumer consumer = siphon $ \producer -> fmap pure $ runEffect $ producer >-> mute consumer 

fromConsumerM :: MonadIO m 
              => (m () -> IO (Either e a)) 
              -> Consumer b m r 
              -> Siphon b e a
fromConsumerM whittle consumer = siphon $ \producer -> whittle $ runEffect $ (hoist liftIO producer) >-> mute consumer 

fromSafeConsumer :: Consumer b (SafeT IO) r -> Siphon b e ()
fromSafeConsumer = fromConsumerM (fmap pure . runSafeT)

fromFallibleConsumer :: Consumer b (ExceptT e IO) r -> Siphon b e ()
fromFallibleConsumer = fromConsumerM runExceptT

{-| 
  Turn a 'Parser' from @pipes-parse@ into a 'Sihpon'.
 -}
fromParser :: Parser b IO (Either e a) -> Siphon b e a 
fromParser parser = siphon $ Pipes.Parse.evalStateT parser 


{-| 
  Turn a 'Parser' from @pipes-parse@ into a 'Sihpon'.
 -}
fromParserM :: MonadIO m 
            => (forall r. m (a,r) -> IO (Either e (c,r))) 
            -> Parser b m a -> Siphon b e c 
fromParserM f parser = siphon' $ \producer -> f $ drainage $ (Pipes.Parse.runStateT parser) (hoist liftIO producer)
  where
    drainage m = do 
        (a,leftovers) <- m
        r <- runEffect (leftovers >-> P.drain)
        return (a,r)

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

{-|
    See the section /Non-lens decoding functions/ in the documentation for the
@pipes-text@ package.  
-}
type DecodingFunction bytes text = forall r. Producer bytes IO r -> Producer text IO (Producer bytes IO r)

{-|
    Constructs a 'Siphon' that works on encoded values out of a 'Siphon' that
works on decoded values. 
 -}
encoded :: DecodingFunction bytes text
        -- ^ A decoding function.
        -> Siphon bytes e (a -> b)
        -- ^ A 'Siphon' that determines how to handle leftovers. 
        -- Pass @pure id@ to ignore leftovers. Pass
        -- @unwanted id@ to abort the computation if leftovers remain.
        -> Siphon text  e a 
        -> Siphon bytes e b
encoded decoder (Siphon (unLift -> policy)) (Siphon (unLift -> activity)) = 
    Siphon (Other internal)
  where
    internal = Exhaustive $ \producer -> runExceptT $ do
        (a,leftovers) <- ExceptT $ exhaustive activity $ decoder producer 
        (f,r) <- ExceptT $ exhaustive policy leftovers 
        pure (f a,r)


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
    Specifies a transformation that will be applied to each line of text,
    represented as a 'Producer'.
-}
tweakLines :: (forall r. Producer T.Text IO r -> Producer T.Text IO r) -> Lines e -> Lines e 
tweakLines lt' (Lines tear lt) = Lines tear (lt' . lt) 


{-|
    Specifies a prefix that will be calculated and appended for each line of
    text.
-}
prefixLines :: IO T.Text -> Lines e -> Lines e 
prefixLines tio = tweakLines (\p -> liftIO tio *> p) 


{-|
    Constructs a 'Lines' value.
 -}
toLines :: DecodingFunction ByteString Text 
        -- ^ A decoding function for lines of text.
        -> Siphon ByteString e ()
        -- ^ A 'Siphon'
        -- that specifies how to handle decoding failures. Passing @pure ()@ as
        -- the 'Siphon' will ignore any leftovers. Passing @unwanted ()@ will
        -- abort the computation if leftovers remain.
        -> Lines e 
toLines decoder lopo = Lines
    (\tweaker teardown producer -> do
        let freeLines = transFreeT tweaker 
                      . viewLines 
                      . decoder
                      $ producer
            viewLines = getConst . T.lines Const
        teardown freeLines >>= runSiphon lopo)
    id 


{-|
  A simplified version of 'executePipelineFallibly' for when the error type is `Void`.
  Note however that this function may still throw exceptions.
 -}
executePipeline :: Piping Void a -> Tree (Stage Void) -> IO a 
executePipeline pp pipeline = either absurd id <$> executePipelineFallibly pp pipeline


{-|
    Similar to 'executeFallibly', but instead of a single process it
    executes a (possibly branching) pipeline of external processes. 

    This function has a limitation compared to the standard UNIX pipelines.
    If a downstream process terminates early without error, the upstream
    processes are not notified and keep going. There is no SIGPIPE-like
    functionality, in other words. 
 -}
executePipelineFallibly :: Piping e a 
                        -- ^ 
                        -- Views the pipeline as a single process
                        -- for which @stdin@ is the @stdin@ of the first stage and @stdout@ is the
                        -- @stdout@ of the leftmost terminal stage closer to the root.
                        -- @stderr@ is a combination of the @stderr@ streams of all the
                        -- stages. The combined @stderr@ stream always has UTF-8 encoding.
                        -> Tree (Stage e) 
                        -- ^ A (possibly branching) pipeline of processes.
                        -- Each process' stdin is fed with the stdout of
                        -- its parent in the tree.
                        -> IO (Either e a)
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

errorSiphonUTF8 :: MVar (Output ByteString) -> Lines e -> Siphon ByteString e ()
errorSiphonUTF8 mvar (Lines fun twk) = siphon (fun twk iterTLines)
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
           , stderrLines' :: Lines e
           , exitCodePolicy' :: ExitCode -> Either e ()
           , inbound' :: forall r. Producer ByteString IO r 
                      -> Producer ByteString (ExceptT e IO) r 
           } 

instance Functor (Stage) where
    fmap f (Stage a b c d) = Stage a (fmap f b) (bimap f id . c) (hoist (mapExceptT $ liftM (bimap f id)) . d)

{-|
    Builds a 'Stage'.
-}
stage :: Lines e 
      -- ^ How to handle lines coming from stderr for this 'Stage'.
      -> (ExitCode -> Either e ()) 
      -- ^ Does the 'ExitCode' for this 'Stage' represent an error? (Some
      -- programs return non-standard exit codes.)
      -> CreateProcess 
      -- ^ A process definition.
      -> Stage e       
stage lp ec cp = Stage cp lp ec (hoist lift) 

{-|
   Applies a transformation to the stream of bytes flowing into a stage from previous stages.

   This function is ignored for first stages.
-}
inbound :: (forall r. Producer ByteString (ExceptT e IO) r -> Producer ByteString (ExceptT e IO) r)
        -> Stage e -> Stage e 
inbound f (Stage a b c d) = Stage a b c (f . d)

data CreatePipeline e =  CreatePipeline (Stage e) (NonEmpty (Tree (Stage e))) deriving (Functor)

executePipelineInternal :: (Siphon ByteString e () -> Lines e -> Piping e ())
                        -> (Pump ByteString e () -> Siphon ByteString e () -> Lines e -> Piping e ())
                        -> (Pump ByteString e () -> Lines e -> Piping e ())
                        -> (Pump ByteString e () -> Lines e -> Piping e ())
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

{- $deprecated
 

-} 
{-# DEPRECATED PipingPolicy "Use Piping instead" #-} 
type PipingPolicy e a = Piping e a  

{-# DEPRECATED LinePolicy "Use Lines instead" #-} 
type LinePolicy e = Lines e   

{-# DEPRECATED linePolicy "Use toLines instead" #-} 
linePolicy :: DecodingFunction ByteString Text 
           -> Siphon ByteString e ()
           -> Lines e 
linePolicy = toLines 
