-- | Semantics of requests
-- .
-- A couple of them do not take time, the rest does.
-- Note that since the results are atomic commands, which are executed
-- only later (on the server and some of the clients), all condition
-- are checkd by the semantic functions in the context of the state
-- before the server command. Even if one or more atomic actions
-- are already issued by the point an expression is evaluated, they do not
-- influence the outcome of the evaluation.
module Game.LambdaHack.Server.HandleRequestM
  ( handleRequestAI, handleRequestUI, handleRequestTimed, switchLeader
  , reqMove, reqDisplace, reqAlterFail, reqGameDropAndExit, reqGameSaveAndExit
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , execFailure, setBWait, managePerRequest, handleRequestTimedCases
  , affectSmell, reqMelee, reqMeleeChecked, reqAlter
  , reqWait, reqMoveItems, reqMoveItem, computeRndTimeout, reqProject, reqApply
  , reqGameRestart, reqGameSave, reqTactic, reqAutomate
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.Text as T
import qualified Text.Show.Pretty as Show.Pretty

import           Game.LambdaHack.Atomic
import           Game.LambdaHack.Client (ReqAI (..), ReqUI (..),
                                         RequestTimed (..))
import qualified Game.LambdaHack.Common.Ability as Ability
import           Game.LambdaHack.Common.Actor
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.Faction
import           Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.ItemAspect as IA
import           Game.LambdaHack.Common.Kind
import           Game.LambdaHack.Common.Level
import           Game.LambdaHack.Common.Misc
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.Point
import           Game.LambdaHack.Common.Random
import           Game.LambdaHack.Common.ReqFailure
import           Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import           Game.LambdaHack.Common.Time
import           Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import           Game.LambdaHack.Content.ModeKind
import qualified Game.LambdaHack.Content.TileKind as TK
import           Game.LambdaHack.Server.CommonM
import           Game.LambdaHack.Server.HandleEffectM
import           Game.LambdaHack.Server.ItemM
import           Game.LambdaHack.Server.MonadServer
import           Game.LambdaHack.Server.PeriodicM
import           Game.LambdaHack.Server.ServerOptions
import           Game.LambdaHack.Server.State

execFailure :: MonadServerAtomic m
            => ActorId -> RequestTimed -> ReqFailure -> m ()
execFailure aid req failureSer = do
  -- Clients should rarely do that (only in case of invisible actors)
  -- so we report it to the client, but do not crash
  -- (server should work OK with stupid clients, too).
  body <- getsState $ getActorBody aid
  let fid = bfid body
      msg = showReqFailure failureSer
      impossible = impossibleReqFailure failureSer
      debugShow :: Show a => a -> Text
      debugShow = T.pack . Show.Pretty.ppShow
      possiblyAlarm = if impossible
                      then debugPossiblyPrintAndExit
                      else debugPossiblyPrint
  possiblyAlarm $
    "execFailure:" <+> msg <> "\n"
    <> debugShow body <> "\n" <> debugShow req <> "\n" <> debugShow failureSer
  execSfxAtomic $ SfxMsgFid fid $ SfxUnexpected failureSer

-- | The semantics of server commands.
-- AI always takes time and so doesn't loop.
handleRequestAI :: MonadServerAtomic m
                => ReqAI
                -> m (Maybe RequestTimed)
handleRequestAI cmd = case cmd of
  ReqAITimed cmdT -> return $ Just cmdT
  ReqAINop -> return Nothing

-- | The semantics of server commands. Only the first two cases affect time.
handleRequestUI :: MonadServerAtomic m
                => FactionId -> ActorId -> ReqUI
                -> m (Maybe RequestTimed)
handleRequestUI fid aid cmd = case cmd of
  ReqUITimed cmdT -> return $ Just cmdT
  ReqUIGameRestart t d -> reqGameRestart aid t d >> return Nothing
  ReqUIGameDropAndExit -> reqGameDropAndExit aid >> return Nothing
  ReqUIGameSaveAndExit -> reqGameSaveAndExit aid >> return Nothing
  ReqUIGameSave -> reqGameSave >> return Nothing
  ReqUITactic toT -> reqTactic fid toT >> return Nothing
  ReqUIAutomate -> reqAutomate fid >> return Nothing
  ReqUINop -> return Nothing

-- | This is a shorthand. Instead of setting @bwait@ in @ReqWait@
-- and unsetting in all other requests, we call this once before
-- executing a request.
setBWait :: MonadServerAtomic m
         => RequestTimed -> ActorId -> Actor -> m (Maybe Bool)
{-# INLINE setBWait #-}
setBWait cmd aid b = do
  let mwait = case cmd of
        ReqWait -> Just True  -- true wait, with bracing, no overhead, etc.
        ReqWait10 -> Just False  -- false wait, only one clip at a time
        _ -> Nothing
  when ((mwait == Just True) /= bwait b) $
    execUpdAtomic $ UpdWaitActor aid (mwait == Just True)
  return mwait

handleRequestTimed :: MonadServerAtomic m
                   => FactionId -> ActorId -> RequestTimed -> m Bool
handleRequestTimed fid aid cmd = do
  b <- getsState $ getActorBody aid
  mwait <- setBWait cmd aid b
  -- Note that only the ordinary 1-turn wait eliminates overhead.
  -- The more fine-graned waits don't make actors braced and induce
  -- overhead, so that they have some drawbacks in addition to the
  -- benefit of seeing approaching danger up to almost a turn faster.
  -- It may be too late to block then, but not too late to sidestep or attack.
  unless (mwait == Just True) $ overheadActorTime fid (blid b)
  advanceTime aid (if mwait == Just False then 10 else 100) True
  handleRequestTimedCases aid cmd
  managePerRequest aid
  return $! isNothing mwait  -- for speed, we report if @cmd@ harmless

-- | Clear deltas for Calm and HP for proper UI display and AI hints.
managePerRequest :: MonadServerAtomic m => ActorId -> m ()
managePerRequest aid = do
  b <- getsState $ getActorBody aid
  let clearMark = 0
  unless (bcalmDelta b == ResDelta (0, 0) (0, 0)) $
    -- Clear delta for the next player turn.
    execUpdAtomic $ UpdRefillCalm aid clearMark
  unless (bhpDelta b == ResDelta (0, 0) (0, 0)) $
    -- Clear delta for the next player turn.
    execUpdAtomic $ UpdRefillHP aid clearMark

handleRequestTimedCases :: MonadServerAtomic m
                        => ActorId -> RequestTimed -> m ()
handleRequestTimedCases aid cmd = case cmd of
  ReqMove target -> reqMove aid target
  ReqMelee target iid cstore -> reqMelee aid target iid cstore
  ReqDisplace target -> reqDisplace aid target
  ReqAlter tpos -> reqAlter aid tpos
  ReqWait -> reqWait aid
  ReqWait10 -> reqWait aid  -- the differences are handled elsewhere
  ReqMoveItems l -> reqMoveItems aid l
  ReqProject p eps iid cstore -> reqProject aid p eps iid cstore
  ReqApply iid cstore -> reqApply aid iid cstore

switchLeader :: MonadServerAtomic m => FactionId -> ActorId -> m ()
{-# INLINE switchLeader #-}
switchLeader fid aidNew = do
  fact <- getsState $ (EM.! fid) . sfactionD
  bPre <- getsState $ getActorBody aidNew
  let mleader = gleader fact
      !_A1 = assert (Just aidNew /= mleader
                     && not (bproj bPre)
                     `blame` (aidNew, bPre, fid, fact)) ()
      !_A2 = assert (bfid bPre == fid
                     `blame` "client tries to move other faction actors"
                     `swith` (aidNew, bPre, fid, fact)) ()
  let (autoDun, _) = autoDungeonLevel fact
  arena <- case mleader of
    Nothing -> return $! blid bPre
    Just leader -> do
      b <- getsState $ getActorBody leader
      return $! blid b
  if | blid bPre /= arena && autoDun ->
       execFailure aidNew ReqWait{-hack-} NoChangeDunLeader
     | otherwise -> do
       execUpdAtomic $ UpdLeadFaction fid mleader (Just aidNew)
     -- We exchange times of the old and new leader.
     -- This permits an abuse, because a slow tank can be moved fast
     -- by alternating between it and many fast actors (until all of them
     -- get slowed down by this and none remain). But at least the sum
     -- of all times of a faction is conserved. And we avoid double moves
     -- against the UI player caused by his leader changes. There may still
     -- happen double moves caused by AI leader changes, but that's rare.
     -- The flip side is the possibility of multi-moves of the UI player
     -- as in the case of the tank.
     -- Warning: when the action is performed on the server,
     -- the time of the actor is different than when client prepared that
     -- action, so any client checks involving time should discount this.
       case mleader of
         Just aidOld | aidOld /= aidNew -> swapTime aidOld aidNew
         _ -> return ()

-- * ReqMove

-- | Add a smell trace for the actor to the level. For now, only actors
-- with gender leave strong and unique enough smell. If smell already there
-- and the actor can smell, remove smell. Projectiles are ignored.
-- As long as an actor can smell, he doesn't leave any smell ever.
affectSmell :: MonadServerAtomic m => ActorId -> m ()
affectSmell aid = do
  b <- getsState $ getActorBody aid
  unless (bproj b) $ do
    fact <- getsState $ (EM.! bfid b) . sfactionD
    ar <- getsState $ getActorAspect aid
    let smellRadius = IA.aSmell ar
    when (fhasGender (gplayer fact) || smellRadius > 0) $ do
      localTime <- getsState $ getLocalTime $ blid b
      lvl <- getLevel $ blid b
      let oldS = fromMaybe timeZero $ EM.lookup (bpos b) . lsmell $ lvl
          newTime = timeShift localTime smellTimeout
          newS = if smellRadius > 0
                 then timeZero
                 else newTime
      when (oldS /= newS) $
        execUpdAtomic $ UpdAlterSmell (blid b) (bpos b) oldS newS

-- | Actor moves or attacks.
-- Note that client may not be able to see an invisible monster
-- so it's the server that determines if melee took place, etc.
-- Also, only the server is authorized to check if a move is legal
-- and it needs full context for that, e.g., the initial actor position
-- to check if melee attack does not try to reach to a distant tile.
reqMove :: MonadServerAtomic m => ActorId -> Vector -> m ()
reqMove source dir = do
  COps{coTileSpeedup} <- getsState scops
  actorSk <- currentSkillsServer source
  sb <- getsState $ getActorBody source
  let abInSkill ab = isJust (btrajectory sb)
                     || EM.findWithDefault 0 ab actorSk > 0
      lid = blid sb
  lvl <- getLevel lid
  let spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
  -- This predicate is symmetric wrt source and target, though the effect
  -- of collision may not be (the source projectiles applies its effect
  -- on the target particles, but loses 1 HP due to the collision).
  -- The condision implies that it's impossible to shoot down a bullet
  -- with a bullet, but a bullet can shoot down a burstable target,
  -- as well as be swept away by it, and two burstable projectiles
  -- burst when meeting mid-air. Projectiles that are not bursting
  -- nor damaging never collide with any projectile.
  collides <- getsState $ \s tb ->
    let sitemKind = getIidKindServer (btrunk sb) s
        titemKind = getIidKindServer (btrunk tb) s
        -- Such projectiles are prone to bursitng or are themselves
        -- particles of an explosion shockwave.
        bursting itemKind = IK.Fragile `elem` IK.ifeature itemKind
                            && IK.Lobable `elem` IK.ifeature itemKind
        sbursting = bursting sitemKind
        tbursting = bursting titemKind
        -- Such projectiles, even if not bursting themselves, can cause
        -- another projectile to burst.
        damaging itemKind = IK.idamage itemKind /= 0
        sdamaging = damaging sitemKind
        tdamaging = damaging titemKind
        -- Avoid explosion extinguishing itself via its own particles colliding.
        sameBlast = IK.isBlast sitemKind
                    && getIidKindIdServer (btrunk sb) s
                       == getIidKindIdServer (btrunk tb) s
    in not sameBlast
       && (sbursting && (tdamaging || tbursting)
           || (tbursting && (sdamaging || sbursting)))
  -- We start by checking actors at the target position.
  tgt <- getsState $ posToAssocs tpos lid
  case tgt of
    (target, tb) : _ | not (bproj sb) || not (bproj tb) || collides tb -> do
      -- A projectile is too small and insubstantial to hit another projectile,
      -- unless it's large enough or tends to explode (fragile and lobable).
      -- The actor in the way is visible or not; server sees him always.
      -- Below the only weapon (the only item) of projectiles is picked.
      mweapon <- pickWeaponServer source
      case mweapon of
        Just (wp, cstore) | abInSkill Ability.AbMelee ->
          reqMeleeChecked source target wp cstore
        _ -> return ()  -- waiting, even if no @AbWait@ ability
    _ -> do
      -- Either the position is empty, or all involved actors are proj.
      -- Movement requires full access and skill.
      if Tile.isWalkable coTileSpeedup $ lvl `at` tpos then
        if abInSkill Ability.AbMove then do
          execUpdAtomic $ UpdMoveActor source spos tpos
          affectSmell source
        else execFailure source (ReqMove dir) MoveUnskilled
      else
        -- Client foolishly tries to move into unwalkable tile.
        execFailure source (ReqMove dir) MoveNothing

-- * ReqMelee

-- | Resolves the result of an actor moving into another.
-- Actors on unwalkable positions can be attacked without any restrictions.
-- For instance, an actor embedded in a wall can be attacked from
-- an adjacent position. This function is analogous to projectGroupItem,
-- but for melee and not using up the weapon.
-- No problem if there are many projectiles at the spot. We just
-- attack the one specified.
reqMelee :: MonadServerAtomic m
         => ActorId -> ActorId -> ItemId -> CStore -> m ()
reqMelee source target iid cstore = do
  actorSk <- currentSkillsServer source
  if EM.findWithDefault 0 Ability.AbMelee actorSk > 0 then
    reqMeleeChecked source target iid cstore
  else execFailure source (ReqMelee target iid cstore) MeleeUnskilled

reqMeleeChecked :: MonadServerAtomic m
                => ActorId -> ActorId -> ItemId -> CStore -> m ()
reqMeleeChecked source target iid cstore = do
  sb <- getsState $ getActorBody source
  tb <- getsState $ getActorBody target
  let req = ReqMelee target iid cstore
  if source == target then execFailure source req MeleeSelf
  else if not (checkAdjacent sb tb) then execFailure source req MeleeDistant
  else do
    let sfid = bfid sb
        tfid = bfid tb
        -- Let the missile drop down, but don't remove its trajectory
        -- so that it doesn't pretend to have hit a wall.
        haltProjectile aid b = case btrajectory b of
          btra@(Just (l, speed)) | not $ null l ->
            execUpdAtomic $ UpdTrajectory aid btra $ Just ([], speed)
          _ -> return ()
    sfact <- getsState $ (EM.! sfid) . sfactionD
    itemKind <- getsState $ getIidKindServer $ btrunk tb
    -- Only catch with appendages, never with weapons. Never steal trunk
    -- from an already caught projectile or one with many items inside.
    if bproj tb && EM.size (beqp tb) == 1 && not (IK.isBlast itemKind)
       && cstore == COrgan then do
      -- Catching the projectile, that is, stealing the item from its eqp.
      -- No effect from our weapon (organ) is applied to the projectile
      -- and the weapon (organ) is never destroyed, even if not durable.
      -- Pushed actor doesn't stop flight by catching the projectile
      -- nor does he lose 1HP.
      -- This is not overpowered, because usually at least one partial wait
      -- is needed to sync (if not, attacker should switch missiles)
      -- and so only every other missile can be caught. Normal sidestepping
      -- or sync and displace, if in a corridor, is as effective
      -- and blocking can be even more so, depending on stats of the missile.
      -- Missiles are really easy to defend against, but sight (and so, Calm)
      -- is the key, as well as light, ambush around a corner, etc.
      execSfxAtomic $ SfxSteal source target iid cstore
      case EM.assocs $ beqp tb of
        [(iid2, (k, _))] -> do
          upds <- generalMoveItem True iid2 k (CActor target CEqp)
                                              (CActor source CInv)
          mapM_ execUpdAtomic upds
          itemFull <- getsState $ itemToFull iid2
          discoverIfMinorEffects (CActor source CInv) iid2 (itemKindId itemFull)
        err -> error $ "" `showFailure` err
      haltProjectile target tb
    else do
      if bproj sb && bproj tb then do
        -- Special case for collision of projectiles, because they just
        -- symmetrically ram into each other, so picking one to hit another,
        -- based on random timing, would be wrong.
        -- Instead of suffering melee attack, let the target projectile
        -- get smashed and burst (if fragile and if not piercing).
        -- The source projectile terminates flight (unless pierces) later on.
        when (bhp tb > oneM) $
          execUpdAtomic $ UpdRefillHP target minusM
        when (bhp tb <= oneM) $
          -- If projectile has too low HP to pierce, terminate its flight.
          haltProjectile target tb
      else do
        -- Normal hit, with effects. Msgs inside @SfxStrike@ describe
        -- the source part of the strike.
        execSfxAtomic $ SfxStrike source target iid cstore
        let c = CActor source cstore
        -- Msgs inside @itemEffect@ describe the target part of the strike.
        -- If any effects and aspects, this is also where they are identified.
        -- Here also the melee damage is applied, before any effects are.
        meleeEffectAndDestroy source target iid c
      sb2 <- getsState $ getActorBody source
      case btrajectory sb2 of
        Just (tra, _speed) | not (null tra) -> do
          -- Deduct a hitpoint for a pierce of a projectile
          -- or due to a hurled actor colliding with another.
          -- Don't deduct if no pierce, to prevent spam.
          -- Never kill in this way.
          when (bhp sb2 > oneM) $ do
            execUpdAtomic $ UpdRefillHP source minusM
            unless (bproj sb2) $ do
              execSfxAtomic $
                SfxMsgFid (bfid sb2) $ SfxCollideActor (blid tb) source target
              unless (bproj tb) $
                execSfxAtomic $
                  SfxMsgFid (bfid tb) $ SfxCollideActor (blid tb) source target
          when (not (bproj sb2) || bhp sb2 <= oneM) $
            -- Non-projectiles can't pierce, so terminate their flight.
            -- If projectile has too low HP to pierce, ditto.
             haltProjectile source sb2
        _ -> return ()
      -- The only way to start a war is to slap an enemy. Being hit by
      -- and hitting projectiles count as unintentional friendly fire.
      let friendlyFire = bproj sb2 || bproj tb
          fromDipl = EM.findWithDefault Unknown tfid (gdipl sfact)
      unless (friendlyFire
              || isFoe sfid sfact tfid  -- already at war
              || isFriend sfid sfact tfid) $  -- allies never at war
        execUpdAtomic $ UpdDiplFaction sfid tfid fromDipl War

-- * ReqDisplace

-- | Actor tries to swap positions with another.
reqDisplace :: MonadServerAtomic m => ActorId -> ActorId -> m ()
reqDisplace source target = do
  COps{coTileSpeedup} <- getsState scops
  actorSk <- currentSkillsServer source
  sb <- getsState $ getActorBody source
  let abInSkill ab = isJust (btrajectory sb)
                     || EM.findWithDefault 0 ab actorSk > 0
  tb <- getsState $ getActorBody target
  tfact <- getsState $ (EM.! bfid tb) . sfactionD
  let tpos = bpos tb
      atWar = isFoe (bfid tb) tfact (bfid sb)
      req = ReqDisplace target
  ar <- getsState $ getActorAspect target
  dEnemy <- getsState $ dispEnemy source target $ IA.aSkills ar
  if | not (abInSkill Ability.AbDisplace) ->
         execFailure source req DisplaceUnskilled
     | not (checkAdjacent sb tb) -> execFailure source req DisplaceDistant
     | atWar && not dEnemy -> do  -- if not at war, can displace always
       -- We don't fail with DisplaceImmobile and DisplaceSupported.
       -- because it's quite common they can't be determined by the attacker,
       -- and so the failure would be too alarming to the player.
       -- If the character melees instead, the player can tell displace failed.
       -- As for the other failures, they are impossible and we don't
       -- verify here that they don't occur, for simplicity.
       mweapon <- pickWeaponServer source
       case mweapon of
         Just (wp, cstore) | abInSkill Ability.AbMelee ->
           reqMeleeChecked source target wp cstore
         _ -> return ()  -- waiting, even if no @AbWait@ ability
     | otherwise -> do
       let lid = blid sb
       lvl <- getLevel lid
       -- Displacing requires full access.
       if Tile.isWalkable coTileSpeedup $ lvl `at` tpos then
         case posToAidsLvl tpos lvl of
           [] -> error $ "" `showFailure` (source, sb, target, tb)
           [_] -> do
             execUpdAtomic $ UpdDisplaceActor source target
             -- We leave or wipe out smell, for consistency, but it's not
             -- absolute consistency, e.g., blinking doesn't touch smell,
             -- so sometimes smellers will backtrack once to wipe smell. OK.
             affectSmell source
             affectSmell target
           _ -> execFailure source req DisplaceProjectiles
       else
         -- Client foolishly tries to displace an actor without access.
         execFailure source req DisplaceAccess

-- * ReqAlter

-- | Search and/or alter the tile.
reqAlter :: MonadServerAtomic m => ActorId -> Point -> m ()
reqAlter source tpos = do
  mfail <- reqAlterFail source tpos
  let req = ReqAlter tpos
  maybe (return ()) (execFailure source req) mfail

reqAlterFail :: MonadServerAtomic m => ActorId -> Point -> m (Maybe ReqFailure)
reqAlterFail source tpos = do
  COps{cotile, coTileSpeedup} <- getsState scops
  sb <- getsState $ getActorBody source
  ar <- getsState $ getActorAspect source
  let calmE = calmEnough sb ar
      lid = blid sb
  sClient <- getsServer $ (EM.! bfid sb) . sclientStates
  itemToF <- getsState $ flip itemToFull
  actorSk <- currentSkillsServer source
  localTime <- getsState $ getLocalTime lid
  let alterSkill = EM.findWithDefault 0 Ability.AbAlter actorSk
      applySkill = EM.findWithDefault 0 Ability.AbApply actorSk
  embeds <- getsState $ getEmbedBag lid tpos
  lvl <- getLevel lid
  let serverTile = lvl `at` tpos
      lvlClient = (EM.! lid) . sdungeon $ sClient
      clientTile = lvlClient `at` tpos
      hiddenTile = Tile.hideAs cotile serverTile
      revealEmbeds = unless (EM.null embeds) $ do
        s <- getState
        let ais = map (\iid -> (iid, getItemBody iid s)) (EM.keys embeds)
        execUpdAtomic $ UpdSpotItemBag (CEmbed lid tpos) embeds ais
      tryApplyEmbeds = do
        -- Can't send @SfxTrigger@ afterwards, because actor may be moved
        -- by the embeds to another level, where @tpos@ is meaningless.
        execSfxAtomic $ SfxTrigger source tpos
        mapM_ tryApplyEmbed $ EM.assocs embeds
      tryApplyEmbed (iid, kit) = do
        let itemFull@ItemFull{itemKind} = itemToF iid
            legal = permittedApply localTime applySkill calmE itemFull kit
        -- Let even completely unskilled actors trigger basic embeds.
        case legal of
          Left ApplyNoEffects -> return ()  -- pure flavour embed
          Left reqFail | reqFail `notElem` [ApplyUnskilled, NotCalmPrecious] ->
            -- The failure is fully expected, because client may choose
            -- to trigger some embeds, knowing that others won't fire.
            execSfxAtomic $ SfxMsgFid (bfid sb)
            $ SfxExpected ("embedded" <+> IK.iname itemKind) reqFail
          _ -> itemEffectEmbedded source lid tpos iid
  if chessDist tpos (bpos sb) > 1
  then return $ Just AlterDistant
  else if Just clientTile == hiddenTile then  -- searches
    -- Only actors with AbAlter > 1 can search for hidden doors, etc.
    if alterSkill <= 1
    then return $ Just AlterUnskilled  -- don't leak about searching
    else do
      -- Blocking by items nor actors does not prevent searching.
      -- Searching broadcasted, in case actors from other factions are present
      -- so that they can learn the tile and learn our action.
      -- If they already know the tile, they will just consider our action
      -- a waste of time and ignore the command.
      execUpdAtomic $ UpdSearchTile source tpos serverTile
      -- Searching also reveals the embedded items of the tile.
      -- If the items are already seen by the client
      -- (e.g., due to item detection, despite tile being still hidden),
      -- the command is ignored on the client.
      revealEmbeds
      -- Seaching triggers the embeds as well, after they are revealed.
      -- The rationale is that the items were all the time present
      -- (just invisible to the client), so they need to be triggered.
      -- The exception is changable tiles, because they are not so easy
      -- to trigger; they need subsequent altering.
      unless (Tile.isDoor coTileSpeedup serverTile
              || Tile.isChangable coTileSpeedup serverTile)
        tryApplyEmbeds
      return Nothing  -- success
  else if clientTile == serverTile then  -- alters
    if alterSkill < Tile.alterMinSkill coTileSpeedup serverTile
    then return $ Just AlterUnskilled  -- don't leak about altering
    else do
      let changeTo tgroup = do
            lvl2 <- getLevel lid
            -- No @SfxAlter@, because the effect is obvious (e.g., opened door).
            let nightCond kt = not (Tile.kindHasFeature TK.Walkable kt
                                    && Tile.kindHasFeature TK.Clear kt)
                               || (if lnight lvl2 then id else not)
                                    (Tile.kindHasFeature TK.Dark kt)
            -- Sometimes the tile is determined precisely by the ambient light
            -- of the source tiles. If not, default to cave day/night condition.
            mtoTile <- rndToAction $ opick cotile tgroup nightCond
            toTile <- maybe (rndToAction
                             $ fromMaybe (error $ "" `showFailure` tgroup)
                               <$> opick cotile tgroup (const True))
                            return
                            mtoTile
            unless (toTile == serverTile) $ do  -- don't regenerate same tile
              -- At most one of these two will be accepted on any given client.
              execUpdAtomic $ UpdAlterTile lid tpos serverTile toTile
              -- This case happens when a client does not see a searching
              -- action by another faction, but sees the subsequent altering.
              case hiddenTile of
                Just tHidden ->
                  execUpdAtomic $ UpdAlterTile lid tpos tHidden toTile
                Nothing -> return ()
              case (Tile.isExplorable coTileSpeedup serverTile,
                    Tile.isExplorable coTileSpeedup toTile) of
                (False, True) -> execUpdAtomic $ UpdAlterExplorable lid 1
                (True, False) -> execUpdAtomic $ UpdAlterExplorable lid (-1)
                _ -> return ()
              -- At the end we replace old embeds (even if partially used up)
              -- with new ones.
              -- If the source tile was hidden, the items could not be visible
              -- on a client, in which case the command would be ignored
              -- on the client, without causing any problems. Otherwise,
              -- if the position is in view, client has accurate info.
              case EM.lookup tpos (lembed lvl2) of
                Just bag -> do
                  s <- getState
                  let ais = map (\iid -> (iid, getItemBody iid s)) (EM.keys bag)
                  execUpdAtomic $ UpdLoseItemBag (CEmbed lid tpos) bag ais
                Nothing -> return ()
              -- Altering always reveals the outcome tile, so it's not hidden
              -- and so its embedded items are always visible.
              embedItem lid tpos toTile
          feats = TK.tfeature $ okind cotile serverTile
          toAlter feat =
            case feat of
              TK.OpenTo tgroup -> Just tgroup
              TK.CloseTo tgroup -> Just tgroup
              TK.ChangeTo tgroup -> Just tgroup
              _ -> Nothing
          groupsToAlterTo = mapMaybe toAlter feats
      if null groupsToAlterTo && EM.null embeds then
        return $ Just AlterNothing  -- no altering possible; silly client
      else
        if EM.notMember tpos $ lfloor lvl then
          if null (posToAidsLvl tpos lvl) then do
            -- The embeds of the initial tile are activated before the tile
            -- is altered. This prevents, e.g., trying to activate items
            -- where none are present any more, or very different to what
            -- the client expected. Surprise only comes through searching above.
            -- The items are first revealed for the sake of clients that
            -- may see the tile as hidden. Note that the tile is not revealed
            -- (unless it's altered later on, in which case the new one is).
            revealEmbeds
            tryApplyEmbeds
            case groupsToAlterTo of
              [] -> return ()
              [groupToAlterTo] -> changeTo groupToAlterTo
              l -> error $ "tile changeable in many ways" `showFailure` l
            return Nothing  -- success
          else return $ Just AlterBlockActor
        else return $ Just AlterBlockItem
  else  -- client is misguided re tile at that position, so bail out
    return $ Just AlterNothing

-- * ReqWait

-- | Do nothing.
--
-- Something is sometimes done in 'setBWait'.
reqWait :: MonadServerAtomic m => ActorId -> m ()
{-# INLINE reqWait #-}
reqWait source = do
  actorSk <- currentSkillsServer source
  unless (EM.findWithDefault 0 Ability.AbWait actorSk > 0) $
    execFailure source ReqWait WaitUnskilled

-- * ReqMoveItems

reqMoveItems :: MonadServerAtomic m
             => ActorId -> [(ItemId, Int, CStore, CStore)] -> m ()
reqMoveItems source l = do
  actorSk <- currentSkillsServer source
  if EM.findWithDefault 0 Ability.AbMoveItem actorSk > 0 then do
    b <- getsState $ getActorBody source
    ar <- getsState $ getActorAspect source
    -- Server accepts item movement based on calm at the start, not end
    -- or in the middle, to avoid interrupted or partially ignored commands.
    let calmE = calmEnough b ar
    mapM_ (reqMoveItem source calmE) l
  else execFailure source (ReqMoveItems l) MoveItemUnskilled

reqMoveItem :: MonadServerAtomic m
            => ActorId -> Bool -> (ItemId, Int, CStore, CStore) -> m ()
reqMoveItem aid calmE (iid, k, fromCStore, toCStore) = do
  b <- getsState $ getActorBody aid
  let fromC = CActor aid fromCStore
      req = ReqMoveItems [(iid, k, fromCStore, toCStore)]
  toC <- case toCStore of
    CGround -> pickDroppable aid b
    _ -> return $! CActor aid toCStore
  bagBefore <- getsState $ getContainerBag toC
  if
   | k < 1 || fromCStore == toCStore -> execFailure aid req ItemNothing
   | toCStore == CEqp && eqpOverfull b k ->
     execFailure aid req EqpOverfull
   | (fromCStore == CSha || toCStore == CSha) && not calmE ->
     execFailure aid req ItemNotCalm
   | otherwise -> do
    upds <- generalMoveItem True iid k fromC toC
    mapM_ execUpdAtomic upds
    itemFull <- getsState $ itemToFull iid
    when (fromCStore == CGround) $  -- pick up
      discoverIfMinorEffects toC iid (itemKindId itemFull)
    -- Reset timeout for equipped periodic items and also for items
    -- moved out of the shared stash, in which timeouts are not consistently
    -- wrt some local time, because actors from many levels put items there
    -- all the time (and don't rebase it to any common clock).
    -- If wrong local time in shared stash causes an item to recharge
    -- for a very long time, the player can reset it by moving it to pack
    -- and back to stash (as a flip side, a charging item in stash may sometimes
    -- be used at once on another level, with different local time, but only
    -- once, because after first use, the timeout is set to local time).
    when (toCStore `elem` [CEqp, COrgan]
          && fromCStore `notElem` [CEqp, COrgan]
          || fromCStore == CSha) $ do
      localTime <- getsState $ getLocalTime (blid b)
      -- The first recharging period after pick up is random,
      -- between 1 and 2 standard timeouts of the item.
      mrndTimeout <- rndToAction $ computeRndTimeout localTime itemFull
      let beforeIt = case iid `EM.lookup` bagBefore of
            Nothing -> []  -- no such items before move
            Just (_, it2) -> it2
      -- The moved item set (not the whole stack) has its timeout
      -- reset to a random value between timeout and twice timeout.
      -- This prevents micromanagement via swapping items in and out of eqp
      -- and via exact prediction of first timeout after equip.
      case mrndTimeout of
        Just rndT -> do
          bagAfter <- getsState $ getContainerBag toC
          let afterIt = case iid `EM.lookup` bagAfter of
                Nothing -> error $ "" `showFailure` (iid, bagAfter, toC)
                Just (_, it2) -> it2
              resetIt = beforeIt ++ replicate k rndT
          when (afterIt /= resetIt) $
            execUpdAtomic $ UpdTimeItem iid toC afterIt resetIt
        Nothing -> return ()  -- no Periodic or Timeout aspect; don't touch

computeRndTimeout :: Time -> ItemFull -> Rnd (Maybe Time)
computeRndTimeout localTime ItemFull{itemKind, itemDisco} =
  case IA.aTimeout $ itemAspect itemDisco of
    t | t /= 0 && IK.Periodic `elem` IK.ifeature itemKind -> do
      rndT <- randomR (0, t)
      let rndTurns = timeDeltaScale (Delta timeTurn) (t + rndT)
      return $ Just $ timeShift localTime rndTurns
    _ -> return Nothing

-- * ReqProject

reqProject :: MonadServerAtomic m
           => ActorId    -- ^ actor projecting the item (is on current lvl)
           -> Point      -- ^ target position of the projectile
           -> Int        -- ^ digital line parameter
           -> ItemId     -- ^ the item to be projected
           -> CStore     -- ^ whether the items comes from floor or inventory
           -> m ()
reqProject source tpxy eps iid cstore = do
  let req = ReqProject tpxy eps iid cstore
  b <- getsState $ getActorBody source
  ar <- getsState $ getActorAspect source
  let calmE = calmEnough b ar
  if cstore == CSha && not calmE then execFailure source req ItemNotCalm
  else do
    mfail <- projectFail source tpxy eps False iid cstore False
    maybe (return ()) (execFailure source req) mfail

-- * ReqApply

reqApply :: MonadServerAtomic m
         => ActorId  -- ^ actor applying the item (is on current level)
         -> ItemId   -- ^ the item to be applied
         -> CStore   -- ^ the location of the item
         -> m ()
reqApply aid iid cstore = do
  let req = ReqApply iid cstore
  b <- getsState $ getActorBody aid
  ar <- getsState $ getActorAspect aid
  let calmE = calmEnough b ar
  if cstore == CSha && not calmE then execFailure aid req ItemNotCalm
  else do
    bag <- getsState $ getBodyStoreBag b cstore
    case EM.lookup iid bag of
      Nothing -> execFailure aid req ApplyOutOfReach
      Just kit -> do
        itemFull <- getsState $ itemToFull iid
        actorSk <- currentSkillsServer aid
        localTime <- getsState $ getLocalTime (blid b)
        let skill = EM.findWithDefault 0 Ability.AbApply actorSk
            legal = permittedApply localTime skill calmE itemFull kit
        case legal of
          Left reqFail -> execFailure aid req reqFail
          Right _ -> applyItem aid iid cstore

-- * ReqGameRestart

reqGameRestart :: MonadServerAtomic m
               => ActorId -> GroupName ModeKind -> Challenge
               -> m ()
reqGameRestart aid groupName scurChalSer = do
  modifyServer $ \ser -> ser {soptionsNxt = (soptionsNxt ser) {scurChalSer}}
  b <- getsState $ getActorBody aid
  oldSt <- getsState $ gquit . (EM.! bfid b) . sfactionD
  -- We don't save game and don't wait for clips end. ASAP.
  modifyServer $ \ser -> ser {sbreakASAP = True}
  isNoConfirms <- isNoConfirmsGame
  -- This call to `revealItems` is really needed, because the other
  -- happens only at game conclusion, not at quitting.
  unless isNoConfirms $ revealItems Nothing
  execUpdAtomic $ UpdQuitFaction (bfid b) oldSt
                $ Just $ Status Restart (fromEnum $ blid b) (Just groupName)

-- * ReqGameDropAndExit

-- After we break out of the game loop, we will notice from @Camping@
-- we shouldn exit the game.
reqGameDropAndExit :: MonadServerAtomic m => ActorId -> m ()
reqGameDropAndExit aid = do
  b <- getsState $ getActorBody aid
  oldSt <- getsState $ gquit . (EM.! bfid b) . sfactionD
  modifyServer $ \ser -> ser {sbreakLoop = True}
  execUpdAtomic $ UpdQuitFaction (bfid b) oldSt
                $ Just $ Status Camping (fromEnum $ blid b) Nothing

-- * ReqGameSaveAndExit

-- After we break out of the game loop, we will notice from @Camping@
-- we shouldn exit the game.
reqGameSaveAndExit :: MonadServerAtomic m => ActorId -> m ()
reqGameSaveAndExit aid = do
  b <- getsState $ getActorBody aid
  oldSt <- getsState $ gquit . (EM.! bfid b) . sfactionD
  modifyServer $ \ser -> ser { sbreakASAP = True
                             , swriteSave = True }
  execUpdAtomic $ UpdQuitFaction (bfid b) oldSt
                $ Just $ Status Camping (fromEnum $ blid b) Nothing

-- * ReqGameSave

-- After we break out of the game loop, we will notice we shouldn't quit
-- the game and we will enter the game loop again.
reqGameSave :: MonadServer m => m ()
reqGameSave =
  modifyServer $ \ser -> ser { sbreakASAP = True
                             , swriteSave = True }

-- * ReqTactic

reqTactic :: MonadServerAtomic m => FactionId -> Tactic -> m ()
reqTactic fid toT = do
  fromT <- getsState $ ftactic . gplayer . (EM.! fid) . sfactionD
  execUpdAtomic $ UpdTacticFaction fid toT fromT

-- * ReqAutomate

reqAutomate :: MonadServerAtomic m => FactionId -> m ()
reqAutomate fid = execUpdAtomic $ UpdAutoFaction fid True
