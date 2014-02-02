module System.Process.Streaming ( 
        createProcessE,
        shellPiped,
        procPiped,
        noNothingHandles,
        consume',
        consume,
        consumeCombined',
        consumeCombined,
        feed',
        feed,
        terminateOnError        
    ) where

import Data.Maybe
import Data.Either
import Control.Applicative
import Control.Monad
import Control.Monad.Error
import Control.Exception
import Pipes
import Pipes.Prelude (drain)
import Pipes.ByteString
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

consume' :: (Producer ByteString IO () -> ErrorT e IO a)
         -> (Producer ByteString IO () -> ErrorT e IO b)
         -> IOExceptionHandler e
         -> (Handle, Handle) 
         -> ErrorT e IO (a,b)
consume' stdoutReader stderrReader exHandler (stdout_hdl, stderr_hdl) = 
    undefined
    where
    consumeHandle :: Handle -> (Producer ByteString IO () -> ErrorT e IO a) -> ErrorT e IO a
    consumeHandle handle consumer = ErrorT $ flip finally (hClose handle) $ do
        result <- runErrorT . consumer $ fromHandle handle 
        runEffect $ fromHandle handle >-> drain 
        return $ result

consume :: (Producer ByteString IO () -> ErrorT e IO a) 
        -> (Producer ByteString IO () -> ErrorT e IO b) 
        -> IOExceptionHandler e
        -> (u,Handle, Handle,v)
        -> (u,ErrorT e IO (a,b),v)
consume stdoutReader stderrReader exHandler (u, stdout_hdl, stderr_hdl, v) =
    (u, consume' stdoutReader stderrReader exHandler (stdout_hdl, stderr_hdl), v)

consumeCombined' :: (Producer (Either ByteString ByteString) IO () -> ErrorT e IO a)
                 -> IOExceptionHandler e
                 -> (Handle, Handle) 
                 -> ErrorT e IO a
consumeCombined' combinedReader exHandler (stdout_hdl, stderr_hdl)  = 
    undefined

consumeCombined :: (Producer (Either ByteString ByteString) IO () -> ErrorT e IO a) 
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
