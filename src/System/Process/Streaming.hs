module System.Process.Streaming ( 
        createProcessE,
        shellPiped,
        procPiped,
        noNothingHandles,
        IOExceptionHandler,
        StdConsumer,
        fromConsumer,
        consume,
        StdCombinedConsumer,
        combined,
        consumeCombined,
        feed,
        terminateOnError        
    ) where

import Data.Maybe
import Data.Either
import Data.Monoid
import Control.Applicative
import Control.Monad
import Control.Monad.Error
import Control.Monad.Writer.Strict
import Control.Exception
import Control.Concurrent.Async
import Pipes
import Pipes.Lift
import qualified Pipes.Prelude as P
import Pipes.ByteString
import Pipes.Concurrent
import System.IO
import System.Process
import System.Exit

createProcessE :: CreateProcess 
               -> ErrorT IOException IO (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
createProcessE = ErrorT . try . createProcess

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

type IOExceptionHandler e = IOException -> e

type StdConsumer e a = Producer ByteString IO () -> ErrorT e IO a

fromConsumer :: (Monoid w, Error e) => Consumer ByteString (WriterT w (ErrorT e IO)) () -> StdConsumer e w
fromConsumer consumer producer = runEffect . execWriterP $ hoist (lift.lift) producer >-> consumer

try' :: IOExceptionHandler e -> IO (Either e a) -> IO (Either e a)
try' handler action = try action >>= either (return . Left . handler) return

writeToMailbox :: Handle -> (ByteString -> a) -> Output a -> IO ()
writeToMailbox handle mapper mailbox = 
     finally (runEffect $ fromHandle handle >-> P.map mapper >-> toOutput mailbox)
             (hClose handle) 

consumeMailbox :: Input z -> (Producer z IO () -> ErrorT e IO a) -> IO (Either e a)
consumeMailbox inMailbox consumer = do
    result <- runErrorT . consumer $ fromInput inMailbox
    case result of 
        Left e -> return $ Left e
        Right r -> do
            runEffect $ fromInput inMailbox >-> P.drain 
            return $ result

consume' :: StdConsumer e a
         -> StdConsumer e b
         -> IOExceptionHandler e
         -> (Handle, Handle) 
         -> ErrorT e IO (a,b)
consume' stdoutConsumer stderrConsumer exHandler (stdout_hdl, stderr_hdl) = ErrorT $ try' exHandler $ do 
    (inMailbox1, outMailbox1, seal1) <- spawn' Unbounded
    a1 <- async $ writeToMailbox stdout_hdl id inMailbox1
    a2 <- async $ wait a1 `finally` atomically seal1 
    a3 <- async $ consumeMailbox outMailbox1 stdoutConsumer 
    (inMailbox2, outMailbox2, seal2) <- spawn' Unbounded
    b1 <- async $ writeToMailbox stderr_hdl id inMailbox2
    b2 <- async $ wait b1 `finally` atomically seal2 
    b3 <- async $ consumeMailbox outMailbox2 stderrConsumer 
    (_,r) <- waitAny [fmap Right a3,fmap Left b3]
    -- is waiting here a problem???
    flip finally (waitBoth a2 b2) $ case r of
        Left rb -> case rb of 
            Left e -> do
                    cancel a3
                    return $ Left e
            Right b -> do 
                ra <- wait a3
                case ra of
                    Left e -> return $ Left e -- drop b result
                    Right a -> return $ Right (a,b)
        Right ra -> case ra of 
            Left e -> do
                    cancel b3
                    return $ Left e
            Right a -> do
                rb <- wait b3
                case rb of 
                    Left e -> return $ Left e -- drop a result
                    Right b -> return $ Right (a,b)

consume :: StdConsumer e a
        -> StdConsumer e b
        -> IOExceptionHandler e
        -> (u,Handle, Handle,v)
        -> (u,ErrorT e IO (a,b),v)
consume stdoutReader stderrReader exHandler (u, stdout_hdl, stderr_hdl, v) =
    (u, consume' stdoutReader stderrReader exHandler (stdout_hdl, stderr_hdl), v)

type StdCombinedConsumer e a = Producer (Either ByteString ByteString) IO () -> ErrorT e IO a

-- Useful in combination with "bifold" of the "bifunctors" package.
combined :: (Either ByteString ByteString -> ByteString) 
         -> (a -> StdConsumer e b) 
         -> a -> StdCombinedConsumer e b
combined mapper f a producer =  f a (producer >-> P.map mapper)  

consumeCombined' :: StdCombinedConsumer e a
                 -> IOExceptionHandler e
                 -> (Handle, Handle) 
                 -> ErrorT e IO a
consumeCombined' combinedReader exHandler (stdout_hdl, stderr_hdl)  = ErrorT $ try' exHandler $ do 
    undefined
    (inMailbox1, outMailbox1, seal1) <- spawn' Unbounded
    a1 <- async $ writeToMailbox stdout_hdl Right inMailbox1
    a2 <- async $ wait a1 `finally` atomically seal1 
    --a3 <- async $ consumeMailbox outMailbox1 stdoutConsumer 
    b1 <- async $ writeToMailbox stderr_hdl Left inMailbox1
    b2 <- async $ wait b1 `finally` atomically seal1 
    -- Better link the asyncs? --should the asyncs be really canceled? 
    consumeMailbox outMailbox1 combinedReader `finally` (cancel a1 >> cancel b1) 
                                              `finally` (waitBoth a2 b2)

consumeCombined :: StdCombinedConsumer e a
                -- Maybe (Int,ByteString) -- limit the length of lines? Would this be useful?
                -> IOExceptionHandler e
                -> (u,Handle, Handle,v)
                -> (u,ErrorT e IO a,v)
consumeCombined combinedReader exHandler (u, stdout_hdl, stderr_hdl, v) =
    (u, consumeCombined' combinedReader exHandler (stdout_hdl, stderr_hdl), v)

feed' :: Producer ByteString IO a
      -> IOExceptionHandler e
      -> Handle
      -> ErrorT e IO b
      -> ErrorT e IO b 
feed' producer exHandler stdin_hdl action = ErrorT $ try' exHandler $ do
    a1 <- async $ runEffect $ producer >-> toHandle stdin_hdl       
    a2 <- async $ runErrorT action
    r <- wait a2  
    case r of
        Left e -> cancel a1 >> (return $ Left e)
        Right b -> wait a1 >> (return $ Right b)

feed :: Producer ByteString IO a
     -> IOExceptionHandler e
     -> (Handle,ErrorT e IO b,v)
     -> (ErrorT e IO b,v)
feed producer exHandler (stdin_hdl,action,v) =
    (feed' producer exHandler stdin_hdl action, v)

terminateOnError :: (ErrorT e IO a,ProcessHandle)
                 -> ErrorT e IO (a,ExitCode)
terminateOnError (action,pHandle) = ErrorT $ do
    result <- runErrorT action
    case result of
        Left e -> do    
            terminateProcess pHandle  
            return $ Left e
        Right r -> do 
            exitCode <- waitForProcess pHandle 
            return $ Right (r,exitCode)  

example1 =  terminateOnError 
          . feed undefined undefined     
          . consume undefined undefined undefined 
          . noNothingHandles

example2 =  terminateOnError 
          . feed undefined undefined     
          . consumeCombined undefined undefined 
          . noNothingHandles

foo2 :: (Monoid w, Error e) => Consumer ByteString (WriterT w (ErrorT e IO)) () -> StdCombinedConsumer e w
foo2 = combined (either id id) fromConsumer


