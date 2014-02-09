{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.Process.Streaming ( 
        ConcE (..),
        mapConcE,
        Consumption,
        consume,
        LineDecoder,
        lineDecoder,
        consumeCombinedLines,
        useConsumer,
        useConsumerE,
        useConsumerW,
        Feeding,
        feed,
        useProducer,
        useProducerE,
        useProducerW,
        terminateOnError,
        createProcessE,
        _cmdspec,
        _RawCommand,
        _ShellCommand,
        _cwd,
        _env,
        stream3,
        pipe3,
        handle3
    ) where

import Data.Maybe
import Data.Functor.Identity
import Data.Either
import Data.Monoid
import Data.Traversable
import Data.Typeable
import Control.Applicative
import Control.Monad
import Control.Monad.Trans.Free
import Control.Monad.Trans.Either
import Control.Monad.Error
import Control.Monad.Writer.Strict
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Pipes
import qualified Pipes.Prelude as P
import Pipes.Lift
import Pipes.ByteString
import qualified Pipes.Text as T
import Pipes.Concurrent
import System.IO
import System.Process
import System.Exit

data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

-- A variant of Concurrently with errors explicit in the signature.
newtype ConcE e a = ConcE { runConcE :: IO (Either e a) }

instance Functor (ConcE e) where
  fmap f (ConcE x) = ConcE $ fmap (fmap f) x

instance (Show e, Typeable e) => Applicative (ConcE e) where
  pure = ConcE . pure . pure
  ConcE fs <*> ConcE as =
    ConcE . revealError $ 
        uncurry ($) <$> concurrently (elideError fs) (elideError as)

instance (Show e, Typeable e) => Alternative (ConcE e) where
  empty = ConcE $ forever (threadDelay maxBound)
  ConcE as <|> ConcE bs =
    ConcE $ either id id <$> race as bs

mapConcE :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConcE f = revealError .  mapConcurrently (elideError . f)

--
mailbox2Handle :: Input ByteString -> Handle -> IO ()
mailbox2Handle mailbox handle = 
     finally (runEffect $ fromInput mailbox >-> toHandle handle)
             (hClose handle) 

handle2Mailbox :: Handle -> Output ByteString -> IO ()
handle2Mailbox handle mailbox = 
     finally (runEffect $ fromHandle handle >-> toOutput mailbox)
             (hClose handle) 

consumeMailbox :: Input b -> (Producer b IO () -> IO (Either e a)) -> IO (Either e a)
consumeMailbox inMailbox consumer = do
    result <- consumer $ fromInput inMailbox
    case result of 
        Left e -> return $ Left e
        Right r -> do
            runEffect $ fromInput inMailbox >-> P.drain 
            return $ result

feedMailbox :: (Consumer b IO () -> IO (Either e a)) -> Output b -> IO (Either e a)
feedMailbox feeder outMailbox = feeder $ toOutput outMailbox

try' :: (IOException -> e) -> IO (Either e a) -> IO (Either e a)
try' handler action = try action >>= either (return . Left . handler) return

type Consumption b e a = Producer b IO () -> IO (Either e a)

consume :: (IOException -> e) 
        -> Handle 
        -> (Producer ByteString IO () -> IO (Either e a))
        -> IO (Either e a) 
consume exHandler h c = try' exHandler $ do 
    (outbox, inbox, seal) <- spawn' Unbounded
    (_,r) <- concurrently  (do a <- async $ handle2Mailbox h outbox
                               wait a `finally` atomically seal)
                           (consumeMailbox inbox c) 
    return r                                

type LineDecoder = Producer ByteString IO () -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ())

writeLines :: MVar (Output T.Text) 
           -> (ByteString -> e) 
           -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ())
           -> IO (Either e ())
writeLines mvar errh freeTLines = do
    remainingBytes <- iterTLines freeTLines
    -- We use EitherT here instead of ErrorT to avoid an Error constraint on e.
    runEitherT $ runEffect $ hoist lift remainingBytes >-> (await >>= lift . left . errh) 
    where
    iterTLines :: forall x. FreeT (Producer T.Text IO) IO x -> IO x
    iterTLines = iterT $ \textProducer -> do
        withMVar mvar $ \output -> do
            -- the P.drain bit was difficult to figure out!!!
            join $ runEffect $ textProducer >-> (toOutput output >> P.drain)

lineDecoder :: T.Codec
            -> (forall r. Producer T.Text IO r -> Producer T.Text IO r) 
            -> LineDecoder
lineDecoder aCodec transform producer =  transFreeT transform 
                                       . viewLines 
                                       . viewDecoded 
                                       $ producer
    where 
    viewLines = getConst . T.lines Const
    viewDecoded = getConst . T.codec aCodec Const

consumeCombinedLines :: (Show e, Typeable e) 
                     => (IOException -> e) 
                     -> (ByteString -> e)
                     -> [(Handle, LineDecoder)]
        			 -> (Producer T.Text IO () -> IO (Either e a))
        		     -> IO (Either e a) 
