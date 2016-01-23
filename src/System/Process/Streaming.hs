
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
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}


module System.Process.Streaming ( 
        -- * Execution
          executeFallibly
        , execute
        -- * Piping the standard streams
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
        , Pump
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
        , fromConsumer
        , fromConsumer'
        , fromConsumerM
        , fromConsumerM'
        , fromSafeConsumer
        , fromFallibleConsumer
        , fromParser
        , fromParserM 
        , fromFoldl
        , fromFoldlIO
        , fromFoldlM
        , intoLazyBytes
        , intoLazyText 
        , intoList
        , unwanted
        , DecodingFunction
        , encoded
        , SiphonOp (..)
        , contramapFoldable
        , contramapEnumerable
        , contraproduce
        , contraencoded
        , Splitter 
        , splitter
        , splitIntoLines
        , tweakSplits
        , rejoin 
        , nest
        -- * Handling lines
        , Lines
        , toLines
        , tweakLines
        , prefixLines
        -- * Throwing exceptions
        , unwantedX
        , LeftoverException (..)
        , leftoverX
        , _leftoverX
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
        , T.decodeAscii 
        , T.decodeIso8859_1
    ) where

import qualified Data.ByteString.Lazy as BL
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Monoid
import Data.Foldable
import Data.Typeable
import Data.Bifunctor
import Data.Tree
import qualified Data.Text.Lazy as TL
import Data.Text 
import Data.Text.Encoding hiding (decodeUtf8)
import Data.Void
import Data.List.NonEmpty
import Data.Functor.Day
import Data.Profunctor (Star(..))
import Control.Applicative
import Control.Applicative.Lift
import Control.Monad
import Control.Monad.Trans.Free hiding (Pure)
import qualified Control.Monad.Trans.Free as FREE
import Control.Monad.Trans.Except
import qualified Control.Foldl as L
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Conceit
import Pipes
import qualified Pipes as P
import qualified Pipes.Prelude as P
import Pipes.ByteString
import Pipes.Parse
import qualified Pipes.Text as T
import qualified Pipes.Text.Encoding as T
import Pipes.Concurrent
import Pipes.Safe (SafeT, runSafeT)
import System.IO
import System.Process
import System.Process.Lens
import Pipes.Transduce (Fold1,Fold2)
import qualified Pipes.Transduce
import System.Exit

{-|
  A simplified version of 'executeFallibly' for when the error type unifies
  with `Void`.  Note however that this function may still throw exceptions.
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
    (mi,mout,merr,phandle) <- createProcess record
    case getFirst . getConst . somePrism (Const . First . Just) $ (mi,mout,merr) of
        Nothing -> 
            throwIO (userError "stdin/stdout/stderr handle unwantedly null")
            `finally`
            terminateCarefully phandle 
        Just t -> do
            latch <- newEmptyMVar
            let (action,cleanup) = allocator t
                innerRace = _runConceit $
                    (_Conceit (takeMVar latch >> terminateOnError phandle action))
                    <|>   
                    (_Conceit (onException (putMVar latch () >> _runConceit Control.Applicative.empty) 
                                           (terminateCarefully phandle))) 
            -- Handles must be closed *after* terminating the process, because a close
            -- operation may block if the external process has unflushed bytes in the stream.
            (restore innerRace `onException` terminateCarefully phandle) `finally` cleanup 



terminateCarefully :: ProcessHandle -> IO ()
terminateCarefully pHandle = do
    mExitCode <- getProcessExitCode pHandle   
    case mExitCode of 
        Nothing -> catch 
            (terminateProcess pHandle) 
            (\(_::IOException) -> return ())
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
    Do not pipe any standard stream. 
-}
nopiping :: Piping e ()
nopiping = PPNone ()

{-|
    Pipe @stdout@.
-}
pipeo :: Siphon ByteString e a -> Piping e a
pipeo (runSiphonDumb -> siphonout) = PPOutput $ siphonout

{-|
    Pipe @stderr@.
-}
pipee :: Siphon ByteString e a -> Piping e a
pipee (runSiphonDumb -> siphonout) = PPError $ siphonout

