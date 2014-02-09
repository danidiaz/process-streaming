{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.Process.Streaming ( 
        ConcurrentlyE (..),
        mapConcurrentlyE,
        consume,
        decodeLines,
        consumeCombinedLines,
        feed,
        createProcessE,
        _cmdspec,
        _RawCommand,
        _ShellCommand,
        _cwd,
        _env,
        stream3,
        pipe3,
        handle3,
        terminateOnError        
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
newtype ConcurrentlyE e a = ConcurrentlyE { runConcurrentlyE :: IO (Either e a) }

instance Functor (ConcurrentlyE e) where
  fmap f (ConcurrentlyE x) = ConcurrentlyE $ fmap (fmap f) x

instance (Show e, Typeable e) => Applicative (ConcurrentlyE e) where
  pure = ConcurrentlyE . pure . pure
  ConcurrentlyE fs <*> ConcurrentlyE as =
    ConcurrentlyE . revealError $ 
        (\(f, a) -> f a) <$> concurrently (elideError fs) (elideError as)

instance (Show e, Typeable e) => Alternative (ConcurrentlyE e) where
  empty = ConcurrentlyE $ forever (threadDelay maxBound)
  ConcurrentlyE as <|> ConcurrentlyE bs =
    ConcurrentlyE $ either id id <$> race as bs

mapConcurrentlyE :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConcurrentlyE f = revealError .  mapConcurrently (elideError . f)

--
mailbox2Handle :: Input ByteString -> Handle -> IO ()
mailbox2Handle mailbox handle = 
     finally (runEffect $ fromInput mailbox >-> toHandle handle)
             (hClose handle) 

handle2Mailbox :: Handle -> Output ByteString -> IO ()
handle2Mailbox handle mailbox = 
     finally (runEffect $ fromHandle handle >-> toOutput mailbox)
             (hClose handle) 

consumeMailbox :: Input z -> (Producer z IO () -> IO (Either e a)) -> IO (Either e a)
consumeMailbox inMailbox consumer = do
    result <- consumer $ fromInput inMailbox
    case result of 
        Left e -> return $ Left e
        Right r -> do
            runEffect $ fromInput inMailbox >-> P.drain 
            return $ result

feedMailbox :: (Consumer z IO () -> IO (Either e a)) -> Output z -> IO (Either e a)
feedMailbox feeder outMailbox = feeder $ toOutput outMailbox

try' :: (IOException -> e) -> IO (Either e a) -> IO (Either e a)
try' handler action = try action >>= either (return . Left . handler) return

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

writeLines :: MVar (Output T.Text) 
           -> (ByteString -> e) 
           -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ())
           -> IO (Either e ())
writeLines mvar errh freeTLines = do
    remainingBytes <- iterTLines freeTLines
    -- We use EitherT instead of ErrorT to avoid an Error constraint on e.
    runEitherT $ runEffect $ hoist lift remainingBytes >-> (await >>= lift . left . errh) 
    where
    iterTLines :: forall x. FreeT (Producer T.Text IO) IO x -> IO x
    iterTLines = iterT $ \textProducer -> do
        withMVar mvar $ \output -> do
            -- the P.drain bit was difficult to figure out!!!
            join $ runEffect $ textProducer >-> (toOutput output >> P.drain)

decodeLines :: T.Codec
            -> (forall t1. Producer T.Text IO t1 -> Producer T.Text IO t1) 
            -> Producer ByteString IO ()
            -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ())
decodeLines aCodec transform producer = transFreeT transform . viewLines . viewDecoded $ producer
    where 
    viewLines = getConst . T.lines Const
    viewDecoded = getConst . T.codec aCodec Const

consumeCombinedLines :: (Show e, Typeable e) 
                     => (IOException -> e) 
                     -> (ByteString -> e)
                     -> [(Handle, Producer ByteString IO () -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ()))]
        			 -> (Producer T.Text IO () -> IO (Either e a))
        		     -> IO (Either e a) 
consumeCombinedLines exHandler encHandler actions c = try' exHandler $ do
    (outbox, inbox, seal) <- spawn' Unbounded
    t <- newMVar outbox
    r <- runConcurrentlyE $ (,) <$> ConcurrentlyE (finally (mapConcurrentlyE (\(h,f) -> consume exHandler h $ writeLines t encHandler .   f) actions) 
                                                           (atomically seal))

                                <*> ConcurrentlyE (consumeMailbox inbox c)
    return $ snd <$> r

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

--
--example1 =  terminateOnError 
--          . feed undefined undefined     
--          . consume undefined undefined undefined 
--          . noNothingHandles
--
--example2 =  terminateOnError 
--          . feed undefined undefined     
--          . consumeCombined undefined undefined 
--          . noNothingHandles

--foo2 :: (Monoid w, Error e) => Consumer ByteString (WriterT w (ErrorT e IO)) () -> StdCombinedConsumer e w
--foo2 = combined (either id id) fromConsumer


