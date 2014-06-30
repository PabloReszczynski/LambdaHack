-- | The type of kinds of game modes for LambdaHack.
module Content.ModeKind ( cdefs ) where

import qualified Data.EnumMap.Strict as EM

import Game.LambdaHack.Common.ContentDef
import Game.LambdaHack.Content.ModeKind

cdefs :: ContentDef ModeKind
cdefs = ContentDef
  { getSymbol = msymbol
  , getName = mname
  , getFreq = mfreq
  , validate = validateModeKind
  , content =
      [campaign, duel, skirmish, ambush, battle, safari, pvp, coop, defense]
  }
campaign,        duel, skirmish, ambush, battle, safari, pvp, coop, defense :: ModeKind

campaign = ModeKind
  { msymbol  = 'a'
  , mname    = "campaign"
  , mfreq    = [("campaign", 1)]
  , mplayers = playersCampaign
  , mcaves   = cavesCampaign
  }

duel = ModeKind
  { msymbol  = 'u'
  , mname    = "duel"
  , mfreq    = [("duel", 1)]
  , mplayers = playersDuel
  , mcaves   = cavesSkirmish
  }

skirmish = ModeKind
  { msymbol  = 'k'
  , mname    = "skirmish"
  , mfreq    = [("skirmish", 1)]
  , mplayers = playersSkirmish
  , mcaves   = cavesSkirmish
  }

ambush = ModeKind
  { msymbol  = 'm'
  , mname    = "ambush"
  , mfreq    = [("ambush", 1)]
  , mplayers = playersSkirmish
  , mcaves   = cavesAmbush
  }

battle = ModeKind
  { msymbol  = 'b'
  , mname    = "battle"
  , mfreq    = [("battle", 1)]
  , mplayers = playersBattle
  , mcaves   = cavesBattle
  }

safari = ModeKind
  { msymbol  = 'f'
  , mname    = "safari"
  , mfreq    = [("safari", 1)]
  , mplayers = playersSafari
  , mcaves   = cavesSafari
  }

pvp = ModeKind
  { msymbol  = 'v'
  , mname    = "PvP"
  , mfreq    = [("PvP", 1)]
  , mplayers = playersPvP
  , mcaves   = cavesSkirmish
  }

coop = ModeKind
  { msymbol  = 'o'
  , mname    = "Coop"
  , mfreq    = [("Coop", 1)]
  , mplayers = playersCoop
  , mcaves   = cavesCampaign
  }

defense = ModeKind
  { msymbol  = 'e'
  , mname    = "defense"
  , mfreq    = [("defense", 1)]
  , mplayers = playersDefense
  , mcaves   = cavesCampaign
  }


playersCampaign, playersDuel, playersSkirmish, playersBattle, playersSafari, playersPvP, playersCoop, playersDefense :: Players

playersCampaign = Players
  { playersList = [ playerHero
                  , playerMonster
                  , playerAnimal ]
  , playersEnemy = [ ("Adventurer Party", "Monster Hive")
                   , ("Adventurer Party", "Animal Kingdom") ]
  , playersAlly = [("Monster Hive", "Animal Kingdom")] }

playersDuel = Players
  { playersList = [ playerHero { playerName = "White"
                               , playerInitial = 1 }
                  , playerAntiHero { playerName = "Purple"
                                   , playerInitial = 1 }
                  , playerHorror ]
  , playersEnemy = [ ("White", "Purple")
                   , ("White", "Horror Den")
                   , ("Purple", "Horror Den") ]
  , playersAlly = [] }

playersSkirmish = playersDuel
  { playersList = [ playerHero {playerName = "White"}
                  , playerAntiHero {playerName = "Purple"}
                  , playerHorror ] }

playersBattle = Players
  { playersList = [ playerHero {playerInitial = 5}
                  , playerMonster { playerInitial = 20
                                  , playerSpawn = 0 }
                  , playerAnimal { playerInitial = 10
                                 , playerSpawn = 0 } ]
  , playersEnemy = [ ("Adventurer Party", "Monster Hive")
                   , ("Adventurer Party", "Animal Kingdom") ]
  , playersAlly = [("Monster Hive", "Animal Kingdom")] }

playersSafari = Players
  { playersList = [ playerMonster { playerName = "Monster Tourist Office"
                                  , playerSpawn = 0
                                  , playerEntry = -8
                                  , playerInitial = 10
                                  , playerAI = False
                                  , playerUI = True }
                  , playerCivilian { playerName = "Hunam Convict Pack"
                                   , playerEntry = -8 }
                  , playerAnimal { playerName =
                                     "Animal Magnificent Specimen Variety"
                                 , playerSpawn = 0
                                 , playerEntry = -9
                                 , playerInitial = 7 }
                  , playerAnimal { playerName =
                                     "Animal Exquisite Herds and Packs"
                                 , playerSpawn = 0
                                 , playerEntry = -10
                                 , playerInitial = 20 } ]
  , playersEnemy = [ ("Monster Tourist Office", "Hunam Convict Pack")
                   , ("Monster Tourist Office",
                      "Animal Magnificent Specimen Variety")
                   , ("Monster Tourist Office",
                      "Animal Exquisite Herds and Packs") ]
  , playersAlly = [( "Animal Magnificent Specimen Variety"
                   , "Animal Exquisite Herds and Packs" )] }