{-|
    Pipe @stdout@ and @stderr@.
-}
pipeoe :: Siphon ByteString e a -> Siphon ByteString e b -> Piping e (a,b)
pipeoe (runSiphonDumb -> siphonout) (runSiphonDumb -> siphonerr) = 
    PPOutputError $ uncurry $ separated siphonout siphonerr  

{-|
    Pipe @stdout@ and @stderr@ and consume them combined as 'Text'.  
-}
pipeoec :: Lines e -> Lines e -> Siphon Text e a -> Piping e a
pipeoec policy1 policy2 (runSiphonDumb -> s) = 
    PPOutputError $ uncurry $ combined policy1 policy2 s

{-|
    Pipe @stdin@.
-}
pipei :: Pump ByteString e i -> Piping e i
pipei (Pump feeder) = PPInput $ \(consumer,cleanup) -> feeder consumer `finally` cleanup

{-|
    Pipe @stdin@ and @stdout@.
-}
pipeio :: Pump ByteString e i -> Siphon ByteString e a -> Piping e (i,a)
pipeio (Pump feeder) (runSiphonDumb -> siphonout) = PPInputOutput $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonout producer))

{-|
    Pipe @stdin@ and @stderr@.
-}
pipeie :: Pump ByteString e i -> Siphon ByteString e a -> Piping e (i,a)
pipeie (Pump feeder) (runSiphonDumb -> siphonerr) = PPInputError $ \(consumer,cleanup,producer) ->
        (conceit (feeder consumer `finally` cleanup) (siphonerr producer))

{-|
    Pipe @stdin@, @stdout@ and @stderr@.
-}
pipeioe :: Pump ByteString e i -> Siphon ByteString e a -> Siphon ByteString e b -> Piping e (i,a,b)
pipeioe (Pump feeder) (runSiphonDumb -> siphonout) (runSiphonDumb -> siphonerr) = fmap flattenTuple $ PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (separated siphonout siphonerr outprod errprod))
    where
        flattenTuple (i, (a, b)) = (i,a,b)

{-|
    Pipe @stdin@, @stdout@ and @stderr@, consuming the last two combined as 'Text'.
-}
pipeioec :: Pump ByteString e i -> Lines e -> Lines e -> Siphon Text e a -> Piping e (i,a)
pipeioec (Pump feeder) policy1 policy2 (runSiphonDumb -> s) = PPInputOutputError $
    \(consumer,cleanup,outprod,errprod) -> 
             (conceit (feeder consumer `finally` cleanup) 
                      (combined policy1 policy2 s outprod errprod))

separated :: (Producer ByteString IO () -> IO (Either e a))
          -> (Producer ByteString IO () -> IO (Either e b))
          ->  Producer ByteString IO () -> Producer ByteString IO () -> IO (Either e (a,b))
separated outfunc errfunc outprod errprod = 
    conceit (outfunc outprod) (errfunc errprod)

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
    Collects incoming 'BS.ByteString' values into a lazy 'BL.ByteString'.
-}
intoLazyBytes :: Siphon ByteString e BL.ByteString 
intoLazyBytes = fromFoldl (fmap BL.fromChunks L.list)

{-| 
    Collects incoming 'Data.Text' values into a lazy 'TL.Text'.
-}
intoLazyText :: Siphon Text e TL.Text
intoLazyText = fromFoldl (fmap TL.fromChunks L.list)

intoList :: Siphon b e [b]
intoList = fromFoldl L.list

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

   This functions incurs in less overhead than 'siphon'.
-}
siphon' :: (forall r. Producer b IO r -> IO (Either e (a,r))) -> Siphon b e a 
siphon' f = Siphon (Other (Exhaustive f))

