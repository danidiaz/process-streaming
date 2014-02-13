
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
        consume,
        LineDecoder,
        decodeLines,
        decodeLines',
        LeftoverPolicy,
        LeftoverPolicy',
        ignoreLeftovers,
        firstFailingBytes,
        consumeCombinedLines,
        useConsumer,
        useConsumer',
        -- * Feeding stdin
        feed,
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
        createProcessE,
        terminateOnError,
        executeX,
        execute3,
        execute2,
        -- * Concurrency helpers
        Conc (..),
        conc,
        conc3,
        mapConc,
        mapConc_,
        ConcProd (..),
        concProd,
        -- * Other helpers
        safely,
        fallibly,
        monoidally,
        monoifably,
        righteously
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

{-|
    Type synonym for a function that takes a 'Producer', does something with
it, and returns a result @a@ or an error @e@. 

    Notice that, even if this package doesn't depend on @pipes-parse@, you can
convert a @Parser b IO (Either e a)@ to a @Consumption b e a@ by using
'evalStateT'. 
 -}

{-|
    This function consumes the @stdout@ or @stderr@ of an external process,
with buffering.    

    It takes an exception handler, a file 'Handle', and a 'Consumption'
function (type synonym shown expanded) as parameters. Data is read from the
handle and published as a 'Producer', which is then passed to the 'Consumption'
function. 
  
    The 'Consumption' function can incur in delays without risking deadlocks in
the external process caused by full output buffers, because data is constantly
read and stored in an intermediate buffer until it is consumed. 

    If the 'Consumption' returns with vale @a@, 'consume' /keeps draining/ the
'Handle' until it is closed by the external process, and /only then/ returns
the @a@. If the 'Consumption' fails with @e@, 'consume' returns immediately. So
failing with @e@ is a good way to interrupt a process.  
 -}
consume :: (IOException -> e) 
        -> Handle 
        -> (Producer ByteString IO () -> IO (Either e a))
        -> IO (Either e a) 
consume exHandler h c = try' exHandler $ do 
    (outbox, inbox, seal) <- spawn' Unbounded
    snd <$> concurrently  (do a <- async $ handle2Mailbox h outbox
                              wait a `finally` atomically seal)
                          (consumeMailbox inbox c) 

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
    Construct a 'LineDecoder' from a 'T.Codec' and a function that modifies
each individual line.

    If you want the lines unmodified, just pass @id@. Line prefixes are easy to
add using applicative notation:

  > decodeLines utf8 (\x -> yield "prefix: " *> x)

    The modifier function could also be used to add timestamps.
 -}
decodeLines :: (forall r. Producer ByteString IO r -> Producer T.Text IO (Producer ByteString IO r)) 
            -> (forall r. Producer T.Text IO r -> Producer T.Text IO r) 
            -> LineDecoder
decodeLines decoder transform =  transFreeT transform 
                               . viewLines 
                               . decoder
    where 
    viewLines = getConst . T.lines Const

decodeLines' :: T.Codec
             -> (forall r. Producer T.Text IO r -> Producer T.Text IO r) 
             -> LineDecoder
decodeLines' aCodec = decodeLines decoder 
    where 
    decoder = getConst . T.codec aCodec Const

type LeftoverPolicy l e = forall m. MonadIO m => l -> m (Either e ())

type LeftoverPolicy'  l e = l -> IO (Either e ())

ignoreLeftovers :: LeftoverPolicy l e 
ignoreLeftovers =  const (liftIO . return $ Right ()) 

firstFailingBytes :: (ByteString -> e) -> LeftoverPolicy (Producer ByteString IO ()) e 
firstFailingBytes errh remainingBytes = do
    liftIO $ runEitherT . runEffect $ hoist lift remainingBytes >-> (await >>= lift . left . errh)


