module System.Process.Streaming ( 
        createProcessE,
        shellPiped,
        procPiped,
        noNothingHandles,
        IOExceptionHandler,
        StdConsumer,
        fromSimpleConsumer,
        fromConsumer,
        consume',
        consume,
        StdCombinedConsumer,
        fromSimpleSingleConsumer,
        fromSingleConsumer,
        consumeCombined',
        consumeCombined,
        feed',
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

fromSimpleConsumer :: Error e => Consumer ByteString IO () -> StdConsumer e () 
fromSimpleConsumer consumer producer = runEffect . hoist lift $ producer >-> consumer

fromConsumer :: (Monoid w, Error e) => Consumer ByteString (WriterT w (ErrorT e IO)) () -> StdConsumer e w
fromConsumer consumer producer = fmap snd $ runEffect . runWriterP $ hoist (lift.lift) producer >-> consumer

consume' :: StdConsumer e a
         -> StdConsumer e b
         -> IOExceptionHandler e
         -> (Handle, Handle) 
         -> ErrorT e IO (a,b)
consume' stdoutConsumer stderrConsumer exHandler (stdout_hdl, stderr_hdl) = ErrorT $ try' exHandler $ do 
    (inMailbox1, outMailbox1, seal1) <- spawn' Unbounded
    a1 <- async $ writeToMailbox stdout_hdl inMailbox1
    a2 <- async $ wait a1 `finally` atomically seal1 
    a3 <- async $ consumeMailbox outMailbox1 stdoutConsumer 
    (inMailbox2, outMailbox2, seal2) <- spawn' Unbounded
    b1 <- async $ writeToMailbox stderr_hdl inMailbox2
    b2 <- async $ wait b1 `finally` atomically seal2 
    b3 <- async $ consumeMailbox outMailbox2 stderrConsumer 
    (_,r) <- waitAny [fmap Right a3,fmap Left b3]
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
    where
    try' :: IOExceptionHandler e -> IO (Either e a) -> IO (Either e a)
    try' handler action = try action >>= either (return . Left . handler) return

    writeToMailbox :: Handle -> Output ByteString -> IO ()
    writeToMailbox handle mailbox = 
         finally (runEffect $ fromHandle handle >-> toOutput mailbox)
                 (hClose handle) 

    consumeMailbox :: Input ByteString -> (Producer ByteString IO () -> ErrorT e IO a) -> IO (Either e a)
    consumeMailbox inMailbox consumer = do
        result <- runErrorT . consumer $ fromInput inMailbox
        case result of 
            Left e -> return $ Left e
            Right r -> do
                runEffect $ fromInput inMailbox >-> P.drain 
                return $ result

consume :: StdConsumer e a
        -> StdConsumer e b
        -> IOExceptionHandler e
        -> (u,Handle, Handle,v)
        -> (u,ErrorT e IO (a,b),v)
consume stdoutReader stderrReader exHandler (u, stdout_hdl, stderr_hdl, v) =
    (u, consume' stdoutReader stderrReader exHandler (stdout_hdl, stderr_hdl), v)

type StdCombinedConsumer e a = Producer (Either ByteString ByteString) IO () -> ErrorT e IO a

fromSimpleSingleConsumer :: Error e => Consumer ByteString IO () 
                                    -> StdCombinedConsumer e () 
fromSimpleSingleConsumer consumer producer =
    fromSimpleConsumer consumer (producer >-> P.map (either id id))

fromSingleConsumer :: (Monoid w, Error e) => Consumer ByteString (WriterT w (ErrorT e IO)) () 
                                          -> StdCombinedConsumer e w
fromSingleConsumer consumer producer = 
    fromConsumer consumer (producer >-> P.map (either id id))

consumeCombined' :: StdCombinedConsumer e a
                 -> IOExceptionHandler e
                 -> (Handle, Handle) 
                 -> ErrorT e IO a
consumeCombined' combinedReader exHandler (stdout_hdl, stderr_hdl)  = 
    undefined

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
feed' producer exHandler stdin_hdl action = undefined

feed :: Producer ByteString IO a
     -> IOExceptionHandler e
     -> (Handle,ErrorT e IO b,v)
     -> (ErrorT e IO b,v)
feed producer exHandler (stdin_hdl,action,v) =
    (feed' producer exHandler stdin_hdl action, v)

terminateOnError :: (ErrorT e IO a,ProcessHandle)
                 -> ErrorT e IO (a,ExitCode)
terminateOnError = undefined

example1 =  terminateOnError 
          . feed undefined undefined     
          . consume undefined undefined undefined 
          . noNothingHandles

example2 =  terminateOnError 
          . feed undefined undefined     
          . consumeCombined undefined undefined 
          . noNothingHandles