{-| 
    Useful in combination with folds from the pipes prelude, or more
    specialized folds like 'Pipes.Text.toLazyM' from @pipes-text@ and
    'Pipes.ByteString.toLazyM' from @pipes-bytestring@. 
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

fromConsumer :: Consumer b IO () -> Siphon b e ()
fromConsumer consumer = fromFold $ \producer -> runEffect $ producer >-> consumer 

{-| 
    Builds a 'Siphon' out of a 'Consumer' with a polymorphic return type
    (one example is 'toHandle' from @pipes-bytestring@).
-}
fromConsumer' :: Consumer b IO Void -> Siphon b e ()
fromConsumer' consumer = fromFold'_$ \producer -> runEffect $ producer >-> fmap absurd consumer 

fromConsumerM :: MonadIO m 
              => (m () -> IO (Either e a)) 
              -> Consumer b m () 
              -> Siphon b e a
fromConsumerM whittle consumer = siphon $ \producer -> whittle $ runEffect $ (hoist liftIO producer) >-> consumer 

fromConsumerM' :: MonadIO m 
               => (forall r. m r -> IO (Either e (a,r))) 
               -> Consumer b m Void
               -> Siphon b e a
fromConsumerM' whittle consumer = siphon' $ \producer -> whittle $ runEffect $ (hoist liftIO producer) >-> fmap absurd consumer 

fromSafeConsumer :: Consumer b (SafeT IO) Void -> Siphon b e ()
fromSafeConsumer = fromConsumerM' (fmap (\r -> Right ((),r)) . runSafeT)

fromFallibleConsumer :: Consumer b (ExceptT e IO) Void -> Siphon b e ()
fromFallibleConsumer = fromConsumerM' (fmap (fmap (\r -> ((), r))) . runExceptT)

{-| 
  Turn a 'Parser' from @pipes-parse@ into a 'Siphon'.
 -}
fromParser :: Parser b IO (Either e a) -> Siphon b e a 
fromParser parser = siphon' $ \producer -> drainage $ Pipes.Parse.runStateT parser producer
  where
    drainage m = do 
        (a,leftovers) <- m
        r <- runEffect (leftovers >-> P.drain)
        case a of
            Left e -> return (Left e)
            Right a' -> return (Right (a',r)) 

{-| 
  Turn a 'Parser' from @pipes-parse@ into a 'Siphon'.
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
  Constructs a 'Siphon' that aborts the computation with an explicit error
  if the underlying 'Producer' produces anything.
 -}
unwanted :: a -> Siphon b b a
unwanted a = siphon' $ \producer -> do
    n <- next producer  
    return $ case n of 
        Left r -> Right (a,r)
        Right (b,_) -> Left b

{-|
  Like 'unwanted', but throws an exception instead of using the explicit
  error type.
-}
unwantedX :: Exception ex => (b -> ex) -> a -> Siphon b e a
unwantedX f a = siphon' $ \producer -> do
    n <- next producer  
    case n of 
        Left r -> return $ Right (a,r)
        Right (b,_) -> throwIO (f b)

{-|
  Exception that carries a message and a sample of the leftover data.  
-}
data LeftoverException b = LeftoverException String b deriving (Typeable)

instance (Typeable b) => Exception (LeftoverException b)

instance (Typeable b) => Show (LeftoverException b) where
    show (LeftoverException msg _) = 
        "[Leftovers of type " ++ typeName (Proxy::Data.Typeable.Proxy b) ++ "]" ++ msg'
      where
        typeName p = showsTypeRep (typeRep p) []
        msg' = case msg of
                   [] -> []
                   _ -> " " ++ msg

{-|
    Throws 'LeftoverException' if any data comes out of the underlying
    producer, and returns 'id' otherwise.
-}
leftoverX :: String 
          -- ^ Error message
          -> Siphon ByteString e (a -> a)
leftoverX msg = unwantedX (LeftoverException msg') id
    where 
      msg' = "leftoverX." ++ case msg of
         "" -> ""
         _ -> " " ++ msg

{-|
    Like 'leftoverX', but doesn't take an error message.
-}
_leftoverX :: Siphon ByteString e (a -> a)
_leftoverX = unwantedX (LeftoverException msg) id
    where 
      msg = "_leftoverX."

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
        -- ^ A 'Siphon' that determines how to handle decoding leftovers.
        -- Pass @pure id@ to ignore leftovers. Pass @unwanted id@ to abort
        -- the computation with an explicit error if leftovers remain. Pass
        -- '_leftoverX' to throw a 'LeftoverException' if leftovers remain.
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
    Like encoded, but works on 'SiphonOp's. 
 -}