playersPvP = Players
  { playersList = [ playerHero {playerName = "Red"}
                  , playerHero {playerName = "Blue"}
                  , playerHorror ]
  , playersEnemy = [ ("Red", "Blue")
                   , ("Red", "Horror Den")
                   , ("Blue", "Horror Den") ]
  , playersAlly = [] }

playersCoop = Players
  { playersList = [ playerAntiHero { playerName = "Coral" }
                  , playerAntiHero { playerName = "Amber" }
                  , playerAntiHero { playerName = "Green" }
                  , playerAntiHero { playerName = "Yellow" }
                  , playerAntiHero { playerName = "Cyan" }
                  , playerAntiHero { playerName = "Red"
                                   , playerLeader = False }
                  , playerAntiHero { playerName = "Blue"
                                   , playerLeader = False }
                  , playerAnimal { playerUI = True }
                  , playerMonster
                  , playerMonster { playerName = "Leaderless Monster Hive"
                                  , playerLeader = False } ]
  , playersEnemy = [ ("Coral", "Monster Hive")
                   , ("Amber", "Monster Hive")
                   , ("Green", "Monster Hive")
                   , ("Yellow", "Monster Hive")
                   , ("Cyan", "Monster Hive")
                   , ("Red", "Monster Hive")
                   , ("Blue", "Monster Hive")
                   , ("Animal Kingdom", "Leaderless Monster Hive") ]
  , playersAlly = [ ("Coral", "Amber")
                  , ("Green", "Yellow")
                  , ("Green", "Cyan")
                  , ("Yellow", "Cyan") ] }

playersDefense = Players
  { playersList = [ playerMonster { playerInitial = 1
                                  , playerAI = False
                                  , playerUI = True }
                  , playerAntiHero { playerName = "Yellow"
                                   , playerInitial = 10 }
                  , playerAnimal ]
  , playersEnemy = [ ("Yellow", "Monster Hive")
                   , ("Yellow", "Animal Kingdom") ]
  , playersAlly = [("Monster Hive", "Animal Kingdom")] }

playerHero, playerAntiHero, playerCivilian, playerMonster, playerAnimal, playerHorror :: Player

playerHero = Player
  { playerName = "Adventurer Party"
  , playerFaction = "hero"
  , playerSpawn = 0
  , playerEntry = -1
  , playerInitial = 3
  , playerLeader = True
  , playerAI = False
  , playerUI = True
  }

playerAntiHero = playerHero
  { playerAI = True
  , playerUI = False
  }

playerCivilian = Player
  { playerName = "Civilian Crowd"
  , playerFaction = "civilian"
  , playerSpawn = 0
  , playerEntry = -1
  , playerInitial = 3
  , playerLeader = False  -- unorganized
  , playerAI = True
  , playerUI = False
  }

playerMonster = Player
  { playerName = "Monster Hive"
  , playerFaction = "monster"
  , playerSpawn = 66
  , playerEntry = -3
  , playerInitial = 5
  , playerLeader = True
  , playerAI = True
  , playerUI = False
  }

playerAnimal = Player
  { playerName = "Animal Kingdom"
  , playerFaction = "animal"
  , playerSpawn = 33
  , playerEntry = -2
  , playerInitial = 3
  , playerLeader = False
  , playerAI = True
  , playerUI = False
  }

playerHorror = Player
  { playerName = "Horror Den"
  , playerFaction = "horror"
  , playerSpawn = 0
  , playerEntry = -1
  , playerInitial = 0
  , playerLeader = False
  , playerAI = True
  , playerUI = False
  }


cavesCampaign, cavesSkirmish, cavesAmbush, cavesBattle, cavesSafari :: Caves

cavesCampaign = EM.fromList [ (-1, ("caveRogue", Just True))
                            , (-2, ("caveRogue", Nothing))
                            , (-3, ("caveEmpty", Nothing))
                            , (-10, ("caveNoise", Nothing))]

cavesSkirmish = EM.fromList [(-3, ("caveSkirmish", Nothing))]

cavesAmbush = EM.fromList [(-5, ("caveAmbush", Nothing))]

cavesBattle = EM.fromList [(-3, ("caveBattle", Nothing))]

cavesSafari = EM.fromList [ (-8, ("caveAmbush", Nothing))
                          , (-9, ("caveBattle", Nothing))
                          , (-10, ("caveSkirmish", Just False)) ]
