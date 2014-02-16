
-- |
-- This module contains helper functions and types built on top of
-- @System.Process@.
--
-- See the functions 'execute3', 'execute2' and 'executeX' for an entry point.
-- Then read about 'consume' and 'feed' and how to combine the actions
-- concurrently using 'Conc'.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}

module System.Process.Streaming ( 
        -- * Consuming stdout/stderr
        LeftoverPolicy,
        ignoreLeftovers,
        firstFailingBytes,
        leftovers,
        leftovers_,
        LineDecoder,
        decodeLines,
        combinedLines,
        useConsumer,
        -- * Feeding stdin
        useProducer,
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
        -- * Execution helpers
        createProcess',
        terminateOnError,
        executeX,
        execute3,
        execute2,
        execute3cl,
        execute2cl,
        -- * Concurrency helpers
        Conc (..),
        conc,
        conc3,
        mapConc,
        mapConc_,
        ForkProd (..),
        forkProd,
        buffer,
        -- * Other helpers
        surely,
        safely,
        fallibly,
        monoidally,
        exceptionally,
        purge
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

try' :: (IOException -> e) -> IO (Either e a) -> IO (Either e a)
try' handler action = try action >>= either (return . Left . handler) return

mailbox2Handle :: Input ByteString -> Handle -> IO (Either e ())
mailbox2Handle mailbox handle = do
     finally (runEffect $ fromInput mailbox >-> toHandle handle)
             (hClose handle) 
     return $ Right ()

handle2Mailbox :: Handle -> Output ByteString -> IO (Either e ())
handle2Mailbox handle mailbox = do 
     finally (runEffect $ fromHandle handle >-> toOutput mailbox)
             (hClose handle) 
     return $ Right ()

consumeMailbox :: Input b -> (Producer b IO () -> IO (Either e a)) -> IO (Either e a)
consumeMailbox inMailbox consumer = do
    result <- consumer $ fromInput inMailbox
    case result of 
        Left e -> return $ Left e
        Right r -> do
            runEffect $ fromInput inMailbox >-> P.drain 
            return $ result

{-|
    In the Pipes ecosystem, leftovers from decoding operations are often stored
in the result value of 'Producer's (often as 'Producer's themselves). This is a
type synonym for a function that examines these results values, and may fail
depending on what it encounters.
 -}
type LeftoverPolicy  l e = l -> IO (Either e ())


{-|
    Never fails for any leftover.
 -}
ignoreLeftovers :: LeftoverPolicy l e 
ignoreLeftovers =  const (liftIO . return $ Right ()) 

{-|
    For 'ByteString' leftovers, fails if it encounters any leftover and
constructs the error out of the first undedcoded bytes. 
 -}
firstFailingBytes :: (ByteString -> e) -> LeftoverPolicy (Producer ByteString IO ()) e 
firstFailingBytes errh remainingBytes = do
    runEitherT . runEffect $ hoist lift remainingBytes >-> (await >>= lift . left . errh)

{-|
    'Producers' that represent the results of decoding operations store
leftovers in their result values. But many functions in this module
('useConsumer', 'forkProd', and others) work only with 'Producer's that return
@()@. The 'leftover' function augments these functions with a 'LeftoverPolicy'
and lets them work with the result of a decoding. 

    It may happen that the argument function returns successfully but leftovers
exist, indicating a decoding failure. The first argument of 'leftover' lets you
store the results in the message error.
 -}
leftovers :: (Show e, Typeable e)
         => (e' -> x -> e) 
         -> LeftoverPolicy l e' 
         -> (Producer b IO () -> IO (Either e x))
         -> Producer b IO l -> IO (Either e x)
leftovers errWrapper policy activity producer = revealError $ do
    (Output outbox,inbox,seal) <- spawn' Unbounded
    feeding <- async $ runEffect $ 
        producer >-> (P.mapM $ atomically . outbox) >-> P.drain
    sealing <- async $ wait feeding <* atomically seal
    result <- elideError $ activity $ fromInput inbox 
    leftovers <- wait sealing >>= policy
    case leftovers of
        Left e' -> elideError . return . Left $ errWrapper e' result   
        Right () -> return result

leftovers_ :: (Show e, Typeable e)
           => LeftoverPolicy l e 
           -> (Producer b IO () -> IO (Either e x))
           -> Producer b IO l -> IO (Either e x)
leftovers_ = leftovers const

{-|
  Type synonym for a function that takes a 'ByteString' producer, decodes it
into 'T.Text', and returns a streamed effectful list of line producers. See the
@pipes-group@ package for utilities on how to manipulate these streamed
effectful lists. They allow you to handle individual lines without forcing you
to have a whole line in memory at any given time.

    The final @Producer ByteString IO ()@ return value holds the bytes
following the first decoding error. If there are no decoding errors, it will be
an empty producer.
 -} 
 
type LineDecoder = Producer ByteString IO () -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ())

{-|
    Constructs a 'LineDecoder'.

    The first argument is a function function that decodes 'ByteString' into
'T.Text'. See the section /Decoding Functions/ in the documentation for the
"Pipes.Text" module.  

    The second argument is a function that modifies each individual line. The
line is represented as a 'Producer' to avoid having to keep it wholly in
memory. If you want the lines unmodified, just pass @id@. Line prefixes are
easy to add using applicative notation:

  > decodeLines utf8 (\x -> yield "prefix: " *> x)
 -}
decodeLines :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
            -> (forall r. Producer T.Text IO r -> Producer T.Text IO r) 
            -> LineDecoder
decodeLines decoder transform =  transFreeT transform 
                               . viewLines 
                               . decoder
    where 
    viewLines = getConst . T.lines Const

writeLines :: MVar (Output T.Text) 
           -> LeftoverPolicy (Producer ByteString IO ()) e
           -> FreeT (Producer T.Text IO) IO (Producer ByteString IO ())
           -> IO (Either e ())
writeLines mvar errh freeTLines = iterTLines freeTLines >>= errh
    where
    iterTLines :: forall x. FreeT (Producer T.Text IO) IO x -> IO x
    iterTLines = iterT $ \textProducer -> do
        -- the P.drain bit was difficult to figure out!!!
        join $ withMVar mvar $ \output -> do
            runEffect $ (textProducer <* P.yield (singleton '\n')) >-> (toOutput output >> P.drain)

{-| 
    This function reads bytes from a lists of file handles, converts them into
text, splits each text stream into lines (possibly modifying the lines in the
process) and writes all lines to a single stream, concurrently. The combined
stream is publishes as a 'Producer', which is them passed to a function that
does something with it. 

   'consumeCombinedLines' is typically used to consume @stdout@ and @stderr@
together.

   The first arguent is an error callback. 

   A 'LineDecoder' and a 'LeftoverPolicy' must be specified for each handle.

    /Beware!/ 'consumeCombinedLines' avoids situations in which a line emitted
in @stderr@ cuts a long line emitted in @stdout@, see
<http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines
here> for a description of the problem.  To avoid this, the combined text
stream is locked while writing each individual line. But this means that if the
external program stops writing to a handle /while in the middle of a line/,
lines coming from the other handles won't be printed, either!

   'consumeCombinedLines' behaves like 'consume' in respect to early
termination and draining of leftover data in the handles. 
 -}

combinedLines :: (Show e, Typeable e) 
              => [(Producer ByteString IO (), LineDecoder, LeftoverPolicy (Producer ByteString IO ()) e)]
        	  -> (Producer T.Text IO () -> IO (Either e a))
        	  -> IO (Either e a) 
combinedLines actions producer = do
    (outbox, inbox, seal) <- spawn' Unbounded
    mVar <- newMVar outbox
    r <- runConc $ (,) <$> Conc (finally (mapConc (consume' mVar) actions) 
                                         (atomically seal)
                                )
                       <*> Conc (finally (consumeMailbox inbox producer)
                                         (atomically seal)
                                )
    return $ snd <$> r
    where 
    consume' mVar (producer,lineDec,leftoverp) = 
        (buffer $ writeLines mVar leftoverp . lineDec) producer 

{-|
    Builds a function that will be plugged into 'consume' or 'consumeCombinedLines' out of a 'Producer'.

    You may need to use 'surely' for the types to fit.

   >  useProducer producer consumer = runEffect (producer >-> consumer) 
 -}

useConsumer :: Monad m => Consumer b m () -> Producer b m () -> m ()
useConsumer consumer producer = runEffect $ producer >-> consumer 

{-|
    Builds a function that will be plugged into 'feed' out of a 'Producer'.

    You may need to use 'surely' for the types to fit.

   >  useProducer producer consumer = runEffect (producer >-> consumer) 
 -}
useProducer :: Monad m => Producer b m () -> Consumer b m () -> m ()
useProducer producer consumer = runEffect (producer >-> consumer) 

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

{-|
    Exactly like 'createProcess' but uses 'Either' instead of throwing 'IOExceptions'.

    > createProcessE = try . createProcess
 -}
createProcess' :: CreateProcess 
               -> IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
createProcess' = try . createProcess


{-|
    Terminate the external process is the computation fails, otherwise return
the 'ExitCode' alongside the result. 
 -}
terminateOnError :: ProcessHandle 
                 -> IO (Either e a)
                 -> IO (Either e (ExitCode,a))
terminateOnError pHandle action = do
    result <- action
    case result of
        Left e -> do    
            mExitCode <- getProcessExitCode pHandle   
            case mExitCode of 
                Nothing -> do 
                    terminateProcess pHandle  
                Just _ -> return ()
            return $ Left e
        Right r -> do 
            exitCode <- waitForProcess pHandle 
            return $ Right (exitCode,r)  

{-|
    > executeX :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) (t, ProcessHandle) -> e -> (IOException -> e) -> CreateProcess -> (t -> IO (Either e a)) -> IO (Either e (ExitCode,a))

    Convenience function that launches the external process, does stuff with
its standard streams, and returns the 'ExitCode' upon completion alongside the
results. 

   The first argument is 'Prism' that matches against the tuple returned by
'createProcess' and removes the 'Maybe's that wrap the 'Handle's. 

   The second argument is the error value for when one of the 'Handles' is unexpectedly 'Nothing'.

   The third argument is an error callback for exceptions thrown when launching
the process, or while waiting for it to complete.  

   The fourth argument is a computation that depends of what the prism matches
(some subset of the handles) and may fail with error @e@. The computation is
often constructed using the 'Applicative' instance of 'Conc' and functions
like 'consume', 'consumeCombinedLines' and 'feed'.

   If an exception is thrown while this function executes, the
external process is terminated. 
 -}
executeX :: ((forall m. Applicative m => ((t, ProcessHandle) -> m (t, ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))) -> CreateProcess -> (IOException -> e) -> ((forall z. IO z -> IO z) -> t -> IO (Either e a)) -> IO (Either e (ExitCode,a))
executeX somePrism procSpec exHandler action = mask $ \restore -> runEitherT $ do
    maybeHtuple <- bimapEitherT exHandler id $ EitherT $ createProcess' procSpec  
    case getFirst . getConst . somePrism (Const . First . Just) $ maybeHtuple of
        Nothing -> left $ exHandler $ userError "stdin/stdout/stderr handle unexpectedly null" 
        Just (htuple,phandle) -> do
            EitherT $ try' exHandler $ 
                (terminateOnError phandle $ action restore htuple)
                `onException`
                terminateProcess phandle -- pending -- terminate even on prism failure                           

{-|
    When we want to work with @stdin@, @stdout@ and @stderr@.

    > execute3 = executeX handle3
 -}
execute3 :: (Show e, Typeable e)
         => CreateProcess 
         -> (IOException -> e)
         -> (Consumer ByteString IO () -> IO (Either e a))
         -> (Producer ByteString IO () -> IO (Either e b))
         -> (Producer ByteString IO () -> IO (Either e c))
         -> IO (Either e (ExitCode,(a,b,c)))
execute3 spec ehandler feeder consumout consumerr = do
    executeX handle3 spec' ehandler $ \unmask (hin,hout,herr) ->
        (unmask $ try' ehandler $ -- maybe repeat this for each job, with annotations 
             conc3 ((feeder $ toHandle hin) `finally` hClose hin)
                   ((buffer consumout $ fromHandle hout) `finally` hClose hout)
                   ((buffer consumerr $ fromHandle herr)`finally` hClose herr))
        `finally` hClose hin
        `finally` hClose hout
        `finally` hClose herr
    where 
    spec' = spec { std_in = CreatePipe
                 , std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

{-|
    When we only want to work with @stdout@ and @stderr@.

    > execute2 = executeX handle2
 -}
execute2 :: (Show e, Typeable e) 
         => CreateProcess 
         -> (IOException -> e)
         -> (Producer ByteString IO () -> IO (Either e a))
         -> (Producer ByteString IO () -> IO (Either e b))
         -> IO (Either e (ExitCode,(a,b)))
execute2 spec ehandler consumout consumerr = do
    executeX handle2 spec' ehandler $ \unmask (hout,herr) ->
        (unmask $ try' ehandler $ -- maybe repeat this for each job, with annotations 
            conc ((buffer consumout $ fromHandle hout) `finally` hClose hout)
                 ((buffer consumerr $ fromHandle herr) `finally` hClose herr))
        `finally` hClose hout
        `finally` hClose herr
    where 
    spec' = spec { std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

execute3cl :: (Show e, Typeable e) 
           => CreateProcess 
           -> (IOException -> e)
           -> (Consumer ByteString IO () -> IO (Either e a))
           -> LineDecoder
           -> LeftoverPolicy (Producer ByteString IO ()) e
           -> LineDecoder
           -> LeftoverPolicy (Producer ByteString IO ()) e
           -> (Producer T.Text IO () -> IO (Either e b))
           -> IO (Either e (ExitCode,(a,b)))
execute3cl spec ehandler feeder ld1 lop1 ld2 lop2 combinedConsumer = 
    executeX handle3 spec' ehandler $ \unmask (hin,hout,herr) -> 
        (unmask $ try' ehandler $ 
            conc (feeder (toHandle hin) 
                  `finally` hClose hin)
                 (combinedLines [ (fromHandle hout,ld1,lop1)
                                , (fromHandle herr,ld2,lop2)
                                ]
                                combinedConsumer 
                  `finally` hClose hout 
                  `finally` hClose herr)
        `finally` hClose hin
        `finally` hClose hout
        `finally` hClose herr)
    where
    spec' = spec { std_in = CreatePipe
                 , std_out = CreatePipe
                 , std_err = CreatePipe
                 } 

execute2cl :: (Show e, Typeable e) 
           => CreateProcess 
           -> (IOException -> e)
           -> LineDecoder
           -> LeftoverPolicy (Producer ByteString IO ()) e
           -> LineDecoder
           -> LeftoverPolicy (Producer ByteString IO ()) e
           -> (Producer T.Text IO () -> IO (Either e a))
           -> IO (Either e (ExitCode,a))

execute2cl spec ehandler ld1 lop1 ld2 lop2 combinedConsumer = do
    executeX handle2 spec' ehandler $ \unmask (hout,herr) -> 
        (unmask $ try' ehandler $ 
            combinedLines [(fromHandle hout,ld1,lop1),
                           (fromHandle herr,ld2,lop2)]
                          combinedConsumer)
        `finally` hClose hout
        `finally` hClose herr
    where 
    spec' = spec { std_out = CreatePipe
                 , std_err = CreatePipe
                 } 
data WrappedError e = WrappedError e
    deriving (Show, Typeable)

instance (Show e, Typeable e) => Exception (WrappedError e)

elideError :: (Show e, Typeable e) => IO (Either e a) -> IO a
elideError action = action >>= either (throwIO . WrappedError) return

revealError :: (Show e, Typeable e) => IO a -> IO (Either e a)  
revealError action = catch (action >>= return . Right)
                           (\(WrappedError e) -> return . Left $ e)   

{-| 
    'Conc' is very similar to 'Control.Concurrent.Async.Concurrently' from the
@async@ package, but it has an explicit error type @e@.

    The 'Applicative' instance is used to run actions concurrently and combine their results. 

   If any of the actions fails with @e@ the other actions are immediately
cancelled and the whole computation fails with @e@. 

    'Conc' and its accompanying functions are useful to run concurrently the
actions that work over each handle (actions defined using functions like 'consume',
'consumeCombinedLines' and 'feed').
-}
newtype Conc e a = Conc { runConc :: IO (Either e a) }

instance Functor (Conc e) where
  fmap f (Conc x) = Conc $ fmap (fmap f) x

instance (Show e, Typeable e) => Applicative (Conc e) where
  pure = Conc . pure . pure
  Conc fs <*> Conc as =
    Conc . revealError $ 
        uncurry ($) <$> concurrently (elideError fs) (elideError as)

instance (Show e, Typeable e) => Alternative (Conc e) where
  empty = Conc $ forever (threadDelay maxBound)
  Conc as <|> Conc bs =
    Conc $ either id id <$> race as bs

conc :: (Show e, Typeable e) 
     => IO (Either e a)
     -> IO (Either e b)
     -> IO (Either e (a,b))
conc c1 c2 = runConc $ (,) <$> Conc c1
                           <*> Conc c2

conc3 :: (Show e, Typeable e) 
      => IO (Either e a)
      -> IO (Either e b)
      -> IO (Either e c)
      -> IO (Either e (a,b,c))
conc3 c1 c2 c3 = runConc $ (,,) <$> Conc c1
                                <*> Conc c2
                                <*> Conc c3

{-| 
      Works similarly to 'Control.Concurrent.Async.mapConcurrently' from the
@async@ package, but if any of the computations fails with @e@, the others are
immediately cancelled and the whole computation fails with @e@. 
 -}
mapConc :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConc f = revealError .  mapConcurrently (elideError . f)

mapConc_ :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e ())
mapConc_ f l = fmap (const ()) <$> mapConc f l