contraencoded :: DecodingFunction bytes text
        -- ^ A decoding function.
        -> Siphon bytes e (a -> b)
        -- ^ A 'Siphon' that determines how to handle decoding leftovers.
        -- Pass @pure id@ to ignore leftovers. Pass @unwanted id@ to abort
        -- the computation with an explicit error if leftovers remain. Pass
        -- '_leftoverX' to throw a 'LeftoverException' if leftovers remain.
        -> SiphonOp e a text
        -> SiphonOp e b bytes 
contraencoded decoder leftovers (SiphonOp siph) = SiphonOp $ 
    encoded decoder leftovers siph


{-|
    Build a 'Splitter' out of a function that splits a 'Producer' while
    preserving streaming.

    See the section /FreeT Transformations/ in the documentation for the
    /pipes-text/ package, and also the documentation for the /pipes-group/
    package.
-}
splitter :: (forall r. Producer b IO r -> FreeT (Producer b IO) IO r) -> Splitter b
splitter = Splitter

{-|
    Specifies a transformation that will be applied to each individual
    split, represented as a 'Producer'.
-}
tweakSplits :: (forall r. Producer b IO r -> Producer b IO r) -> Splitter b -> Splitter b
tweakSplits f (Splitter s) = Splitter $ fmap (transFreeT f) s


{-|
    Flattens the 'Splitter', returning a function from 'Producer' to
    'Producer' which can be passed to functions like 'contraproduce'.
-}
rejoin :: forall b r. Splitter b -> Producer b IO r -> Producer b IO r
rejoin (Splitter f) = go . f 
  where
    -- code copied from the "concats" function from the pipes-group package
    go f = do
        x <- lift (runFreeT f)
        case x of
            FREE.Pure r -> return r
            Free p -> do
                f' <- p
                go f'


splitIntoLines :: Splitter T.Text 
splitIntoLines = splitter $ getConst . T.lines Const


{-|
    Process each individual split created by a 'Splitter' using a 'Siphon'.
 -}
nest :: Splitter b -> Siphon b Void a -> SiphonOp e r a -> SiphonOp e r b
nest (Splitter sp) nested = 
    contraproduce $ \producer -> iterT runRow (hoistFreeT lift $ sp producer)
  where
    runRow p = do
        (r, innerprod) <- lift $ fmap (either absurd id) (runSiphon nested p)
        P.yield r >> innerprod

{-|
    A newtype wrapper with functions for working on the inputs of
    a 'Siphon', instead of the outputs. 
 -}
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

{-|
    Useful to weed out unwanted inputs to a 'Siphon', by returning @[]@.
-}
contramapFoldable :: Foldable f => (a -> f b) -> SiphonOp e r b -> SiphonOp e r a
contramapFoldable unwinder = contramapEnumerable (Select . each . unwinder)

contramapEnumerable :: Enumerable t => (a -> t IO b) -> SiphonOp e r b -> SiphonOp e r a
contramapEnumerable unwinder (getSiphonOp -> s) = SiphonOp $
    siphon' $ runSiphon s . flip for (enumerate . toListT . unwinder) 

contraproduce :: (forall r. Producer a IO r -> Producer b IO r) -> SiphonOp e r b -> SiphonOp e r a
contraproduce f (getSiphonOp -> s) = SiphonOp $ siphon' $ runSiphon s . f

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
        -> Siphon ByteString e (() -> ())
        -- ^ A 'Siphon' that determines how to handle decoding leftovers.
        -- Pass @pure id@ to ignore leftovers. Pass @unwanted id@ to abort
        -- the computation with an explicit error if leftovers remain. Pass
        -- '_leftoverX' to throw a 'LeftoverException' if leftovers remain.
        -> Lines e 
toLines decoder lopo = Lines
    (\tweaker tear producer -> do
        let freeLines = transFreeT tweaker 
                      . viewLines 
                      . decoder
                      $ producer
            viewLines = getConst . T.lines Const
        tear freeLines >>= runSiphonDumb (fmap ($()) lopo))
    id 


