
-- |
-- Lenses and traversals for 'CreateProcess' and related types.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Lens ( 
         _cmdspec
       , _ShellCommand
       , _RawCommand
       , _cwd
       , _env
       , streams
       , _close_fds
       , _create_group
       , _delegate_ctlc 
       , handles
       , nohandles
       , handleso
       , handlese
       , handlesoe
       , handlesi
       , handlesio
       , handlesie
       , handlesioe
    ) where

import Data.Maybe
import Data.Functor.Identity
import Data.Monoid
import Data.Traversable
import Control.Applicative
import System.IO
import System.Process

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

    > streams :: Lens' CreateProcess (StdStream,StdStream,StdStream)
-}
streams :: forall f. Functor f => ((StdStream,StdStream,StdStream) -> f (StdStream,StdStream,StdStream)) -> CreateProcess -> f CreateProcess 
streams f c = setStreams c <$> f (getStreams c)
    where 
        getStreams c = (std_in c,std_out c, std_err c)
        setStreams c (s1,s2,s3) = c { std_in  = s1 
                                    , std_out = s2 
                                    , std_err = s3 
                                    } 

_close_fds :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_close_fds f c = set_close_fds c <$> f (close_fds c)
    where
    set_close_fds c cwd' = c { close_fds = cwd' } 


_create_group :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_create_group f c = set_create_group c <$> f (create_group c)
    where
    set_create_group c cwd' = c { create_group = cwd' } 

_delegate_ctlc :: forall f. Functor f => (Bool -> f Bool) -> CreateProcess -> f CreateProcess 
_delegate_ctlc f c = set_delegate_ctlc c <$> f (delegate_ctlc c)
    where
    set_delegate_ctlc c cwd' = c { delegate_ctlc = cwd' } 

{-|
    A 'Lens' for the return value of 'createProcess' that focuses on the handles.

    > handles :: Lens' (Maybe Handle, Maybe Handle, Maybe Handle,ProcessHandle) (Maybe Handle, Maybe Handle, Maybe Handle)
 -}
handles :: forall m. Functor m => ((Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)) -> (Maybe Handle,Maybe Handle ,Maybe Handle,ProcessHandle) -> m (Maybe Handle,Maybe Handle ,Maybe Handle,ProcessHandle) 
handles f quad = setHandles quad <$> f (getHandles quad)  
    where
        setHandles (c1'',c2'',c3'',c4'') (c1',c2',c3') = (c1',c2',c3',c4'')
        getHandles (c1'',c2'',c3'',c4'') = (c1'',c2'',c3'')
    

{-|
    A 'Prism' that matches when none of the standard streams have been piped.

    > nohandles :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle) ()
 -}
nohandles :: forall m. Applicative m => (() -> m ()) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
nohandles f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Nothing, Nothing, Nothing) = Right () 
        impure x = Left x
        justify () = (Nothing, Nothing, Nothing)  


{-|
    A 'Prism' that matches when only @stdin@ has been piped.

    > handlesi :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle) (Handle)
 -}
handlesi :: forall m. Applicative m => (Handle -> m Handle) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handlesi f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Just h1, Nothing, Nothing) = Right h1
        impure x = Left x
        justify h1 = (Just h1, Nothing, Nothing)  

handlesio :: forall m. Applicative m => ((Handle,Handle) -> m (Handle,Handle)) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handlesio f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Just h1, Just h2, Nothing) = Right (h1,h2)
        impure x = Left x
        justify (h1,h2) = (Just h1, Just h2, Nothing)  

handlesie :: forall m. Applicative m => ((Handle,Handle) -> m (Handle,Handle)) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handlesie f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Just h1, Nothing, Just h2) = Right (h1,h2)
        impure x = Left x
        justify (h1,h2) = (Just h1, Nothing, Just h2)  

{-|
    A 'Prism' that matches when all three @stdin@, @stdout@ and @stderr@ have been piped.

    > handlesioe :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle) (Handle, Handle, Handle)
 -}
handlesioe :: forall m. Applicative m => ((Handle, Handle, Handle) -> m (Handle, Handle, Handle)) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handlesioe f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Just h1, Just h2, Just h3) = Right (h1, h2, h3) 
        impure x = Left x
        justify (h1, h2, h3) = (Just h1, Just h2, Just h3)  

{-|
    A 'Prism' that matches when only @stdout@ and @stderr@ have been piped.

    > handlesoe :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle) (Handle, Handle)
 -}
handlesoe :: forall m. Applicative m => ((Handle, Handle) -> m (Handle, Handle)) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handlesoe f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Nothing, Just h2, Just h3) = Right (h2, h3) 
        impure x = Left x
        justify (h2, h3) = (Nothing, Just h2, Just h3)  

{-|
    A 'Prism' that matches when only @stdout@ has been piped.

    > handleso :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle) (Handle)
 -}
handleso :: forall m. Applicative m => (Handle -> m Handle) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handleso f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Nothing, Just h2, Nothing) = Right h2
        impure x = Left x
        justify h2 = (Nothing, Just h2, Nothing)  

{-|
    A 'Prism' that matches when only @stderr@ has been piped.

    > handlese :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle) (Handle)
 -}
handlese :: forall m. Applicative m => (Handle -> m Handle) -> (Maybe Handle, Maybe Handle, Maybe Handle) -> m (Maybe Handle, Maybe Handle, Maybe Handle)
handlese f quad = case impure quad of
    Left l -> pure l
    Right r -> fmap justify (f r)
    where    
        impure (Nothing, Nothing, Just h2) = Right h2
        impure x = Left x
        justify h2 = (Nothing, Nothing, Just h2)  