{-| 
    'ForkProd' is a newtype around a function that does something with a
'Producer'. The applicative instance fuses these functions, so that each one
receives its own copy of the 'Producer' and runs concurrently with the others.
Like with 'Conc', if any of the functions fails with @e@ the others are
immediately cancelled and the whole computation fails with @e@.   

    'ForkProd' and its accompanying functions are useful to run multiple
parsers from "Pipes.Parse" in parallel over the same 'Producer'.
 -}
newtype ForkProd b e a = ForkProd { runForkProd :: Producer b IO () -> IO (Either e a) }

instance Functor (ForkProd b e) where
  fmap f (ForkProd x) = ForkProd $ fmap (fmap (fmap f)) x

instance (Show e, Typeable e) => Applicative (ForkProd b e) where
  pure = ForkProd . pure . pure . pure
  ForkProd fs <*> ForkProd as = 
      ForkProd $ \producer -> revealError $ do
          (Output outbox1,inbox1,seal1) <- spawn' Unbounded
          (Output outbox2,inbox2,seal2) <- spawn' Unbounded
          --let (Output combined) = outbox1 <> outbox2
          feeding <- async $ runEffect $ 
              producer >-> (P.mapM $ \v -> do atomically $ outbox1 v
                                              atomically $ outbox2 v)
                       >-> P.drain
          sealing <- async $ wait feeding >> atomically seal1 >> atomically seal2
          r <- uncurry ($) <$> concurrently (elideError $ fs $ fromInput inbox1) 
                                            (elideError $ as $ fromInput inbox2)
          wait sealing
          return r

