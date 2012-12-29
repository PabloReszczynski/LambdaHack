{-# LANGUAGE OverloadedStrings #-}
-- | Saving and restoring games and player diaries.
module Game.LambdaHack.Action.Save
  ( saveGameFile, restoreGame, rmBkpSaveHistory, saveGameBkp
  ) where

import Control.Concurrent
import qualified Control.Exception as Ex hiding (handle)
import Control.Monad
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory
import System.FilePath
import System.IO.Unsafe (unsafePerformIO)

import Game.LambdaHack.Config
import Game.LambdaHack.Msg
import Game.LambdaHack.State
import Game.LambdaHack.Utils.File

-- | Save player history.
saveHistory :: FilePath -> StateClient -> IO ()
saveHistory configHistoryFile cli =
  encodeEOF configHistoryFile (shistory cli)

saveLock :: MVar ()
{-# NOINLINE saveLock #-}
saveLock = unsafePerformIO newEmptyMVar

-- | Save a simple serialized version of the current state.
-- Protected by a lock to avoid corrupting the file.
saveGameFile :: ConfigUI -> State -> StateServer -> StateClient -> State
             -> IO ()
saveGameFile ConfigUI{configSaveFile} state ser cli loc = do
  putMVar saveLock ()
  encodeEOF configSaveFile (state, ser, cli, loc)
  takeMVar saveLock

-- | Try to create a directory. Hide errors due to,
-- e.g., insufficient permissions, because the game can run
-- in the current directory just as well.
tryCreateDir :: FilePath -> IO ()
tryCreateDir dir =
  Ex.catch
    (createDirectory dir)
    (\ e -> case e :: Ex.IOException of _ -> return ())

-- | Try to copy over data files. Hide errors due to,
-- e.g., insufficient permissions, because the game can run
-- without data files just as well.
tryCopyDataFiles :: ConfigUI -> (FilePath -> IO FilePath) -> IO ()
tryCopyDataFiles ConfigUI{ configScoresFile
                         , configRulesCfgFile
                         , configUICfgFile } pathsDataFile = do
  rulesFile  <- pathsDataFile $ takeFileName configRulesCfgFile <.> ".default"
  uiFile     <- pathsDataFile $ takeFileName configUICfgFile    <.> ".default"
  scoresFile <- pathsDataFile $ takeFileName configScoresFile
  let newRulesFile  = configRulesCfgFile <.> ".ini"
      newUIFile     = configUICfgFile    <.> ".ini"
      newScoresFile = configScoresFile
  Ex.catch
    (copyFile rulesFile newRulesFile >>
     copyFile uiFile newUIFile >>
     copyFile scoresFile newScoresFile)
    (\ e -> case e :: Ex.IOException of _ -> return ())

-- | Restore a saved game, if it exists. Initialize directory structure,
-- if needed.
restoreGame :: ConfigUI -> (FilePath -> IO FilePath) -> Text
            -> IO (Either (State, StateServer, StateClient, State, Msg)
                          (History, Msg))
restoreGame config@ConfigUI{ configAppDataDir
                           , configHistoryFile
                           , configSaveFile
                           , configBkpFile } pathsDataFile title = do
  ab <- doesDirectoryExist configAppDataDir
  -- If the directory can't be created, the current directory will be used.
  unless ab $ do
    tryCreateDir configAppDataDir
    -- Possibly copy over data files. No problem if it fails.
    tryCopyDataFiles config pathsDataFile
  -- If the cli file does not exist, create an empty cli.
  -- TODO: when cli gets corrupted, start a new one, too.
  shistory <-
    do db <- doesFileExist configHistoryFile
       if db
         then strictDecodeEOF configHistoryFile
         else defaultHistory
  -- If the savefile exists but we get IO errors, we show them,
  -- back up the savefile and move it out of the way and start a new game.
  -- If the savefile was randomly corrupted or made read-only,
  -- that should solve the problem. If the problems are more serious,
  -- the other functions will most probably also throw exceptions,
  -- this time without trying to fix it up.
  sb <- doesFileExist configSaveFile
  bb <- doesFileExist configBkpFile
  Ex.catch
    (if sb
       then do
         renameFile configSaveFile configBkpFile
         (state, ser, cli, loc) <- strictDecodeEOF configBkpFile
         let msg = "Welcome back to" <+> title <> "."
         return $ Left (state, ser, cli {shistory}, loc, msg)
       else
         if bb
           then do
             (state, ser, cli, loc) <- strictDecodeEOF configBkpFile
             let msg = "No savefile found. Restoring from a backup savefile."
             return $ Left (state, ser, cli {shistory}, loc, msg)
           else return $ Right (shistory, "Welcome to" <+> title <> "!"))
    (\ e -> case e :: Ex.SomeException of
              _ -> let msg = "Starting a new game, because restore failed."
                             <+> "The error message was:"
                             <+> (T.unwords . T.lines) (showT e)
                   in return $ Right (shistory, msg))

-- | Save the cli and a backup of the save game file, in case of crashes.
-- This is only a backup, so no problem is the game is shut down
-- before saving finishes, so we don't wait on the mvar. However,
-- if a previous save is already in progress, we skip this save.
saveGameBkp :: ConfigUI -> State -> StateServer -> StateClient -> State
            -> IO ()
saveGameBkp ConfigUI{ configHistoryFile
                    , configSaveFile
                    , configBkpFile } state ser cli loc = do
  b <- tryPutMVar saveLock ()
  when b $
    void $ forkIO $ do
      saveHistory configHistoryFile cli  -- save often in case of crashes
      encodeEOF configSaveFile (state, ser, cli, loc)
      renameFile configSaveFile configBkpFile
      takeMVar saveLock

-- | Remove the backup of the savegame and save the player cli.
-- Should be called before any non-error exit from the game.
-- Sometimes the backup file does not exist and it's OK.
-- We don't bother reporting any other removal exceptions, either,
-- because the backup file is relatively unimportant.
-- We wait on the mvar, because saving the cli at game shutdown is important.
rmBkpSaveHistory :: ConfigUI -> StateClient -> IO ()
rmBkpSaveHistory ConfigUI{ configHistoryFile
                         , configBkpFile } cli = do
  putMVar saveLock ()
  saveHistory configHistoryFile cli  -- save often in case of crashes
  bb <- doesFileExist configBkpFile
  when bb $ removeFile configBkpFile
  takeMVar saveLock
