{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Streaming ( 
        ConcurrentlyE (..),
        consume,
        feed,
        createProcessE,
        shellPiped,
        procPiped,
--        noNothingHandles,
--        IOExceptionHandler,
--        StreamSifter,
--        fromConsumer,
--        consume,
--        StdCombinedConsumer,
--        combined,
--        consumeCombined,
--        feed,
--        terminateOnError        
    ) where

import Data.Maybe
import Data.Either
import Data.Monoid
import Data.Typeable
import Control.Applicative
import Control.Monad
import Control.Monad.Error
import Control.Monad.Writer.Strict
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Pipes
import Pipes.Lift
import qualified Pipes.Prelude as P
import Pipes.ByteString
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

createProcessE :: CreateProcess 
               -> IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
createProcessE = try . createProcess

shellPiped :: String -> CreateProcess 
shellPiped cmd = (shell cmd) { std_in = CreatePipe, 
                               std_out = CreatePipe, 
                               std_err = CreatePipe 
                             }

procPiped :: FilePath -> [String] -> CreateProcess 
procPiped cmd args = (proc cmd args) { std_in = CreatePipe, 
                                       std_out = CreatePipe, 
                                       std_err = CreatePipe 
                                     }

noNothingHandles :: (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) 
      -> (Handle, Handle, Handle, ProcessHandle)
noNothingHandles (mb_stdin_hdl, mb_stdout_hdl, mb_stderr_hdl, ph) = 
    maybe (error "handle is unexpectedly Nothing") 
          id
          ((,,,) <$> mb_stdin_hdl 
                 <*> mb_stdout_hdl 
                 <*> mb_stderr_hdl 
                 <*> pure ph)

--type IOExceptionHandler e = IOException -> e
--
--type StreamSifter e a = Producer ByteString IO () -> ErrorT e IO a
--
--fromConsumer :: (Monoid w, Error e) => Consumer ByteString (WriterT w (ErrorT e IO)) () -> StreamSifter e w
--fromConsumer consumer producer = runEffect . execWriterP $ hoist (lift.lift) producer >-> consumer
--
--
--
--
--consume' :: StreamSifter e a
--         -> StreamSifter e b
--         -> IOExceptionHandler e
--         -> (Handle, Handle) 
--         -> ErrorT e IO (a,b)
--consume' stdoutConsumer stderrConsumer exHandler (stdout_hdl, stderr_hdl) = ErrorT $ try' exHandler $ do 
--    (inMailbox1, outMailbox1, seal1) <- spawn' Unbounded
--    a1 <- async $ writeToMailbox stdout_hdl id inMailbox1
--    a2 <- async $ wait a1 `finally` atomically seal1 
--    a3 <- async $ consumeMailbox outMailbox1 stdoutConsumer 
--    (inMailbox2, outMailbox2, seal2) <- spawn' Unbounded
--    b1 <- async $ writeToMailbox stderr_hdl id inMailbox2
--    b2 <- async $ wait b1 `finally` atomically seal2 
--    b3 <- async $ consumeMailbox outMailbox2 stderrConsumer 
--    (_,r) <- waitAny [fmap Right a3,fmap Left b3]
--    -- is waiting here a problem???
--    flip finally (waitBoth a2 b2) $ case r of
--        Left rb -> case rb of 
--            Left e -> do
--                    cancel a3
--                    return $ Left e
--            Right b -> do 
--                ra <- wait a3
--                case ra of
--                    Left e -> return $ Left e -- drop b result
--                    Right a -> return $ Right (a,b)
--        Right ra -> case ra of 
--            Left e -> do
--                    cancel b3
--                    return $ Left e
--            Right a -> do
--                rb <- wait b3
--                case rb of 
--                    Left e -> return $ Left e -- drop a result
--                    Right b -> return $ Right (a,b)
--
--consume :: StreamSifter e a
--        -> StreamSifter e b
--        -> IOExceptionHandler e
--        -> (u,Handle, Handle,v)
--        -> (u,ErrorT e IO (a,b),v)
--consume stdoutReader stderrReader exHandler (u, stdout_hdl, stderr_hdl, v) =
--    (u, consume' stdoutReader stderrReader exHandler (stdout_hdl, stderr_hdl), v)
--
--type StdCombinedConsumer e a = Producer (Either ByteString ByteString) IO () -> ErrorT e IO a
--
--
--consumeCombined' :: Pipe ByteString ByteString IO X  
--                 -> Pipe ByteString ByteString IO X   
--                 -> StreamSifter e a
--                 -> IOExceptionHandler e
--                 -> (Handle, Handle) 
--                 -> ErrorT e IO a
--consumeCombined' = undefined

---- Useful in combination with "bifold" of the "bifunctors" package.
--combined :: (Either ByteString ByteString -> ByteString) 
--         -> (a -> StreamSifter e b) 
--         -> a -> StdCombinedConsumer e b
--combined mapper f a producer =  f a (producer >-> P.map mapper)  
--
--consumeCombined' :: StdCombinedConsumer e a
--                 -> IOExceptionHandler e
--                 -> (Handle, Handle) 
--                 -> ErrorT e IO a
--consumeCombined' combinedReader exHandler (stdout_hdl, stderr_hdl)  = ErrorT $ try' exHandler $ do 
--    undefined
--    (inMailbox1, outMailbox1, seal1) <- spawn' Unbounded
--    a1 <- async $ writeToMailbox stdout_hdl Right inMailbox1
--    a2 <- async $ wait a1 `finally` atomically seal1 
--    --a3 <- async $ consumeMailbox outMailbox1 stdoutConsumer 
--    b1 <- async $ writeToMailbox stderr_hdl Left inMailbox1
--    b2 <- async $ wait b1 `finally` atomically seal1 
--    -- Better link the asyncs? --should the asyncs be really canceled? 
--    consumeMailbox outMailbox1 combinedReader `finally` (cancel a1 >> cancel b1) 
--                                              `finally` (waitBoth a2 b2)
--
--consumeCombined :: StdCombinedConsumer e a
--                -- Maybe (Int,ByteString) -- limit the length of lines? Would this be useful?
--                -> IOExceptionHandler e
--                -> (u,Handle, Handle,v)
--                -> (u,ErrorT e IO a,v)
--consumeCombined combinedReader exHandler (u, stdout_hdl, stderr_hdl, v) =
--    (u, consumeCombined' combinedReader exHandler (stdout_hdl, stderr_hdl), v)

--feed' :: Producer ByteString IO a
--      -> IOExceptionHandler e
--      -> Handle
--      -> ErrorT e IO b
--      -> ErrorT e IO b 
--feed' producer exHandler stdin_hdl action = ErrorT $ try' exHandler $ do
--    a1 <- async $ runEffect $ producer >-> toHandle stdin_hdl       
--    a2 <- async $ runErrorT action
--    r <- wait a2  
--    case r of
--        Left e -> cancel a1 >> (return $ Left e)
--        Right b -> wait a1 >> (return $ Right b)
--
--feed :: Producer ByteString IO a
--     -> IOExceptionHandler e
--     -> (Handle,ErrorT e IO b,v)
--     -> (ErrorT e IO b,v)
--feed producer exHandler (stdin_hdl,action,v) =
--    (feed' producer exHandler stdin_hdl action, v)
--
--terminateOnError :: (ErrorT e IO a,ProcessHandle)
--                 -> ErrorT e IO (a,ExitCode)
--terminateOnError (action,pHandle) = ErrorT $ do
--    result <- runErrorT action
--    case result of
--        Left e -> do    
--            terminateProcess pHandle  
--            return $ Left e
--        Right r -> do 
--            exitCode <- waitForProcess pHandle 
--            return $ Right (r,exitCode)  
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


