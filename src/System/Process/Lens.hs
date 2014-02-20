
-- |
-- This module contains helper functions and types built on top of
-- @System.Process@.
--
-- See the functions 'execute2' and 'execute3' for an entry point.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and folds from
-- "Pipes.Prelude" can be used to consume the output streams of the external
-- processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Lens ( 
        -- * Prisms and lenses
        _cmdspec,
        _ShellCommand,
        _RawCommand,
        _cwd,
        _env,
        stream3,
        pipe3,
        pipe2,
        pipe2h,
        handle3,
        handle2,
    ) where

import Data.Maybe
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
import Control.Monad.Trans.Either
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
import System.Exit

{-|
    > _cmdspec :: Lens' CreateProcess CmdSpec 
-}
_cmdspec :: forall f. Functor f => (CmdSpec -> f CmdSpec) -> CreateProcess -> f CreateProcess 
_cmdspec f c = setCmdSpec c <$> f (cmdspec c)
    where
    setCmdSpec c cmdspec' = c { cmdspec = cmdspec' } 

{-|
    > _ShellCommand :: Prism' CmdSpec String
-}
_ShellCommand :: forall m. Applicative m => (String -> m String) -> CmdSpec -> m CmdSpec 
_ShellCommand f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap ShellCommand (f r)
    where    
    impure (ShellCommand str) = Right str
    impure x = Left x

{-|
    > _RawCommand :: Prism' CmdSpec (FilePath,[String])
-}
_RawCommand :: forall m. Applicative m => ((FilePath,[String]) -> m (FilePath,[String])) -> CmdSpec -> m CmdSpec 
_RawCommand f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
    impure (RawCommand fpath strs) = Right (fpath,strs)
    impure x = Left x
    justify (fpath,strs) = RawCommand fpath strs

{-|
    > _cwd :: Lens' CreateProcess (Maybe FilePath)
-}
_cwd :: forall f. Functor f => (Maybe FilePath -> f (Maybe FilePath)) -> CreateProcess -> f CreateProcess 
_cwd f c = setCwd c <$> f (cwd c)
    where
    setCwd c cwd' = c { cwd = cwd' } 

{-|
    > _env :: Lens' CreateProcess (Maybe [(String,String)])
-}
_env :: forall f. Functor f => (Maybe [(String, String)] -> f (Maybe [(String, String)])) -> CreateProcess -> f CreateProcess 
_env f c = setEnv c <$> f (env c)
    where
    setEnv c env' = c { env = env' } 

{-| 
    A lens for the @(std_in,std_out,std_err)@ triplet.  

    > stream3 :: Lens' CreateProcess (StdStream,StdStream,StdStream)
-}
stream3 :: forall f. Functor f => ((StdStream,StdStream,StdStream) -> f (StdStream,StdStream,StdStream)) -> CreateProcess -> f CreateProcess 
stream3 f c = setStreams c <$> f (getStreams c)
    where 
    getStreams c = (std_in c,std_out c, std_err c)
    setStreams c (s1,s2,s3) = c { std_in  = s1 
                                , std_out = s2 
                                , std_err = s3 
                                } 
{-|
    > pipe3 = (CreatePipe,CreatePipe,CreatePipe)
-} 
pipe3 :: (StdStream,StdStream,StdStream)
pipe3 = (CreatePipe,CreatePipe,CreatePipe)

{-|
    Specifies @CreatePipe@ for @std_out@ and @std_err@; @std_in@ is set to 'Inherit'.

    > pipe3 = (Inherit,CreatePipe,CreatePipe)
 -}
pipe2 :: (StdStream,StdStream,StdStream)
pipe2 = (Inherit,CreatePipe,CreatePipe)

{-|
    Specifies @CreatePipe@ for @std_out@ and @std_err@; @std_in@ is taken as 
parameter. 
 -}
pipe2h :: Handle -> (StdStream,StdStream,StdStream)
pipe2h handle = (UseHandle handle,CreatePipe,CreatePipe)

{-|
    A 'Prism' for the return value of 'createProcess' that removes the 'Maybe's from @stdin@, @stdout@ and @stderr@ or fails to match if any of them is 'Nothing'.

    > handle3 :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> ((Handle, Handle, Handle), ProcessHandle)
 -}
handle3 :: forall m. Applicative m => (((Handle, Handle, Handle), ProcessHandle) -> m ((Handle, Handle, Handle), ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
handle3 f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
    impure (Just h1, Just h2, Just h3, phandle) = Right ((h1, h2, h3), phandle) 
    impure x = Left x
    justify ((h1, h2, h3), phandle) = (Just h1, Just h2, Just h3, phandle)  

{-|
    A 'Prism' for the return value of 'createProcess' that removes the 'Maybe's from @stdout@ and @stderr@ or fails to match if any of them is 'Nothing'.

    > handle2 :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> ((Handle, Handle), ProcessHandle)
 -}
handle2 :: forall m. Applicative m => (((Handle, Handle), ProcessHandle) -> m ((Handle, Handle), ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
handle2 f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
    impure (Nothing, Just h2, Just h3, phandle) = Right ((h2, h3), phandle) 
    impure x = Left x
    justify ((h2, h3), phandle) = (Nothing, Just h2, Just h3, phandle)  