forkProd :: (Show e, Typeable e) 
         => (Producer b IO () -> IO (Either e x))
         -> (Producer b IO () -> IO (Either e y))
         -> (Producer b IO () -> IO (Either e (x,y)))
forkProd c1 c2 = runForkProd $ (,) <$> ForkProd c1
                                   <*> ForkProd c2


{-|
    This function consumes the @stdout@ or @stderr@ of an external process,
with buffering.    

    It takes as arguments an exception handler, a file 'Handle', and a
function that does something with a 'Producer'. The 'Producer' publishes the
data form the 'Handle'.
  
    The argument function can incur in delays without risking deadlocks in the
external process caused by full output buffers, because data is constantly read
and stored in an intermediate buffer until it is consumed. 

    If the argument function returns with vale @a@, 'consume' /keeps draining/
the 'Handle' until it is closed by the external process, and /only then/
returns the @a@. If the argument function fails with @e@, 'consume' returns
immediately. So failing with @e@ is a good way to interrupt a process.  

    Arguments functions pluggable into 'consume' can be constructed with the
'useConsumer' function. They can also be constructed out of parses from
"Pipes.Parse" by running 'evalStateT' on the parser. A third way of
constructing them is using the folds defined in module 'Pipes.Prelude'.
 -}
buffer :: (Show e, Typeable e) 
       => (Producer ByteString IO () -> IO (Either e a))
       -> (Producer ByteString IO () -> IO (Either e a))