writeLines :: MVar (Output T.Text) 
           -> LeftoverPolicy' (Producer ByteString IO ()) e
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
text, splits each text stream into lines (possibly modifying the lines in the process) and
writes all lines to a single stream, concurrently. The combined stream is publishes as a 'Producer', which
is passed to a 'Consumption' function (type synonym shown expanded). 

   'consumeCombinedLines' is typically used to consume @stdout@ and @stderr@ together.

   It takes two error callbacks: one for 'IOException's, and another for decoding errors (the 'ByteString' passed to the callback contains the first bytes that could't be decoded).  

    /Beware!/ 'consumeCombinedLines' avoids situations in which a line
emitted in @stderr@ cuts a long line emitted in @stdout@, see <http://unix.stackexchange.com/questions/114182/can-redirecting-stdout-and-stderr-to-the-same-file-mangle-lines here> for a description of the problem. 
To avoid this, the combined text stream is
locked while writing each individual line. But this means that if the external
program stops writing to a handle /while in the middle of a line/, lines from the
other handles won't be consumed, either!

   'consumeCombinedLines' behaves like 'consume' in respect to early termination and draining of leftover data in the handles. 
 -}
consumeCombinedLines :: (Show e, Typeable e) 
                     => (IOException -> e) 
                     -> [(Handle, LineDecoder, LeftoverPolicy' (Producer ByteString IO ()) e)]
        			 -> (Producer T.Text IO () -> IO (Either e a))
        		     -> IO (Either e a) 
consumeCombinedLines exHandler actions c = try' exHandler $ do
    (outbox, inbox, seal) <- spawn' Unbounded
    mVar <- newMVar outbox
    r <- runConc $ (,) <$> Conc (finally (mapConc (consume' mVar) actions) 
                                           (atomically seal)
                                  )
                        <*> Conc (consumeMailbox inbox c)
    return $ snd <$> r
    where 
    consume' mVar (h,lineDec,leftoverp) = consume exHandler h $ 
        writeLines mVar leftoverp . lineDec 



{-|
    Constructs a 'Consumption' from a 'Consumer'. If basically combines the
'Producer' and the 'Consumer' in a pipeline and runs it.
 -}
useConsumer :: MonadIO m 
            => LeftoverPolicy l e 
            -> Consumer b m l 
            -> Producer b m l -> m (Either e ())
useConsumer policy consumer producer = do
    leftovers <- runEffect $ producer >-> consumer 
    policy leftovers 

useConsumer' :: MonadIO m       
             => Consumer b m l 
             -> Producer b m l -> m (Either e ())
useConsumer' = useConsumer ignoreLeftovers

--useSafeConsumer :: Consumer b (SafeT IO) l -> Consumption b l e ()
--useSafeConsumer consumer producer = Right <$> (runSafeT $ runEffect $ hoist lift producer >-> consumer)
--
--{-|
--    Constructs a 'Consumption' from a 'Consumer' that may fail with @e@.
-- -}
--useConsumerE :: Error e => Consumer b (ErrorT e IO) l -> Consumption b l e ()
--useConsumerE consumer producer = runEffect $ runErrorP $ hoist lift producer >-> consumer
--
--{-|
--    Constructs a 'Consumption' from a 'Consumer' that may fail with @e'@ and
--that keeps a monoidal summary @w@ of the consumed data. If the consumer fails
--with @e'@, a failure @e@ is constructed by combining @e'@ and the values
--accumulated up until the error, so that @e@ may include them if the user
--wishes. To ignore them, it is enough to pass 'const' as the first argument. 
-- -}
--useConsumerW :: (Monoid w, Error e') => (w -> e' -> e) -> Consumer b (ErrorT e' (WriterT w IO)) l -> Consumption b l e w 
--useConsumerW resultsUntilError consumer producer = do
--    (r,w) <- runEffect $ runWriterP $ runErrorP $ hoist (lift.lift) producer >-> consumer 
--    case r of
--        Left e' -> return $ Left $ resultsUntilError w e'    
--        Right () -> return $ Right w
--
--useSafeConsumerW :: Monoid w => Consumer b (WriterT w (SafeT IO)) l -> Consumption b l e w 
--useSafeConsumerW consumer producer = do
--    (_,w) <- runSafeT $ runEffect $ runWriterP $ hoist (lift.lift) producer >-> consumer
--    return $ Right w
--

{-|
    This function feeds the stdin of an external process, with buffering.

    It takes an exception handler, a file 'Handle', and a 'Feeding' function (type synonym shown expanded) as parameters. Data is produced and received by the 'Consumer', that writes it to the 'Handler'.

    The 'Feeding' function need not worry about delays caused by the slowness of the external process in reading the data, because the supplied data is buffered and written to the 'Handle' in a separate thread.

    If the 'Feeding' fails with @e@, 'feed' returns immediately. So failing with @e@ is a good way to interrupt a process.
 -}
feed :: (IOException -> e)
     -> Handle 
     -> (Consumer ByteString IO () -> IO (Either e a))
     -> IO (Either e a) 
feed exHandler h c = try' exHandler $ do 
    (outbox, inbox, seal) <- spawn' Unbounded
    fst <$> concurrently (do a <- async $ feedMailbox c outbox
                             wait a `finally` atomically seal) 
                         (mailbox2Handle inbox h)

{-|
    Constructs a 'Feeding' from a 'Producer'. If basically combines the
'Producer' and the 'Consumer' in a pipeline and runs it.
 -}
useProducer :: MonadIO m 
            => Producer b m () 
            -> Consumer b m () -> m (Either e ())
useProducer producer consumer = Right `liftM` runEffect (producer >-> consumer) 


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
    Specifies @CreatePipe@ for @std_out@ and @std_err@; @std_in@ is taken as 
parameter. 
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
createProcessE :: CreateProcess 
               -> IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
createProcessE = try . createProcess


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
            terminateProcess pHandle  
            return $ Left e
        Right r -> do 
            exitCode <- waitForProcess pHandle 
            return $ Right (exitCode,r)  

{-|
    > executeX :: Prism' (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) (t, ProcessHandle) -> CreateProcess -> (IOException -> e) -> (t -> IO (Either e a)) -> IO (Either e (ExitCode,a))

    Convenience function that launches the external process, does stuff with
its standard streams, and returns the 'ExitCode' upon completion alongside the
results. 

   The first argument is 'Prism' that matches against the tuple returned by
'createProcess'. If the prism fails to match, an 'error' is raised. 

   The second argument is an error callback for exceptions thrown when launching
the process, or while waiting for it to complete.  

   The fourth argument is a computation that depends of what the prism matches
(some subset of the handles) and may fail with error @e@. The compuation is
often constructed using the 'Applicative' instance of 'Conc' and functions
like 'consume', 'consumeCombinedLines' and 'feed'.

   If an asynchronous exception is thrown while this function executes, the
external process is terminated. 
 -}
executeX :: ((forall m. Applicative m => ((t, ProcessHandle) -> m (t, ProcessHandle)) -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))) -> e -> (IOException -> e) -> CreateProcess -> (t -> IO (Either e a)) -> IO (Either e (ExitCode,a))
executeX somePrism nomatch exHandler procSpec action = mask $ \restore -> runEitherT $ do
    maybeHtuple <- bimapEitherT exHandler id $ EitherT $ createProcessE procSpec  
    case getFirst . getConst . somePrism (Const . First . Just) $ maybeHtuple of
        Nothing -> left nomatch 
        Just (htuple,phandle) -> do
            EitherT $ try' exHandler $ 
                restore (terminateOnError phandle $ action htuple)
                `onException`
                terminateProcess phandle                            

{-|
    When we want to work with @stdin@, @stdout@ and @stderr@.

    > execute3 = executeX handle3
 -}
execute3 ::  e -> (IOException -> e) -> CreateProcess -> ((Handle,Handle,Handle) -> IO (Either e a)) -> IO (Either e (ExitCode,a))
execute3 = executeX handle3

{-|
    When we only want to work with @stdout@ and @stderr@.

    > execute2 = executeX handle2
 -}
execute2 :: e -> (IOException -> e) -> CreateProcess -> ((Handle,Handle) -> IO (Either e a)) -> IO (Either e (ExitCode,a))
execute2 = executeX handle2


--
--
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

    The 'Applicative' instance is used to run concurrently the actions that
work over each handle (actions defined using functions like 'consume',
'consumeCombinedLines' and 'feed') and combine their results. 

   If any of the actions fails with @e@ the other actions are immediately
cancelled and the whole computation fails with @e@. 
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
@async@ package, but if any of the computations fails with @e@, the other are
immediately cancelled and the whole computation fails with @e@. 
 -}
mapConc :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e (t b))
mapConc f = revealError .  mapConcurrently (elideError . f)

mapConc_ :: (Show e, Typeable e, Traversable t) => (a -> IO (Either e b)) -> t a -> IO (Either e ())
mapConc_ f l = fmap (const ()) <$> mapConc f l

newtype ConcProd b r e a = ConcProd { runConcProd :: Producer b IO r -> IO (Either e a) }

instance Functor (ConcProd b r e) where
  fmap f (ConcProd x) = ConcProd $ fmap (fmap (fmap f)) x

instance (Show e, Typeable e) => Applicative (ConcProd b r e) where
  pure = ConcProd . pure . pure . pure
  ConcProd fs <*> ConcProd as = 
      ConcProd $ \producer -> revealError $ do
          (Output outbox1,inbox1,seal1) <- spawn' Unbounded
          (Output outbox2,inbox2,seal2) <- spawn' Unbounded
          --let (Output combined) = outbox1 <> outbox2
          feeding <- async $ runEffect $ 
              producer >-> (P.mapM $ \v -> do atomically $ outbox1 v
                                              atomically $ outbox2 v)
                       >-> P.drain
          sealing <- async $ wait feeding >> atomically seal1 >> atomically seal2
          r <- uncurry ($) <$> concurrently (elideError $ fs producer) 
                                            (elideError $ as producer)
          wait sealing
          return r

concProd :: (Show e, Typeable e) 
         => (Producer b IO u -> IO (Either e x))
         -> (Producer b IO u -> IO (Either e y))
         -> (Producer b IO u -> IO (Either e (x,y)))
concProd c1 c2 = runConcProd $ (,) <$> ConcProd c1
                                   <*> ConcProd c2

safely :: (MFunctor t, C.MonadCatch m, MonadIO m) 
       => (t (SafeT m) l -> (SafeT m) x) 
       -> (t m l -> m x) 
safely safeActivity = runSafeT . safeActivity . hoist lift 

fallibly :: (MFunctor t, Monad m, Error e) 
         => (t (ErrorT e m) l -> (ErrorT e m) (Either e x)) 
         -> (t m l -> m (Either e x)) 
fallibly fallibleActivity proxy = join `liftM` (runErrorT . fallibleActivity . hoist lift $ proxy)

monoidally :: (MFunctor t,Monad m, Monoid w) 
           => (w -> e -> e)
           -> (t (WriterT w m) l -> WriterT w m (Either e ()))
           -> (t m l -> m (Either e w))
monoidally errh monoidalActivity proxy = do        
    (r,w) <- runWriterT . monoidalActivity . hoist lift $ proxy
    case r of 
        Left e -> return $ Left $ errh w e  
        Right () -> return $ Right w 

monoifably :: (MFunctor t,Monad m,Monoid w, Error e') 
           => (w -> e' -> e) 
           -> (w -> e  -> e)
           -> (t (ErrorT e' (WriterT w m)) l -> ErrorT e' (WriterT w m) (Either e ()))
           -> (t m l -> m (Either e w))
monoifably errh1 errh2 monoidalActivity proxy = do
    (r,w) <- runWriterT . runErrorT . monoidalActivity . hoist (lift.lift) $ proxy
    case r of
        Left e' -> return $ Left $ errh1 w e'    
        Right r' -> case r' of
            Left e -> return $ Left $ errh2 w e
            Right () -> return $ Right w 

righteously :: (Functor f, Functor f') => f (f' a) -> f (f' (Either e a))
righteously = fmap (fmap Right)
