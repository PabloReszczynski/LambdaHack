-- | The server definitions for the server-client communication protocol.
module Game.LambdaHack.Server.ProtocolM
  ( -- * The communication channels
    CliSerQueue, ConnServerDict, ChanServer(..)
    -- * The server-client communication monad
  , MonadServerComm
      ( getsDict  -- exposed only to be implemented, not used
      , modifyDict  -- exposed only to be implemented, not used
      , liftIO  -- exposed only to be implemented, not used
      )
    -- * Protocol
  , putDict, sendUpdate, sendUpdateCheck, sendUpdNoState
  , sendSfx, sendQueryAI, sendQueryUI
    -- * Assorted
  , killAllClients, childrenServer, updateConn, tryRestore
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , writeQueue, readQueueAI, readQueueUI, newQueue
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.Concurrent
import           Control.Concurrent.Async
import qualified Data.EnumMap.Strict as EM
import           Data.Key (mapWithKeyM, mapWithKeyM_)
import           System.FilePath
import           System.IO.Unsafe (unsafePerformIO)

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client (RequestAI, RequestUI, Response (..),
                                         sbenchmark)
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.File
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import qualified Game.LambdaHack.Common.Save as Save
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Common.Thread
import           Game.LambdaHack.Content.ModeKind
import           Game.LambdaHack.Content.RuleKind
import           Game.LambdaHack.Server.DebugM
import           Game.LambdaHack.Server.MonadServer hiding (liftIO)
import           Game.LambdaHack.Server.ServerOptions
import           Game.LambdaHack.Server.State

writeQueue :: MonadServerComm m
           => Response -> CliSerQueue Response -> m ()
{-# INLINE writeQueue #-}
writeQueue cmd responseS = liftIO $ putMVar responseS cmd

readQueueAI :: MonadServerComm m
            => CliSerQueue RequestAI -> m RequestAI
{-# INLINE readQueueAI #-}
readQueueAI requestS = liftIO $ takeMVar requestS

readQueueUI :: MonadServerComm m
            => CliSerQueue RequestUI -> m RequestUI
{-# INLINE readQueueUI #-}
readQueueUI requestS = liftIO $ takeMVar requestS

newQueue :: IO (CliSerQueue a)
newQueue = newEmptyMVar

type CliSerQueue = MVar

-- | Connection information for all factions, indexed by faction identifier.
type ConnServerDict = EM.EnumMap FactionId ChanServer

-- | Connection channel between the server and a single client.
data ChanServer = ChanServer
  { responseS  :: CliSerQueue Response
  , requestAIS :: CliSerQueue RequestAI
  , requestUIS :: Maybe (CliSerQueue RequestUI)
  }

-- | The server monad with the ability to communicate with clients.
class MonadServer m => MonadServerComm m where
  getsDict     :: (ConnServerDict -> a) -> m a
  modifyDict   :: (ConnServerDict -> ConnServerDict) -> m ()
  liftIO       :: IO a -> m a

getDict :: MonadServerComm m => m ConnServerDict
getDict = getsDict id

putDict :: MonadServerComm m => ConnServerDict -> m ()
putDict s = modifyDict (const s)

-- | If the @AtomicFail@ conditions hold, send a command to client,
-- otherwise do nothing.
sendUpdate :: (MonadServerAtomic m, MonadServerComm m)
           => FactionId -> UpdAtomic -> m ()
sendUpdate !fid !cmd = do
  succeeded <- execUpdAtomicFidCatch fid cmd
  when succeeded $ sendUpd fid cmd

-- | Send a command to client, crashing if the @AtomicFail@ conditions
-- don't hold when executed on the client's state.
sendUpdateCheck :: (MonadServerAtomic m, MonadServerComm m)
                => FactionId -> UpdAtomic -> m ()
sendUpdateCheck !fid !cmd = do
  execUpdAtomicFid fid cmd
  sendUpd fid cmd

sendUpd :: MonadServerComm m => FactionId -> UpdAtomic -> m ()
sendUpd !fid !cmd = do
  chan <- getsDict (EM.! fid)
  s <- getsServer $ (EM.! fid) . sclientStates
  let resp = RespUpdAtomic s cmd
  debug <- getsServer $ sniff . soptions
  when debug $ debugResponse fid resp
  writeQueue resp $ responseS chan

sendUpdNoState :: MonadServerComm m => FactionId -> UpdAtomic -> m ()
sendUpdNoState !fid !cmd = do
  chan <- getsDict (EM.! fid)
  let resp = RespUpdAtomicNoState cmd
  debug <- getsServer $ sniff . soptions
  when debug $ debugResponse fid resp
  writeQueue resp $ responseS chan

sendSfx :: MonadServerComm m => FactionId -> SfxAtomic -> m ()
sendSfx !fid !sfx = do
  let resp = RespSfxAtomic sfx
  debug <- getsServer $ sniff . soptions
  when debug $ debugResponse fid resp
  chan <- getsDict (EM.! fid)
  case chan of
    ChanServer{requestUIS=Just{}} -> writeQueue resp $ responseS chan
    _ -> return ()

sendQueryAI :: MonadServerComm m => FactionId -> ActorId -> m RequestAI
sendQueryAI fid aid = do
  let respAI = RespQueryAI aid
  debug <- getsServer $ sniff . soptions
  when debug $ debugResponse fid respAI
  chan <- getsDict (EM.! fid)
  req <- do
    writeQueue respAI $ responseS chan
    readQueueAI $ requestAIS chan
  when debug $ debugRequestAI aid
  return req

sendQueryUI :: (MonadServerAtomic m, MonadServerComm m)
            => FactionId -> ActorId -> m RequestUI
sendQueryUI fid _aid = do
  let respUI = RespQueryUI
  debug <- getsServer $ sniff . soptions
  when debug $ debugResponse fid respUI
  chan <- getsDict (EM.! fid)
  req <- do
    writeQueue respUI $ responseS chan
    readQueueUI $ fromJust $ requestUIS chan
  when debug $ debugRequestUI _aid
  return req

killAllClients :: (MonadServerAtomic m, MonadServerComm m) => m ()
killAllClients = do
  d <- getDict
  let sendKill fid _ = sendUpdNoState fid $ UpdKillExit fid
  -- We can't interate over sfactionD, because client can be from an old game.
  -- For the same reason we can't look up and send client's state.
  mapWithKeyM_ sendKill d

-- Global variable for all children threads of the server.
childrenServer :: MVar [Async ()]
{-# NOINLINE childrenServer #-}
childrenServer = unsafePerformIO (newMVar [])

-- | Update connections to the new definition of factions.
-- Connect to clients in old or newly spawned threads
-- that read and write directly to the channels.
updateConn :: (MonadServerAtomic m, MonadServerComm m)
           => (Bool -> FactionId -> ChanServer -> IO ())
           -> m ()
updateConn executorClient = do
  -- Prepare connections based on factions.
  oldD <- getDict
  let mkChanServer :: Faction -> IO ChanServer
      mkChanServer fact = do
        responseS <- newQueue
        requestAIS <- newQueue
        requestUIS <- if fhasUI $ gplayer fact
                      then Just <$> newQueue
                      else return Nothing
        return $! ChanServer{..}
      addConn :: FactionId -> Faction -> IO ChanServer
      addConn fid fact = case EM.lookup fid oldD of
        Just conns -> return conns  -- share old conns and threads
        Nothing -> mkChanServer fact
  factionD <- getsState sfactionD
  d <- liftIO $ mapWithKeyM addConn factionD
  let newD = d `EM.union` oldD  -- never kill old clients
  putDict newD
  -- Spawn client threads.
  let toSpawn = newD EM.\\ oldD
      forkUI fid connS =
        forkChild childrenServer $ executorClient True fid connS
      forkAI fid connS =
        forkChild childrenServer $ executorClient False fid connS
      forkClient fid conn@ChanServer{requestUIS=Nothing} =
        -- When a connection is reused, clients are not respawned,
        -- even if UI usage changes, but it works OK thanks to UI faction
        -- clients distinguished by positive FactionId numbers.
        forkAI fid conn
      forkClient fid conn =
        forkUI fid conn
  liftIO $ mapWithKeyM_ forkClient toSpawn

tryRestore :: MonadServerComm m => m (Maybe (State, StateServer))
tryRestore = do
  cops <- getsState scops
  soptions <- getsServer soptions
  let bench = sbenchmark $ sclientOptions soptions
  if bench then return Nothing
  else do
    let prefix = ssavePrefixSer soptions
        fileName = prefix <> Save.saveNameSer cops
    res <- liftIO $ Save.restoreGame cops fileName
    let stdRuleset = getStdRuleset cops
        cfgUIName = rcfgUIName stdRuleset
        content = rcfgUIDefault stdRuleset
    dataDir <- liftIO appDataDir
    liftIO $ tryWriteFile (dataDir </> cfgUIName) content
    return $! res
