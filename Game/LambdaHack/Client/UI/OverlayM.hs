-- | A set of Overlay monad operations.
module Game.LambdaHack.Client.UI.OverlayM
  ( describeMainKeys, lookAt
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.CommonM
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.HumanCmd
import Game.LambdaHack.Client.UI.KeyBindings
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.ItemDescription
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import qualified Game.LambdaHack.Content.TileKind as TK

describeMainKeys :: MonadClientUI m => m Text
describeMainKeys = do
  saimMode <- getsSession saimMode
  Binding{brevMap} <- getsSession sbinding
  Config{configVi, configLaptop} <- getsSession sconfig
  xhair <- getsClient sxhair
  let kmEscape = head $
        M.findWithDefault [K.KM K.NoModifier K.Esc]
                          ByAimMode {notAiming = MainMenu, aiming = Cancel}
                          brevMap
      kmReturn = head $
        M.findWithDefault [K.KM K.NoModifier K.Return]
                          ByAimMode{notAiming = Help $ Just "", aiming = Accept}
                          brevMap
      (mkp, moveKeys) | configVi = ("keypad or", "hjklyubn,")
                      | configLaptop = ("keypad or", "uk8o79jl,")
                      | otherwise = ("", "keypad keys,")
      tgtKind = case xhair of
        TEnemy _ True -> "at actor"
        TEnemy _ False -> "at enemy"
        TEnemyPos _ _ _ True -> "at actor"
        TEnemyPos _ _ _ False -> "at enemy"
        TPoint{} -> "at position"
        TVector{} -> "with a vector"
      keys | isNothing saimMode =
        "Explore with" <+> mkp <+> "keys or mouse: ["
        <> moveKeys
        <+> T.intercalate ", "
             (map K.showKM [kmReturn, kmEscape])
        <> "]"
           | otherwise =
        "Aim" <+> tgtKind <+> "with" <+> mkp <+> "keys or mouse: ["
        <> moveKeys
        <+> T.intercalate ", "
             (map K.showKM [kmReturn, kmEscape])
        <> "]"
  return $! keys

-- | Produces a textual description of the terrain and items at an already
-- explored position. Mute for unknown positions.
-- The detailed variant is for use in the aiming mode.
lookAt :: MonadClientUI m
       => Bool       -- ^ detailed?
       -> Text       -- ^ how to start tile description
       -> Bool       -- ^ can be seen right now?
       -> Point      -- ^ position to describe
       -> ActorId    -- ^ the actor that looks
       -> Text       -- ^ an extra sentence to print
       -> m Text
lookAt detailed tilePrefix canSee pos aid msg = do
  cops@Kind.COps{cotile=cotile@Kind.Ops{okind}} <- getsState scops
  itemToF <- itemToFullClient
  b <- getsState $ getActorBody aid
  saimMode <- getsSession saimMode
  let lidV = maybe (blid b) aimLevelId saimMode
  lvl <- getLevel lidV
  localTime <- getsState $ getLocalTime lidV
  subject <- partAidLeader aid
  is <- getsState $ getCBag $ CFloor lidV pos
  let verb = MU.Text $ if | pos == bpos b -> "stand on"
                          | canSee -> "notice"
                          | otherwise -> "remember"
  let nWs (iid, kit@(k, _)) = partItemWs k CGround localTime (itemToF iid kit)
      isd = if | EM.size is == 0 -> ""
               | EM.size is <= 2 ->
                 makeSentence [ MU.SubjectVerbSg subject verb
                              , MU.WWandW $ map nWs $ EM.assocs is]
               | otherwise ->
                 makeSentence [MU.Cardinal (EM.size is), "items here"]
      tile = lvl `at` pos
      obscured | knownLsecret lvl
                 && tile /= hideTile cops lvl pos = "partially obscured"
               | otherwise = ""
      tileText = obscured <+> TK.tname (okind tile)
      tilePart | T.null tilePrefix = MU.Text tileText
               | otherwise = MU.AW $ MU.Text tileText
      tileDesc = [MU.Text tilePrefix, tilePart]
  if | not (null (Tile.causeEffects cotile tile)) ->
       return $! makeSentence ("activable:" : tileDesc)
                 <+> msg <+> isd
     | detailed ->
       return $! makeSentence tileDesc
                 <+> msg <+> isd
     | otherwise ->
       return $! msg <+> isd