buffer f producer = do 
    (outbox, inbox, seal) <- spawn' Unbounded
    r <- conc (do a <- async $ handle2Mailbox outbox
                  wait a `finally` atomically seal)
              (consumeMailbox inbox f `finally` atomically seal) 
    return $ snd <$> r
    where
    handle2Mailbox :: Output ByteString -> IO (Either e ())
    handle2Mailbox mailbox = do 
         runEffect $ producer >-> toOutput mailbox
         return $ Right ()


{-| 
  Useful when you want to plug into 'consume' a function that doesn't return an
  'Either'. For example folds from "Pipes.Prelude", or functions created from simple
  'Consumer's with 'useConsumer'. 

  > surely = fmap (fmap Right)
 -}
surely :: (Functor f, Functor f') => f (f' a) -> f (f' (Either e a))
surely = fmap (fmap Right)


{-| 
  Useful when you want to plug into 'consume' a function that does its work in
the 'SafeT' transformer.
 -}
safely :: (MFunctor t, C.MonadCatch m, MonadIO m) 
       => (t (SafeT m) l -> (SafeT m) x) 
       -> (t m l -> m x) 
safely activity = runSafeT . activity . hoist lift 

fallibly :: (MFunctor t, Monad m, Error e) 
         => (t (ErrorT e m) l -> (ErrorT e m) x) 
         -> (t m l -> m (Either e x)) 
fallibly activity = runErrorT . activity . hoist lift 

{-|
  Usually, it is better to use a fold form "Pipes.Prelude" instead of this
function.  But this function has the ability to return the monoidal result
accumulated up until the error happened. 

 The first argument is a function that combines the initial error with the
monoidal result to build the definitive error value. If you want to discard the
results, use 'const' as the first argument.  
 -}
monoidally :: (MFunctor t,Monad m,Monoid w, Error e') 
           => (e' -> w -> e) 
           -> (t (ErrorT e' (WriterT w m)) l -> ErrorT e' (WriterT w m) ())
           -> (t m l -> m (Either e w))
monoidally errh activity proxy = do
    (r,w) <- runWriterT . runErrorT . activity . hoist (lift.lift) $ proxy
    return $ case r of
        Left e' -> Left $ errh e' w    
        Right () -> Right $ w

exceptionally :: (IOException -> e) 
              -> (x -> IO (Either e a))
              -> (x -> IO (Either e a)) 
exceptionally handler operation x = try' handler (operation x) 

purge :: Producer b IO () -> IO (Either e ())
purge = surely . useConsumer $ P.drain