{-|
  A simplified version of 'executePipelineFallibly' for when the error type
  unifies with `Void`.  Note however that this function may still throw
  exceptions.
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
          PPNone _ -> blende ecpol <$> executeFallibly policy cp 
          PPOutput _ -> blende ecpol <$> executeFallibly policy cp 
          PPError action -> do
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action $ fromInput einbox)
                    <*
                    (Conceit $ blende ecpol <$> executeFallibly (pipee (errf lpol)) cp `finally` atomically eseal)
          PPOutputError action -> do 
                (outbox, inbox, seal) <- spawn' (bounded 1)
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action $ (fromInput inbox,fromInput einbox))
                    <* 
                    (Conceit $ blende ecpol <$> executeFallibly
                                    (pipeoe (fromConsumer.toOutput $ outbox) (errf lpol)) cp
                               `finally` atomically seal `finally` atomically eseal
                    )
          PPInput _ -> blende ecpol <$> executeFallibly policy cp
          PPInputOutput _ -> blende ecpol <$> executeFallibly policy cp
          PPInputError action -> do
                (outbox, inbox, seal) <- spawn' (bounded 1)
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
                errf <- errorSiphonUTF8 <$> newMVar eoutbox
                runConceit $  
                    (Conceit $ action (toOutput outbox,atomically seal,fromInput einbox))
                    <* 
                    (Conceit $ blende ecpol <$> executeFallibly
                                    (pipeie (fromProducer . fromInput $ inbox) (errf lpol)) cp
                               `finally` atomically seal `finally` atomically eseal
                    )
          PPInputOutputError action -> do
                (ioutbox, iinbox, iseal) <- spawn' (bounded 1)
                (ooutbox, oinbox, oseal) <- spawn' (bounded 1)
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
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
                (outbox, inbox, seal) <- spawn' (bounded 1)
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
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
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
                (outbox, inbox, seal) <- spawn' (bounded 1)
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
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
                (outbox, inbox, seal) <- spawn' (bounded 1)
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
                (ioutbox, iinbox, iseal) <- spawn' (bounded 1)
                (ooutbox, oinbox, oseal) <- spawn' (bounded 1)
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
                (outbox, inbox, seal) <- spawn' (bounded 1)
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
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
                (ioutbox, iinbox, iseal) <- spawn' (bounded 1)
                (ooutbox, oinbox, oseal) <- spawn' (bounded 1)
                (eoutbox, einbox, eseal) <- spawn' (bounded 1)
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
    runTree _ppend _ppend' (Node (Stage _cp _lpol _ecpol pipe) forest) = case forest of
        [] -> siphon $ \producer ->
            blende _ecpol <$> executeFallibly (_ppend (fromFallibleProducer $ pipe producer) _lpol) _cp
        c1 : cs -> siphon $ \producer ->
           blende _ecpol <$> executeFallibly (ppmiddle (fromFallibleProducer $ pipe producer) (runNonEmpty _ppend _ppend' (c1 :| cs)) _lpol) _cp

    runNonEmpty _ppend _ppend' (b :| bs) = 
        runTree _ppend _ppend' b <* Prelude.foldr (<*) (pure ()) (runTree _ppend' _ppend' <$> bs) 
    
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

----------------------------------------------------------------------------

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
    'Pump's are actions that write data into a process' @stdin@. 
 -}
newtype Pump b e a = Pump { runPump :: Consumer b IO () -> IO (Either e a) } deriving Functor

{-| 
    'first' is useful to massage errors.
-}
instance Bifunctor (Pump b) where
  bimap f g (Pump x) = Pump $ fmap (liftM  (bimap f g)) x


{-| 
    'pure' writes nothing to @stdin@.

    '<*>' sequences the writes to @stdin@.
-}
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

{-| 
    A 'Siphon' represents a computation that completely drains
    a 'Producer', but which may fail early with an error of type @e@. 
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


newtype Splitter b = Splitter { getSplitter :: forall r. Producer b IO r -> FreeT (Producer b IO) IO r } 


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


---

newtype Feed1 b e a = Feed1 (Lift (Feed1_ b e) a) deriving (Functor)

newtype Feed1_ b e a = Feed1_ { runFeed1_ :: Consumer b IO () -> IO (Either e a) } deriving Functor

feed1Fallibly :: Feed1 b e a -> Consumer b IO () -> IO (Either e a)
feed1Fallibly (Feed1 (unLift -> s)) = runFeed1_ s

feed1 :: Feed1 b Void a -> Consumer b IO () -> IO a
feed1 (Feed1 (unLift -> s)) = liftM (either absurd id) . runFeed1_ s

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

withProducer :: Producer b IO r -> Feed1 b e ()
withProducer producer = Feed1 . Other . Feed1_ $ \consumer -> fmap pure $ runEffect (void producer >-> consumer) 

withProducerM :: MonadIO m => (m () -> IO (Either e a)) -> Producer b m r -> Feed1 b e a 
withProducerM whittle producer = Feed1 . Other . Feed1_ $ \consumer -> whittle $ runEffect (void producer >-> hoist liftIO consumer) 

withSafeProducer :: Producer b (SafeT IO) r -> Feed1 b e ()
withSafeProducer = withProducerM (fmap pure . runSafeT)

withFallibleProducer :: Producer b (ExceptT e IO) r -> Feed1 b e ()
withFallibleProducer = withProducerM runExceptT

newtype Streams e r = Streams { 
        getStreams :: Day (Day (Feed1 ByteString e) (Fold2 ByteString ByteString e)) (Star (ExceptT e IO) ExitCode) r 
    } deriving (Functor)

executeInternal' :: 
       CreateProcess 
    -> Streams e a
    -> IO (Either e a)
executeInternal' record (Streams streams) = mask $ \restore -> do
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
--    let (clientx,cleanupx,producer1x,producer2x) = 
--            case (mstdin,mstdout,mstderr) of
--                (Just stdinHandle,Just stdoutHandle,Just stderrHandle) ->
--                    (toHandle stdinHandle,hClose stdinHandle,fromHandle stdoutHandle,fromHandle stderrHandle)
--                (Just stdinHandle,Just stdoutHandle,Nothing          ) ->
--                    (toHandle stdinHandle,hClose stdinHandle,fromHandle stdoutHandle,pure ())
--                (Just stdinHandle,Nothing          ,Just stderrHandle) ->
--                    (toHandle stdinHandle,hClose stdinHandle,pure (),fromHandle stderrHandle)
--                (Just stdinHandle,Nothing          ,Nothing          ) ->
--                    (toHandle stdinHandle,hClose stdinHandle,pure (),pure ())
--                (Nothing         ,Just stdoutHandle,Just stderrHandle) ->
--                    (pure (),pure(),fromHandle stdoutHandle,fromHandle stderrHandle)
--                (Nothing         ,Just stdoutHandle,Nothing          ) ->
--                    (pure (),pure(),fromHandle stdoutHandle,pure ())
--                (Nothing         ,Nothing          ,Just stderrHandle) ->
--                    (pure (),pure(),pure (),fromHandle stderrHandle)
--                (Nothing         ,Nothing          ,Nothing          ) -> 
--                    (pure (),pure(),pure (),pure ())

--        (Just stdinHandle
--    case getFirst . getConst . somePrism (Const . First . Just) $ (mi,mout,merr) of
--        Nothing -> 
--            throwIO (userError "stdin/stdout/stderr handle unwantedly null")
--            `finally`
--            terminateCarefully phandle 
--        Just t -> do
--            latch <- newEmptyMVar
--            let (action,cleanup) = allocator t
--                innerRace = _runConceit $
--                    (_Conceit (takeMVar latch >> terminateOnError phandle action))
--                    <|>   
--                    (_Conceit (onException (putMVar latch () >> _runConceit Control.Applicative.empty) 
--                                           (terminateCarefully phandle))) 
--            -- Handles must be closed *after* terminating the process, because a close
--            -- operation may block if the external process has unflushed bytes in the stream.
--            (restore innerRace `onException` terminateCarefully phandle) `finally` cleanup 