consumeCombinedLines exHandler encHandler actions c = try' exHandler $ do
    (outbox, inbox, seal) <- spawn' Unbounded
    mVar <- newMVar outbox
    r <- runConcE $ (,) <$> ConcE (finally (mapConcE (consumeHandle mVar) actions) 
                                           (atomically seal)
                                  )
                        <*> ConcE (consumeMailbox inbox c)
    return $ snd <$> r
    where 
    consumeHandle mVar (h,lineDec) = consume exHandler h $ 
        writeLines mVar encHandler . lineDec 

--
useConsumer :: Consumer b IO () -> Consumption b e ()
useConsumer consumer producer = Right <$> runEffect (producer >-> consumer) 

useConsumerE :: Error e => Consumer b (ErrorT e IO) () -> Consumption b e ()
useConsumerE consumer producer = runEffect $ runErrorP $ hoist lift producer >-> consumer

useConsumerW :: (Monoid w, Error e') => (w -> e' -> e) -> Consumer b (ErrorT e' (WriterT w IO)) () -> Consumption b e w 
useConsumerW resultsUntilError consumer producer = do
    (r,w) <- runEffect $ runWriterP $ runErrorP $ hoist (lift.lift) producer >-> consumer 
    case r of
        Left e' -> return $ Left $ resultsUntilError w e'    
        Right () -> return $ Right w

-- to plug a parser, just use evalStateT! 

type Feeding b e a = Consumer b IO () -> IO (Either e a)

feed :: (IOException -> e)
     -> Handle 
     -> (Consumer ByteString IO () -> IO (Either e a))
     -> IO (Either e a) 
feed exHandler h c = try' exHandler $ do 
    (outbox, inbox, seal) <- spawn' Unbounded
    (r,_) <- concurrently (do a <- async $ feedMailbox c outbox
                              wait a `finally` atomically seal) 
                          (mailbox2Handle inbox h)
    return r

useProducer :: Producer b IO () -> Feeding b e ()
useProducer producer consumer = Right <$> runEffect (producer >-> consumer) 

useProducerE :: Error e => Producer b (ErrorT e IO) () -> Feeding b e ()
useProducerE producer consumer = runEffect $ runErrorP $ producer >-> hoist lift consumer

useProducerW :: (Monoid w, Error e') => (w -> e' -> e) -> Producer b (ErrorT e' (WriterT w IO)) () -> Feeding b e w 
useProducerW resultsUntilError producer consumer = do
    (r,w) <- runEffect $ runWriterP $ runErrorP $ producer >-> hoist (lift.lift) consumer 
    case r of
        Left e' -> return $ Left $ resultsUntilError w e'    
        Right () -> return $ Right w
--

terminateOnError :: ProcessHandle 
                 -> IO (Either e a)
                 -> IO (Either e (ExitCode,a))
terminateOnError pHandle action = do
    result <- action
    case result of
        Left e -> do    
            terminateProcess pHandle  
            return $ Left e
        Right r -> do 
            exitCode <- waitForProcess pHandle 
            return $ Right (exitCode,r)  

--

createProcessE :: CreateProcess 
               -> IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
createProcessE = try . createProcess

_cmdspec :: forall f. Functor f => (CmdSpec -> f CmdSpec) -> CreateProcess -> f CreateProcess 
_cmdspec f c = setCmdSpec c <$> f (cmdspec c)
    where
    setCmdSpec c cmdspec' = c { cmdspec = cmdspec' } 

_ShellCommand :: forall m. Applicative m => (String -> m String) -> CmdSpec -> m CmdSpec 
_ShellCommand f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap ShellCommand (f r)
    where    
    impure (ShellCommand str) = Right str
    impure x = Left x

_RawCommand :: forall m. Applicative m => ((FilePath,[String]) -> m (FilePath,[String])) -> CmdSpec -> m CmdSpec 
_RawCommand f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
    impure (RawCommand fpath strs) = Right (fpath,strs)
    impure x = Left x
    justify (fpath,strs) = RawCommand fpath strs

_cwd :: forall f. Functor f => (Maybe FilePath -> f (Maybe FilePath)) -> CreateProcess -> f CreateProcess 
_cwd f c = setCwd c <$> f (cwd c)
    where
    setCwd c cwd' = c { cwd = cwd' } 

_env :: forall f. Functor f => (Maybe [(String, String)] -> f (Maybe [(String, String)])) -> CreateProcess -> f CreateProcess 
_env f c = setEnv c <$> f (env c)
    where
    setEnv c env' = c { env = env' } 

stream3 :: forall f. Functor f => ((StdStream,StdStream,StdStream) -> f (StdStream,StdStream,StdStream)) -> CreateProcess -> f CreateProcess 
stream3 f c = setStreams c <$> f (getStreams c)
    where 
    getStreams c = (std_in c,std_out c, std_err c)
    setStreams c (s1,s2,s3) = c { std_in  = s1 
                                , std_out = s2 
                                , std_err = s3 
                                } 

pipe3 :: (StdStream,StdStream,StdStream)
pipe3 = (CreatePipe,CreatePipe,CreatePipe)

handle3 :: forall m. Applicative m => ((Handle, Handle, Handle, ProcessHandle) -> m (Handle, Handle, Handle, ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
handle3 f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
    impure (Just h1, Just h2, Just h3, phandle) = Right (h1, h2, h3, phandle) 
    impure x = Left x
    justify (h1, h2, h3, phandle) = (Just h1, Just h2, Just h3, phandle)  
