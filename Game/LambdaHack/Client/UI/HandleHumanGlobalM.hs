{-# LANGUAGE DataKinds, GADTs #-}
-- | Semantics of 'Command.Cmd' client commands that return server commands.
-- A couple of them do not take time, the rest does.
-- Here prompts and menus and displayed, but any feedback resulting
-- from the commands (e.g., from inventory manipulation) is generated later on,
-- for all clients that witness the results of the commands.
-- TODO: document
module Game.LambdaHack.Client.UI.HandleHumanGlobalM
  ( -- * Meta commands
    byAreaHuman, byAimModeHuman, byItemModeHuman
  , composeIfLeftHuman, composeIfEmptyHuman
    -- * Global commands that usually take time
  , waitHuman, moveRunHuman
  , runOnceAheadHuman, moveOnceToXhairHuman
  , runOnceToXhairHuman, continueToXhairHuman
  , moveItemHuman, projectHuman, applyHuman, alterDirHuman, triggerTileHuman
  , helpHuman, mainMenuHuman, gameDifficultyIncr
    -- * Global commands that never take time
  , gameRestartHuman, gameExitHuman, gameSaveHuman
  , tacticHuman, automateHuman
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

-- Cabal
import qualified Paths_LambdaHack as Self (version)

import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Functor.Infix ((<$$>))
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Version
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.BfsM
import Game.LambdaHack.Client.CommonM
import Game.LambdaHack.Client.ItemSlot
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.FrameM
import Game.LambdaHack.Client.UI.Frontend (frontendName)
import Game.LambdaHack.Client.UI.HandleHelperM
import Game.LambdaHack.Client.UI.HandleHumanLocalM
import Game.LambdaHack.Client.UI.HumanCmd (CmdArea (..), Trigger (..))
import qualified Game.LambdaHack.Client.UI.HumanCmd as HumanCmd
import Game.LambdaHack.Client.UI.InventoryM
import Game.LambdaHack.Client.UI.KeyBindings
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.MsgM
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Client.UI.RunM
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Client.UI.Slideshow
import Game.LambdaHack.Client.UI.SlideshowM
import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import qualified Game.LambdaHack.Content.ItemKind as IK
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Content.TileKind (TileKind)
import qualified Game.LambdaHack.Content.TileKind as TK

-- * ByArea

-- | Pick command depending on area the mouse pointer is in.
-- The first matching area is chosen. If none match, only interrupt.
byAreaHuman :: MonadClientUI m
            => (HumanCmd.HumanCmd -> m (Either MError RequestUI))
            -> [(HumanCmd.CmdArea, HumanCmd.HumanCmd)]
            -> m (Either MError RequestUI)
byAreaHuman cmdAction l = do
  pointer <- getsSession spointer
  let pointerInArea a = do
        rs <- areaToRectangles a
        return $! any (inside pointer) rs
  cmds <- filterM (pointerInArea . fst) l
  case cmds of
    [] -> do
      stopPlayBack
      return $ Left Nothing
    (_, cmd) : _ ->
      cmdAction cmd

areaToRectangles :: MonadClientUI m => HumanCmd.CmdArea -> m [(X, Y, X, Y)]
areaToRectangles ca = case ca of
  CaMessage -> return [(0, 0, fst normalLevelBound, 0)]
  CaMapLeader -> do  -- takes preference over @CaMapParty@ and @CaMap@
    leader <- getLeaderUI
    b <- getsState $ getActorBody leader
    let Point{..} = bpos b
    return [(px, mapStartY + py, px, mapStartY + py)]
  CaMapParty -> do  -- takes preference over @CaMap@
    lidV <- viewedLevelUI
    side <- getsClient sside
    ours <- getsState $ filter (not . bproj . snd)
                        . actorAssocs (== side) lidV
    let rectFromB Point{..} = (px, mapStartY + py, px, mapStartY + py)
    return $! map (rectFromB . bpos . snd) ours
  CaMap -> return
    [( 0, mapStartY, fst normalLevelBound, mapStartY + snd normalLevelBound )]
  CaArenaName -> let y = snd normalLevelBound + 2
                     x = fst normalLevelBound `div` 2 - 11
                 in return [(0, y, x, y)]
  CaPercentSeen -> let y = snd normalLevelBound + 2
                       x = fst normalLevelBound `div` 2
                   in return [(x - 9, y, x, y)]
  CaXhairDesc -> let y = snd normalLevelBound + 2
                     x = fst normalLevelBound `div` 2 + 2
                 in return [(x, y, fst normalLevelBound, y)]
  CaSelected -> let y = snd normalLevelBound + 3
                    x = fst normalLevelBound `div` 2
                in return [(0, y, x - 22, y)]  -- TODO
  CaLeaderStatus -> let y = snd normalLevelBound + 3
                        x = fst normalLevelBound `div` 2
                    in return [(x - 20, y, x, y)]
                      -- TODO: calculate and share with ClientDraw
  CaTargetDesc -> let y = snd normalLevelBound + 3
                      x = fst normalLevelBound `div` 2 + 2
                  in return [(x, y, fst normalLevelBound, y)]
  CaRectangle r -> return [r]
  CaUnion ca1 ca2 -> liftM2 (++) (areaToRectangles ca1) (areaToRectangles ca2)

-- * ByAimMode

byAimModeHuman :: MonadClientUI m
               => m (Either MError RequestUI) -> m (Either MError RequestUI)
               -> m (Either MError RequestUI)
byAimModeHuman cmdNotAimingM cmdAimingM = do
  aimMode <- getsSession saimMode
  if isNothing aimMode then cmdNotAimingM else cmdAimingM

-- * ByItemMode

byItemModeHuman :: MonadClientUI m
                => m (Either MError RequestUI) -> m (Either MError RequestUI)
                -> m (Either MError RequestUI)

byItemModeHuman cmdNotChosenM cmdChosenM = do
  itemSel <- getsSession sitemSel
  if isNothing itemSel then cmdNotChosenM else cmdChosenM

-- * ComposeIfLeft

composeIfLeftHuman :: MonadClientUI m
                    => m (Either MError RequestUI) -> m (Either MError RequestUI)
                    -> m (Either MError RequestUI)
composeIfLeftHuman c1 c2 = do
  slideOrCmd1 <- c1
  case slideOrCmd1 of
    Left _merr -> c2
    _ -> return slideOrCmd1

-- * ComposeIfEmpty

composeIfEmptyHuman :: MonadClientUI m
                    => m (Either MError RequestUI) -> m (Either MError RequestUI)
                    -> m (Either MError RequestUI)
composeIfEmptyHuman c1 c2 = do
  slideOrCmd1 <- c1
  case slideOrCmd1 of
    Left Nothing -> c2
    _ -> return slideOrCmd1

-- * Wait

-- | Leader waits a turn (and blocks, etc.).
waitHuman :: MonadClientUI m => m (RequestTimed 'AbWait)
waitHuman = do
  modifySession $ \sess -> sess {swaitTimes = abs (swaitTimes sess) + 1}
  return ReqWait

-- * MoveDir and RunDir

moveRunHuman :: MonadClientUI m
             => Bool -> Bool -> Bool -> Bool -> Vector
             -> m (FailOrCmd RequestAnyAbility)
moveRunHuman initialStep finalGoal run runAhead dir = do
  arena <- getArenaUI
  leader <- getLeaderUI
  sb <- getsState $ getActorBody leader
  fact <- getsState $ (EM.! bfid sb) . sfactionD
  -- Start running in the given direction. The first turn of running
  -- succeeds much more often than subsequent turns, because we ignore
  -- most of the disturbances, since the player is mostly aware of them
  -- and still explicitly requests a run, knowing how it behaves.
  sel <- getsSession sselected
  let runMembers = if runAhead || noRunWithMulti fact
                   then [leader]  -- TODO: warn?
                   else ES.toList (ES.delete leader sel) ++ [leader]
      runParams = RunParams { runLeader = leader
                            , runMembers
                            , runInitial = True
                            , runStopMsg = Nothing
                            , runWaiting = 0 }
      macroRun25 = ["CTRL-comma", "CTRL-V"]
  when (initialStep && run) $ do
    modifySession $ \cli ->
      cli {srunning = Just runParams}
    when runAhead $
      modifySession $ \cli ->
        cli {slastPlay = map K.mkKM macroRun25 ++ slastPlay cli}
  -- When running, the invisible actor is hit (not displaced!),
  -- so that running in the presence of roving invisible
  -- actors is equivalent to moving (with visible actors
  -- this is not a problem, since runnning stops early enough).
  -- TODO: stop running at invisible actor
  let tpos = bpos sb `shift` dir
  -- We start by checking actors at the the target position,
  -- which gives a partial information (actors can be invisible),
  -- as opposed to accessibility (and items) which are always accurate
  -- (tiles can't be invisible).
  tgts <- getsState $ posToActors tpos arena
  case tgts of
    [] -> do  -- move or search or alter
      runStopOrCmd <- moveSearchAlterAid leader dir
      case runStopOrCmd of
        Left stopMsg -> failWith stopMsg
        Right runCmd ->
          -- Don't check @initialStep@ and @finalGoal@
          -- and don't stop going to target: door opening is mundane enough.
          return $ Right runCmd
    [(target, _)] | run && initialStep ->
      -- No @stopPlayBack@: initial displace is benign enough.
      -- Displacing requires accessibility, but it's checked later on.
      RequestAnyAbility <$$> displaceAid target
    _ : _ : _ | run && initialStep -> do
      let !_A = assert (all (bproj . snd) tgts) ()
      failSer DisplaceProjectiles
    (target, tb) : _ | initialStep && finalGoal -> do
      stopPlayBack  -- don't ever auto-repeat melee
      -- No problem if there are many projectiles at the spot. We just
      -- attack the first one.
      -- We always see actors from our own faction.
      if bfid tb == bfid sb && not (bproj tb) then do
        let autoLvl = snd $ autoDungeonLevel fact
        if autoLvl then failSer NoChangeLvlLeader
        else do
          -- Select adjacent actor by bumping into him. Takes no time.
          success <- pickLeader True target
          let !_A = assert (success `blame` "bump self"
                                    `twith` (leader, target, tb)) ()
          failWith "by bumping"
      else
        -- Attacking does not require full access, adjacency is enough.
        RequestAnyAbility <$$> meleeAid target
    _ : _ -> failWith "actor in the way"

-- | Actor atttacks an enemy actor or his own projectile.
meleeAid :: MonadClientUI m
         => ActorId -> m (FailOrCmd (RequestTimed 'AbMelee))
meleeAid target = do
  leader <- getLeaderUI
  sb <- getsState $ getActorBody leader
  tb <- getsState $ getActorBody target
  sfact <- getsState $ (EM.! bfid sb) . sfactionD
  mel <- pickWeaponClient leader target
  case mel of
    Nothing -> failWith "nothing to melee with"
    Just wp -> do
      let returnCmd = do
            -- Set personal target to the enemy position,
            -- to easily him with a ranged attack when he flees.
            let f (Just (TEnemy _ b)) = Just $ TEnemy target b
                f (Just (TEnemyPos _ _ _ b)) = Just $ TEnemy target b
                f _ = Just $ TEnemy target False
            modifyClient $ updateTarget leader f
            return $ Right wp
          res | bproj tb || isAtWar sfact (bfid tb) = returnCmd
              | isAllied sfact (bfid tb) = do
                go1 <- displayYesNo ColorBW
                         "You are bound by an alliance. Really attack?"
                if not go1 then failWith "attack canceled" else returnCmd
              | otherwise = do
                go2 <- displayYesNo ColorBW
                         "This attack will start a war. Are you sure?"
                if not go2 then failWith "attack canceled" else returnCmd
      res
  -- Seeing the actor prevents altering a tile under it, but that
  -- does not limit the player, he just doesn't waste a turn
  -- on a failed altering.

-- | Actor swaps position with another.
displaceAid :: MonadClientUI m
            => ActorId -> m (FailOrCmd (RequestTimed 'AbDisplace))
displaceAid target = do
  cops <- getsState scops
  leader <- getLeaderUI
  sb <- getsState $ getActorBody leader
  tb <- getsState $ getActorBody target
  tfact <- getsState $ (EM.! bfid tb) . sfactionD
  activeItems <- activeItemsClient target
  disp <- getsState $ dispEnemy leader target activeItems
  let actorMaxSk = sumSkills activeItems
      immobile = EM.findWithDefault 0 AbMove actorMaxSk <= 0
      spos = bpos sb
      tpos = bpos tb
      adj = checkAdjacent sb tb
      atWar = isAtWar tfact (bfid sb)
  if | not adj -> failSer DisplaceDistant
     | not (bproj tb) && atWar
       && actorDying tb ->
       failSer DisplaceDying
     | not (bproj tb) && atWar
       && braced tb ->
       failSer DisplaceBraced
     | not (bproj tb) && atWar
       && immobile ->
       failSer DisplaceImmobile
     | not disp && atWar ->
       failSer DisplaceSupported
     | otherwise -> do
       let lid = blid sb
       lvl <- getLevel lid
       -- Displacing requires full access.
       if accessible cops lvl spos tpos then do
         tgts <- getsState $ posToActors tpos lid
         case tgts of
           [] -> assert `failure` (leader, sb, target, tb)
           [_] -> return $ Right $ ReqDisplace target
           _ -> failSer DisplaceProjectiles
       else failSer DisplaceAccess

-- | Actor moves or searches or alters. No visible actor at the position.
moveSearchAlterAid :: MonadClient m
                   => ActorId -> Vector -> m (Either Text RequestAnyAbility)
moveSearchAlterAid source dir = do
  cops@Kind.COps{cotile} <- getsState scops
  sb <- getsState $ getActorBody source
  actorSk <- actorSkillsClient source
  lvl <- getLevel $ blid sb
  let skill = EM.findWithDefault 0 AbAlter actorSk
      spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
      t = lvl `at` tpos
      runStopOrCmd
        -- Movement requires full access.
        | accessible cops lvl spos tpos =
            -- A potential invisible actor is hit. War started without asking.
            Right $ RequestAnyAbility $ ReqMove dir
        -- No access, so search and/or alter the tile. Non-walkability is
        -- not implied by the lack of access.
        | not (Tile.isWalkable cotile t)
          && (not (knownLsecret lvl)
              || (isSecretPos lvl tpos  -- possible secrets here
                  && (Tile.isSuspect cotile t  -- not yet searched
                      || Tile.hideAs cotile t /= t))  -- search again
              || Tile.isOpenable cotile t
              || Tile.isClosable cotile t
              || Tile.isChangeable cotile t)
          = if | skill < 1 ->
                 Left $ showReqFailure AlterUnskilled
               | EM.member tpos $ lfloor lvl ->
                 Left $ showReqFailure AlterBlockItem
               | otherwise ->
                 Right $ RequestAnyAbility $ ReqAlter tpos Nothing
            -- We don't use MoveSer, because we don't hit invisible actors.
            -- The potential invisible actor, e.g., in a wall or in
            -- an inaccessible doorway, is made known, taking a turn.
            -- If server performed an attack for free
            -- on the invisible actor anyway, the player (or AI)
            -- would be tempted to repeatedly hit random walls
            -- in hopes of killing a monster lurking within.
            -- If the action had a cost, misclicks would incur the cost, too.
            -- Right now the player may repeatedly alter tiles trying to learn
            -- about invisible pass-wall actors, but when an actor detected,
            -- it costs a turn and does not harm the invisible actors,
            -- so it's not so tempting.
        -- Ignore a known boring, not accessible tile.
        | otherwise = Left "never mind"
  return $! runStopOrCmd

-- * RunOnceAhead

runOnceAheadHuman :: MonadClientUI m => m (Either MError RequestUI)
runOnceAheadHuman = do
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  leader <- getLeaderUI
  Config{configRunStopMsgs} <- getsSession sconfig
  keyPressed <- anyKeyPressed
  srunning <- getsSession srunning
  -- When running, stop if disturbed. If not running, stop at once.
  case srunning of
    Nothing -> do
      stopPlayBack
      return $ Left Nothing
    Just RunParams{runMembers}
      | noRunWithMulti fact && runMembers /= [leader] -> do
      stopPlayBack
      if configRunStopMsgs
      then weaveJust <$> failWith "run stop: automatic leader change"
      else return $ Left Nothing
    Just _runParams | keyPressed -> do
      discardPressedKey
      stopPlayBack
      if configRunStopMsgs
      then weaveJust <$> failWith "run stop: key pressed"
      else weaveJust <$> failWith "interrupted"
    Just runParams -> do
      arena <- getArenaUI
      runOutcome <- continueRun arena runParams
      case runOutcome of
        Left stopMsg -> do
          stopPlayBack
          if configRunStopMsgs
          then weaveJust <$> failWith ("run stop:" <+> stopMsg)
          else return $ Left Nothing
        Right runCmd ->
          return $ Right $ ReqUITimed runCmd

-- * MoveOnceToXhair

moveOnceToXhairHuman :: MonadClientUI m => m (FailOrCmd RequestAnyAbility)
moveOnceToXhairHuman = goToXhair True False

goToXhair :: MonadClientUI m
           => Bool -> Bool -> m (FailOrCmd RequestAnyAbility)
goToXhair initialStep run = do
  aimMode <- getsSession saimMode
  -- Movement is legal only outside aiming mode.
  if isJust aimMode then failWith "cannot move in aiming mode"
  else do
    leader <- getLeaderUI
    b <- getsState $ getActorBody leader
    xhairPos <- xhairToPos
    case xhairPos of
      Nothing -> failWith "crosshair position invalid"
      Just c | c == bpos b -> do
        if initialStep
        then return $ Right $ RequestAnyAbility ReqWait
        else failWith "position reached"
      Just c -> do
        running <- getsSession srunning
        case running of
          -- Don't use running params from previous run or goto-xhair.
          Just paramOld | not initialStep -> do
            arena <- getArenaUI
            runOutcome <- multiActorGoTo arena c paramOld
            case runOutcome of
              Left stopMsg -> failWith stopMsg
              Right (finalGoal, dir) ->
                moveRunHuman initialStep finalGoal run False dir
          _ -> do
            let !_A = assert (initialStep || not run) ()
            (_, mpath) <- getCacheBfsAndPath leader c
            case mpath of
              Nothing -> failWith "no route to crosshair"
              Just [] -> assert `failure` (leader, b, c)
              Just (p1 : _) -> do
                let finalGoal = p1 == c
                    dir = towards (bpos b) p1
                moveRunHuman initialStep finalGoal run False dir

multiActorGoTo :: MonadClientUI m
               => LevelId -> Point -> RunParams
               -> m (Either Text (Bool, Vector))
multiActorGoTo arena c paramOld =
  case paramOld of
    RunParams{runMembers = []} ->
      return $ Left "selected actors no longer there"
    RunParams{runMembers = r : rs, runWaiting} -> do
      onLevel <- getsState $ memActor r arena
      if not onLevel then do
        let paramNew = paramOld {runMembers = rs}
        multiActorGoTo arena c paramNew
      else do
        s <- getState
        modifyClient $ updateLeader r s
        let runMembersNew = rs ++ [r]
            paramNew = paramOld { runMembers = runMembersNew
                                , runWaiting = 0}
        b <- getsState $ getActorBody r
        (_, mpath) <- getCacheBfsAndPath r c
        case mpath of
          Nothing -> return $ Left "no route to crosshair"
          Just [] ->
            -- This actor already at goal; will be caught in goToXhair.
            return $ Left ""
          Just (p1 : _) -> do
            let finalGoal = p1 == c
                dir = towards (bpos b) p1
                tpos = bpos b `shift` dir
            tgts <- getsState $ posToActors tpos arena
            case tgts of
              [] -> do
                modifySession $ \sess -> sess {srunning = Just paramNew}
                return $ Right (finalGoal, dir)
              [(target, _)]
                | target `elem` rs || runWaiting <= length rs ->
                -- Let r wait until all others move. Mark it in runWaiting
                -- to avoid cycles. When all wait for each other, fail.
                multiActorGoTo arena c paramNew{runWaiting=runWaiting + 1}
              _ ->
                 return $ Left "actor in the way"

-- * RunOnceToXhair

runOnceToXhairHuman :: MonadClientUI m => m (FailOrCmd RequestAnyAbility)
runOnceToXhairHuman = goToXhair True True

-- * ContinueToXhair

continueToXhairHuman :: MonadClientUI m => m (FailOrCmd RequestAnyAbility)
continueToXhairHuman = goToXhair False False{-irrelevant-}

-- * MoveItem

moveItemHuman :: forall m. MonadClientUI m
              => [CStore] -> CStore -> Maybe MU.Part -> Bool
              -> m (FailOrCmd (RequestTimed 'AbMoveItem))
moveItemHuman cLegalRaw destCStore mverb auto = do
  itemSel <- getsSession sitemSel
  case itemSel of
    Just (fromCStore, iid) | cLegalRaw /= [CGround]  -- not normal pickup
                             && fromCStore /= destCStore -> do  -- not vacuous
      leader <- getLeaderUI
      bag <- getsState $ getActorBag leader fromCStore
      case iid `EM.lookup` bag of
        Nothing -> do  -- used up
          modifySession $ \sess -> sess {sitemSel = Nothing}
          moveItemHuman cLegalRaw destCStore mverb auto
        Just (k, it) -> do
          itemToF <- itemToFullClient
          b <- getsState $ getActorBody leader
          let eqpFree = eqpFreeN b
              kToPick | destCStore == CEqp = min eqpFree k
                      | otherwise = k
          socK <- pickNumber True kToPick
          modifySession $ \sess -> sess {sitemSel = Nothing}
          case socK of
            Left err -> failWith err
            Right kChosen ->
              let is = ( fromCStore
                       , [(iid, itemToF iid (kChosen, take kChosen it))] )
              in moveItems cLegalRaw is destCStore
    _ -> do
      mis <- selectItemsToMove cLegalRaw destCStore mverb auto
      case mis of
        Left err -> return $ Left err
        Right is -> moveItems cLegalRaw is destCStore

selectItemsToMove :: forall m. MonadClientUI m
                  => [CStore] -> CStore -> Maybe MU.Part -> Bool
                  -> m (FailOrCmd (CStore, [(ItemId, ItemFull)]))
selectItemsToMove cLegalRaw destCStore mverb auto = do
  let !_A = assert (destCStore `notElem` cLegalRaw) ()
  let verb = fromMaybe (MU.Text $ verbCStore destCStore) mverb
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  -- This calmE is outdated when one of the items increases max Calm
  -- (e.g., in pickup, which handles many items at once), but this is OK,
  -- the server accepts item movement based on calm at the start, not end
  -- or in the middle.
  -- The calmE is inaccurate also if an item not IDed, but that's intended
  -- and the server will ignore and warn (and content may avoid that,
  -- e.g., making all rings identified)
  let calmE = calmEnough b activeItems
      cLegal | calmE = cLegalRaw
             | destCStore == CSha = []
             | otherwise = delete CSha cLegalRaw
      prompt = makePhrase ["What to", verb]
      promptEqp = makePhrase ["What consumable to", verb]
      p :: CStore -> (Text, m Suitability)
      p cstore = if cstore `elem` [CEqp, CSha] && cLegalRaw /= [CGround]
                 then (promptEqp, return $ SuitsSomething goesIntoEqp)
                 else (prompt, return SuitsEverything)
      (promptGeneric, psuit) = p destCStore
  ggi <-
    if auto
    then getAnyItems psuit prompt promptGeneric cLegalRaw cLegal False False
    else getAnyItems psuit prompt promptGeneric cLegalRaw cLegal True True
  case ggi of
    Right (l, MStore fromCStore) -> return $ Right (fromCStore, l)
    Left err -> failWith err
    _ -> assert `failure` ggi

moveItems :: forall m. MonadClientUI m
          => [CStore] -> (CStore, [(ItemId, ItemFull)]) -> CStore
          -> m (FailOrCmd (RequestTimed 'AbMoveItem))
moveItems cLegalRaw (fromCStore, l) destCStore = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  let calmE = calmEnough b activeItems
      ret4 :: MonadClientUI m
           => [(ItemId, ItemFull)]
           -> Int -> [(ItemId, Int, CStore, CStore)]
           -> m (FailOrCmd [(ItemId, Int, CStore, CStore)])
      ret4 [] _ acc = return $ Right $ reverse acc
      ret4 ((iid, itemFull) : rest) oldN acc = do
        let k = itemK itemFull
            !_A = assert (k > 0) ()
            retRec toCStore =
              let n = oldN + if toCStore == CEqp then k else 0
              in ret4 rest n ((iid, k, fromCStore, toCStore) : acc)
        if cLegalRaw == [CGround]  -- normal pickup
        then case destCStore of
          CEqp | calmE && goesIntoSha itemFull ->
            retRec CSha
          CEqp | not $ goesIntoEqp itemFull ->
            retRec CInv
          CEqp | eqpOverfull b (oldN + k) -> do
            -- If this stack doesn't fit, we don't equip any part of it,
            -- but we may equip a smaller stack later in the same pickup.
            -- TODO: try to ask for a number of items, thus giving the player
            -- the option of picking up a part.
            let fullWarn = if eqpOverfull b (oldN + 1)
                           then EqpOverfull
                           else EqpStackFull
            msgAdd $ "Warning:" <+> showReqFailure fullWarn <> "."
            retRec $ if calmE then CSha else CInv
          _ ->
            retRec destCStore
        else case destCStore of
          CEqp | eqpOverfull b (oldN + k) -> do
            -- If the chosen number from the stack doesn't fit,
            -- we don't equip any part of it and we exit item manipulation.
            let fullWarn = if eqpOverfull b (oldN + 1)
                           then EqpOverfull
                           else EqpStackFull
            failSer fullWarn
          _ -> retRec destCStore
  if not calmE && CSha `elem` [fromCStore, destCStore]
  then failSer ItemNotCalm
  else do
    l4 <- ret4 l 0 []
    return $! case l4 of
      Left err -> Left err
      Right [] -> assert `failure` l
      Right lr -> Right $ ReqMoveItems lr

-- * Project

projectHuman :: MonadClientUI m
             => [Trigger] -> m (FailOrCmd (RequestTimed 'AbProject))
projectHuman ts = do
  itemSel <- getsSession sitemSel
  case itemSel of
    Just (fromCStore, iid) -> do
      leader <- getLeaderUI
      bag <- getsState $ getActorBag leader fromCStore
      case iid `EM.lookup` bag of
        Nothing -> do  -- used up
          modifySession $ \sess -> sess {sitemSel = Nothing}
          failWith "no item to fling"
        Just kit -> do
          itemToF <- itemToFullClient
          let i = (fromCStore, (iid, itemToF iid kit))
          projectItem ts i
    Nothing -> failWith "no item to fling"

projectItem :: MonadClientUI m
            => [Trigger] -> (CStore, (ItemId, ItemFull))
            -> m (FailOrCmd (RequestTimed 'AbProject))
projectItem ts (fromCStore, (iid, itemFull)) = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  let calmE = calmEnough b activeItems
  if not calmE && fromCStore == CSha then failSer ItemNotCalm
  else do
    mpsuitReq <- psuitReq ts
    case mpsuitReq of
      Left err -> failWith err
      Right psuitReqFun ->
        case psuitReqFun itemFull of
          Left reqFail -> failSer reqFail
          Right (pos, _) -> do
            -- Set personal target to the aim position, to easily repeat.
            mposTgt <- leaderTgtToPos
            unless (Just pos == mposTgt) $ do
              sxhair <- getsClient sxhair
              modifyClient $ updateTarget leader (const $ Just sxhair)
            -- Project.
            eps <- getsClient seps
            return $ Right $ ReqProject pos eps iid fromCStore

-- * Apply

-- TODO: factor out item getting
applyHuman :: MonadClientUI m
           => [Trigger] -> m (FailOrCmd (RequestTimed 'AbApply))
applyHuman ts = do
  itemSel <- getsSession sitemSel
  case itemSel of
    Just (fromCStore, iid) -> do
      leader <- getLeaderUI
      bag <- getsState $ getActorBag leader fromCStore
      case iid `EM.lookup` bag of
        Nothing -> do  -- used up
          modifySession $ \sess -> sess {sitemSel = Nothing}
          failWith "no item to apply"
        Just kit -> do
          itemToF <- itemToFullClient
          let i = (fromCStore, (iid, itemToF iid kit))
          applyItem ts i
    Nothing -> failWith "no item to apply"

applyItem :: MonadClientUI m
          => [Trigger] -> (CStore, (ItemId, ItemFull))
          -> m (FailOrCmd (RequestTimed 'AbApply))
applyItem ts (fromCStore, (iid, itemFull)) = do
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  activeItems <- activeItemsClient leader
  let calmE = calmEnough b activeItems
  if not calmE && fromCStore == CSha then failSer ItemNotCalm
  else do
    p <- permittedApplyClient $ triggerSymbols ts
    case p itemFull of
      Left reqFail -> failSer reqFail
      Right _ -> return $ Right $ ReqApply iid fromCStore

-- * AlterDir

-- TODO: accept mouse, too
-- | Ask for a direction and alter a tile, if possible.
alterDirHuman :: MonadClientUI m
              => [Trigger] -> m (FailOrCmd (RequestTimed 'AbAlter))
alterDirHuman ts = do
  Config{configVi, configLaptop} <- getsSession sconfig
  let verb1 = case ts of
        [] -> "alter"
        tr : _ -> verb tr
      keys = K.escKM
             : K.leftButtonReleaseKM
             : map (K.KM K.NoModifier) (K.dirAllKey configVi configLaptop)
      prompt = makePhrase
        ["Where to", verb1 <> "? [movement key] [LMB]"]
  promptAdd prompt
  slides <- reportToSlideshow [K.escKM]
  km <- getConfirms ColorFull keys slides
  case K.key km of
    K.LeftButtonRelease -> do
      leader <- getLeaderUI
      b <- getsState $ getActorBody leader
      Point x y <- getsSession spointer
      let dir = Point x (y -  mapStartY) `vectorToFrom` bpos b
      if isUnit dir
      then alterTile ts dir
      else failWith "never mind"
    _ ->
      case K.handleDir configVi configLaptop km of
        Nothing -> failWith "never mind"
        Just dir -> alterTile ts dir

-- | Player tries to alter a tile using a feature.
alterTile :: MonadClientUI m
          => [Trigger] -> Vector -> m (FailOrCmd (RequestTimed 'AbAlter))
alterTile ts dir = do
  cops@Kind.COps{cotile} <- getsState scops
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  actorSk <- actorSkillsClient leader
  lvl <- getLevel $ blid b
  as <- getsState $ actorList (const True) (blid b)
  let skill = EM.findWithDefault 0 AbAlter actorSk
      tpos = bpos b `shift` dir
      t = lvl `at` tpos
      alterFeats = alterFeatures ts
      verb1 = case ts of
        [] -> "alter"
        tr : _ -> verb tr
      msg = makeSentence ["you", verb1, "towards", MU.Text $ compassText dir]
  case filter (\feat -> Tile.hasFeature cotile feat t) alterFeats of
    _ | skill < 1 -> failSer AlterUnskilled
    [] -> failWith $ guessAlter cops alterFeats t
    feat : _ ->
      if EM.notMember tpos $ lfloor lvl then
        if unoccupied as tpos then do
          msgAdd msg
          return $ Right $ ReqAlter tpos $ Just feat
        else failSer AlterBlockActor
      else failSer AlterBlockItem

alterFeatures :: [Trigger] -> [TK.Feature]
alterFeatures [] = []
alterFeatures (AlterFeature{feature} : ts) = feature : alterFeatures ts
alterFeatures (_ : ts) = alterFeatures ts

-- | Guess and report why the bump command failed.
guessAlter :: Kind.COps -> [TK.Feature] -> Kind.Id TileKind -> Text
guessAlter Kind.COps{cotile} (TK.OpenTo _ : _) t
  | Tile.isClosable cotile t = "already open"
guessAlter _ (TK.OpenTo _ : _) _ = "cannot be opened"
guessAlter Kind.COps{cotile} (TK.CloseTo _ : _) t
  | Tile.isOpenable cotile t = "already closed"
guessAlter _ (TK.CloseTo _ : _) _ = "cannot be closed"
guessAlter _ _ _ = "never mind"

-- * TriggerTile

-- | Leader tries to trigger the tile he's standing on.
triggerTileHuman :: MonadClientUI m
                 => [Trigger] -> m (FailOrCmd (RequestTimed 'AbTrigger))
triggerTileHuman ts = do
  cops@Kind.COps{cotile} <- getsState scops
  leader <- getLeaderUI
  b <- getsState $ getActorBody leader
  lvl <- getLevel $ blid b
  let t = lvl `at` bpos b
      triggerFeats = triggerFeatures ts
  case filter (\feat -> Tile.hasFeature cotile feat t) triggerFeats of
    [] -> failWith $ guessTrigger cops triggerFeats t
    feat : _ -> do
      go <- verifyTrigger leader feat
      case go of
        Right () -> return $ Right $ ReqTrigger feat
        Left err -> return $ Left err

triggerFeatures :: [Trigger] -> [TK.Feature]
triggerFeatures [] = []
triggerFeatures (TriggerFeature{feature} : ts) = feature : triggerFeatures ts
triggerFeatures (_ : ts) = triggerFeatures ts

-- | Verify important feature triggers, such as fleeing the dungeon.
verifyTrigger :: MonadClientUI m
              => ActorId -> TK.Feature -> m (FailOrCmd ())
verifyTrigger leader feat = case feat of
  TK.Cause IK.Escape{} -> do
    b <- getsState $ getActorBody leader
    side <- getsClient sside
    fact <- getsState $ (EM.! side) . sfactionD
    if not (fcanEscape $ gplayer fact) then failWith
      "This is the way out, but where would you go in this alien world?"
    else do
      go <- displayYesNo ColorFull
              "This is the way out. Really leave now?"
      if not go then failWith "game resumed"
      else do
        (_, total) <- getsState $ calculateTotal b
        if total == 0 then do
          -- The player can back off at each of these steps.
          go1 <- displayMore ColorBW
                   "Afraid of the challenge? Leaving so soon and empty-handed?"
          if not go1 then failWith "brave soul!"
          else do
             go2 <- displayMore ColorBW
                     "Next time try to grab some loot before escape!"
             if not go2 then failWith "here's your chance!"
             else return $ Right ()
        else return $ Right ()
  _ -> return $ Right ()

-- | Guess and report why the bump command failed.
guessTrigger :: Kind.COps -> [TK.Feature] -> Kind.Id TileKind -> Text
guessTrigger Kind.COps{cotile} fs@(TK.Cause (IK.Ascend k) : _) t
  | Tile.hasFeature cotile (TK.Cause (IK.Ascend (-k))) t =
    if | k > 0 -> "the way goes down, not up"
       | k < 0 -> "the way goes up, not down"
       | otherwise -> assert `failure` fs
guessTrigger _ fs@(TK.Cause (IK.Ascend k) : _) _ =
    if | k > 0 -> "cannot ascend"
       | k < 0 -> "cannot descend"
       | otherwise -> assert `failure` fs
guessTrigger _ _ _ = "never mind"

-- * Help

-- | Display command help.
helpHuman :: MonadClientUI m
          => (HumanCmd.HumanCmd -> m (Either MError RequestUI)) -> Maybe Text
          -> m (Either MError RequestUI)
helpHuman cmdAction mstart = do
  keyb <- getsSession sbinding
  let keyH = keyHelp keyb
  menuIxHelp <- case mstart of
    Nothing -> getsSession smenuIxHelp
    Just "" -> return 0
    Just t -> do
      let tkm = K.mkKM (T.unpack t)
          matchKeyOrSlot (Left km) = km == tkm
          matchKeyOrSlot (Right slot) = slotLabel slot == t
          mindex = findIndex (matchKeyOrSlot . fst) $ concat $ map snd $ slideshow keyH
      return $! fromMaybe 0 mindex
  (ekm, pointer) <-
    displayChoiceScreen ColorFull True menuIxHelp keyH [K.spaceKM, K.escKM]
  modifySession $ \sess -> sess {smenuIxHelp = pointer}
  case ekm of
    Left km -> case km `M.lookup` bcmdMap keyb of
      _ | km `K.elemOrNull` [K.spaceKM, K.escKM] -> return $ Left Nothing
      Just (_desc, _cats, cmd) -> cmdAction cmd
      Nothing -> weaveJust <$> failWith "never mind"
    Right _slot -> assert `failure` ekm

-- * MainMenu

-- TODO: avoid String
-- | Display the main menu.
mainMenuHuman :: MonadClientUI m
              => (HumanCmd.HumanCmd -> m (Either MError RequestUI))
              -> m (Either MError RequestUI)
mainMenuHuman cmdAction = do
  Kind.COps{corule} <- getsState scops
  Binding{bcmdList} <- getsSession sbinding
  gameMode <- getGameMode
  scurDiff <- getsClient scurDiff
  snxtDiff <- getsClient snxtDiff
  let stripFrame t = tail . init $ T.lines t
      pasteVersion art =
        let pathsVersion = rpathsVersion $ Kind.stdRuleset corule
            version = " Version " ++ showVersion pathsVersion
                      ++ " (frontend: " ++ frontendName
                      ++ ", engine: LambdaHack " ++ showVersion Self.version
                      ++ ") "
            versionLen = length version
        in init art ++ [take (80 - versionLen) (last art) ++ version]
      -- Key-description-command tuples.
      kds = [ (km, (desc, cmd))
            | (km, ([HumanCmd.CmdMainMenu], desc, cmd)) <- bcmdList ]
      statusLen = 30
      bindingLen = 28
      gameName = makePhrase [MU.Capitalize $ MU.Text $ mname gameMode]
      gameInfo = [ T.justifyLeft statusLen ' '
                   $ "Current scenario:" <+> gameName
                 , T.justifyLeft statusLen ' '
                   $ "Current game difficulty:" <+> tshow scurDiff
                 , T.justifyLeft statusLen ' '
                   $ "Next game difficulty:" <+> tshow snxtDiff
                 , T.justifyLeft statusLen ' ' "" ]
      emptyInfo = repeat $ T.justifyLeft bindingLen ' ' ""
      bindings =  -- key bindings to display
        let fmt (k, (d, _)) =
              ( Just k
              , T.justifyLeft bindingLen ' '
                  $ T.justifyLeft 3 ' ' (K.showKM k) <> " " <> d )
        in map fmt kds
      overwrite =  -- overwrite the art with key bindings and other lines
        let over [] (_, line) = ([], (T.pack line, Nothing))
            over bs@((mkey, binding) : bsRest) (y, line) =
              let (prefix, lineRest) = break (=='{') line
                  (braces, suffix)   = span  (=='{') lineRest
              in if length braces >= bindingLen
                 then
                   let lenB = T.length binding
                       pre = T.pack prefix
                       post = T.drop (lenB - length braces) (T.pack suffix)
                       len = T.length pre
                       yxx key = (Left key, (y, len, len + lenB))
                       myxx = yxx <$> mkey
                   in (bsRest, (pre <> binding <> post, myxx))
                 else (bs, (T.pack line, Nothing))
        in snd . mapAccumL over (zip (repeat Nothing) gameInfo
                                 ++ bindings
                                 ++ zip (repeat Nothing) emptyInfo)
      mainMenuArt = rmainMenuArt $ Kind.stdRuleset corule
      artWithVersion = pasteVersion $ map T.unpack $ stripFrame mainMenuArt
      menuOverwritten = overwrite $ zip [0..] artWithVersion
      (menuOvLines, mkyxs) = unzip menuOverwritten
      kyxs = catMaybes mkyxs
      ov = map toAttrLine menuOvLines
  isNoConfirms <- isNoConfirmsGame
  -- TODO: pick the first game that was not yet won
  menuIxMain <- if isNoConfirms then return 4 else getsSession smenuIxMain
  (ekm, pointer) <- displayChoiceScreen ColorFull True menuIxMain (menuToSlideshow (ov, kyxs)) []
  modifySession $ \sess -> sess {smenuIxMain = pointer}
  case ekm of
    Left km -> case km `lookup` kds of
      Just (_desc, cmd) -> cmdAction cmd
      Nothing -> weaveJust <$> failWith "never mind"
    Right _slot -> assert `failure` ekm

-- * GameDifficultyIncr

gameDifficultyIncr :: MonadClientUI m => m ()
gameDifficultyIncr = do
  let delta = 1
  snxtDiff <- getsClient snxtDiff
  let d | snxtDiff + delta > difficultyBound = 1
        | snxtDiff + delta < 1 = difficultyBound
        | otherwise = snxtDiff + delta
  modifyClient $ \cli -> cli {snxtDiff = d}

-- * GameRestart

gameRestartHuman :: MonadClientUI m
                 => GroupName ModeKind -> m (FailOrCmd RequestUI)
gameRestartHuman t = do
  isNoConfirms <- isNoConfirmsGame
  gameMode <- getGameMode
  b <- if isNoConfirms
       then return True
       else displayYesNo ColorBW
            $ "You just requested a new" <+> tshow t
              <+> "game. The progress of the current" <+> mname gameMode
              <+> "game will be lost! Are you sure?"
  if b
  then do
    leader <- getLeaderUI
    snxtDiff <- getsClient snxtDiff
    Config{configHeroNames} <- getsSession sconfig
    return $ Right
           $ ReqUIGameRestart leader t snxtDiff configHeroNames
  else do
    msg2 <- rndToAction $ oneOf
              [ "yea, would be a pity to leave them all to die"
              , "yea, a shame to get your team stranded" ]
    failWith msg2

-- * GameExit

gameExitHuman :: MonadClientUI m => m (FailOrCmd RequestUI)
gameExitHuman = do
  leader <- getLeaderUI
  return $ Right $ ReqUIGameExit leader

-- * GameSave

gameSaveHuman :: MonadClientUI m => m RequestUI
gameSaveHuman = do
  -- Announce before the saving started, since it can take some time
  -- and may slow down the machine, even if not block the client.
  -- TODO: do not save to history:
  msgAdd "Saving game backup."
  return ReqUIGameSave

-- * Tactic

-- Note that the difference between seek-target and follow-the-leader tactic
-- can influence even a faction with passive actors. E.g., if a passive actor
-- has an extra active skill from equipment, he moves every turn.
-- TODO: set tactic for allied passive factions, too or all allied factions
-- and perhaps even factions with a leader should follow our leader
-- and his target, not their leader.
tacticHuman :: MonadClientUI m => m (FailOrCmd RequestUI)
tacticHuman = do
  fid <- getsClient sside
  fromT <- getsState $ ftactic . gplayer . (EM.! fid) . sfactionD
  let toT = if fromT == maxBound then minBound else succ fromT
  go <- displayMore ColorFull
        $ "Current tactic is '" <> tshow fromT
          <> "'. Switching tactic to '" <> tshow toT
          <> "'. (This clears targets.)"
  if not go
    then failWith "tactic change canceled"
    else return $ Right $ ReqUITactic toT

-- * Automate

automateHuman :: MonadClientUI m => m (FailOrCmd RequestUI)
automateHuman = do
  -- BFS is not updated while automated, which would lead to corruption.
  modifySession $ \sess -> sess {saimMode = Nothing}
  go <- displayMore ColorBW
          "Ceding control to AI (press any key to regain)."
  if not go
    then failWith "automation canceled"
    else return $ Right ReqUIAutomate