
-- |
-- Lenses and traversals for 'CreateProcess' and related types.
--
-- These are provided as a convenience and aren't at all required to use the
-- other modules of this package.
--
-----------------------------------------------------------------------------

{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE CPP #-}

module System.Process.Lens ( 
         _cmdspec
       , _ShellCommand
       , _RawCommand
       , _cwd
       , _env
       , std_streams
       , _std_in
       , _std_out
       , _std_err
       , _close_fds
       , _create_group
       , _delegate_ctlc 
#if MIN_VERSION_process(1,3,0)
       , _detach_console 
       , _create_new_console 
       , _new_session 
#endif
    ) where

import Control.Applicative
import System.Process

{-|
    > _cmdspec :: Lens' CreateProcess CmdSpec 
-}
_cmdspec :: forall f. Functor f => (CmdSpec -> f CmdSpec) -> CreateProcess -> f CreateProcess 
_cmdspec f x = setCmdSpec x <$> f (cmdspec x)
    where
    setCmdSpec c cmdspec' = c { cmdspec = cmdspec' } 

{-|
    > _ShellCommand :: Traversal' CmdSpec String
-}
_ShellCommand :: forall m. Applicative m => (String -> m String) -> CmdSpec -> m CmdSpec 
_ShellCommand f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap ShellCommand (f r)
    where    
    impure (ShellCommand str) = Right str
    impure x = Left x

{-|
    > _RawCommand :: Traversal' CmdSpec (FilePath,[String])
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
_cwd f x = setCwd x <$> f (cwd x)
    where
    setCwd c cwd' = c { cwd = cwd' } 

{-|
    > _env :: Lens' CreateProcess (Maybe [(String,String)])
-}
_env :: forall f. Functor f => (Maybe [(String, String)] -> f (Maybe [(String, String)])) -> CreateProcess -> f CreateProcess 
_env f x = setEnv x <$> f (env x)
    where
    setEnv c env' = c { env = env' } 

{-| 
    A lens for the @(std_in,std_out,std_err)@ triplet.  

    > std_streams :: Lens' CreateProcess (StdStream,StdStream,StdStream)
-}
std_streams :: forall f. Functor f => ((StdStream,StdStream,StdStream) -> f (StdStream,StdStream,StdStream)) -> CreateProcess -> f CreateProcess 
std_streams f x = setStreams x <$> f (getStreams x)
    where 
        getStreams c = (std_in c,std_out c, std_err c)
        setStreams c (s1,s2,s3) = c { std_in  = s1 
                                    , std_out = s2 
                                    , std_err = s3 
                                    } 

_std_in :: forall f. Functor f => (StdStream -> f (StdStream)) -> CreateProcess -> f CreateProcess 
_std_in f x = setStreams x <$> f (getStreams x)
    where 
        getStreams c = std_in c
        setStreams c s1 = c { std_in  = s1 } 

_std_out :: forall f. Functor f => (StdStream -> f (StdStream)) -> CreateProcess -> f CreateProcess 
_std_out f x = setStreams x <$> f (getStreams x)
    where 
        getStreams c = std_out c
        setStreams c s1 = c { std_out  = s1 } 

_std_err :: forall f. Functor f => (StdStream -> f (StdStream)) -> CreateProcess -> f CreateProcess 
_std_err f x = setStreams x <$> f (getStreams x)
    where 
        getStreams c = std_err c
        setStreams c s1 = c { std_err = s1 } 

_close_fds :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_close_fds f x = set_close_fds x <$> f (close_fds x)
    where
    set_close_fds c v = c { close_fds = v } 


_create_group :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_create_group f x = set_create_group x <$> f (create_group x)
    where
    set_create_group c v = c { create_group = v } 

_delegate_ctlc :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_delegate_ctlc f x = set_delegate_ctlc x <$> f (delegate_ctlc x)
    where
    set_delegate_ctlc c v = c { delegate_ctlc = v } 

#if MIN_VERSION_process(1,3,0)
_detach_console :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_detach_console f x = set_detach_console x <$> f (detach_console x)
    where
    set_detach_console c v = c { detach_console = v } 

_create_new_console :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_create_new_console f x = set_create_new_console x <$> f (create_new_console x)
    where
    set_create_new_console c v = c { create_new_console = v } 

_new_session :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_new_session f x = set_new_session x <$> f (new_session x)
    where
    set_new_session c v = c { new_session = v } 
#endif

