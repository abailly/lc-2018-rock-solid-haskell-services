{-# LANGUAGE GeneralizedNewtypeDeriving  #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Main where

import RIO
import RIO.Orphans ()
import qualified RIO.Text as Text

import Data.FileEmbed (embedFile)
import qualified System.Etc as Etc

import Data.Aeson ((.:))
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Types as JSON (Parser)

import Data.Pool (Pool)
import Database.Persist.Sql (runMigration, runSqlPool)
import Database.Persist.Postgresql (SqlBackend, ConnectionString, withPostgresqlPool)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Control.Monad.Logger (MonadLogger)


--------------------------------------------------------------------------------
-- Data Structures

data SimpleApp =
  SimpleApp {
      appLogFunc :: LogFunc
    , appDbPool   :: Pool SqlBackend
    }

instance HasLogFunc SimpleApp where
  logFuncL = lens appLogFunc $ \x y -> x { appLogFunc = y }

--------------------------------------------------------------------------------
-- Configuration

specBytes :: ByteString
specBytes =
  $(embedFile "./config/spec.yaml")

parseConfigSpec :: MonadThrow m => m (Etc.ConfigSpec ())
parseConfigSpec =
  case Text.decodeUtf8' specBytes of
    Left err -> throwM err
    Right result -> Etc.parseConfigSpec result

resolveConfigSpec :: Etc.ConfigSpec () -> IO (Etc.Config, Vector SomeException)
resolveConfigSpec configSpec = do
  let
    defaultConfig = Etc.resolveDefault configSpec

  (fileConfig, fileWarnings) <- Etc.resolveFiles configSpec
  envConfig <- Etc.resolveEnv configSpec
  cliConfig <- Etc.resolvePlainCli configSpec

  return ( defaultConfig <> fileConfig <> envConfig <> cliConfig
         , fileWarnings
         )

buildConfig :: IO (Etc.Config, Vector SomeException)
buildConfig = do
  configSpec <- parseConfigSpec
  resolveConfigSpec configSpec

--------------------------------------------------------------------------------
-- Database

share [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
   Person
     name String
     age Int Maybe
     deriving Show
  |]

parseConnString :: JSON.Value -> JSON.Parser ByteString
parseConnString = JSON.withObject "ConnString" $ \obj -> do
  -- TODO: Some other settings are missing
  user <- obj .: "username"
  password <- obj .: "password"
  database <- obj .: "database"
  host     <- obj .: "host"
  return $
    Text.encodeUtf8
    $ Text.unwords [ "user=" <> user
                   , "password=" <> password
                   , "dbname=" <> database
                   , "host=" <> host
                   ]

withDatabasePool
  :: ( MonadUnliftIO m
     , MonadLogger m
     , MonadThrow m
     , MonadIO m
     ) => Etc.Config -> (Pool SqlBackend -> m a) -> m a
withDatabasePool config action = do
  connString <- Etc.getConfigValueWith parseConnString ["database"] config
  -- TODO: Fetch pool size from the configuration
  -- http://hackage.haskell.org/package/etc-0.4.0.1/docs/System-Etc.html#v:getConfigValue
  withPostgresqlPool connString 1 action

--------------------------------------------------------------------------------
-- Logging

parseLogHandle :: JSON.Value -> JSON.Parser Handle
parseLogHandle = JSON.withText "IOHandle" $ \_handleText ->
  -- TODO: Make sure we parse the text and return the correct handle
  return stdout

buildLogOptions :: Etc.Config -> IO LogOptions
buildLogOptions _config = do
  -- TODO: Get logging out of the config, make sure you use parseLogHandle
  logOptionsHandle stdout True

--------------------------------------------------------------------------------
-- Main

main :: IO ()
main = do
  (config, _fileWarnings) <- buildConfig
  logOptions <- buildLogOptions config

  withLogFunc logOptions $ \logFunc -> do
    runRIO logFunc $ withDatabasePool config $ \sqlPool ->
      liftIO $ runRIO (SimpleApp logFunc sqlPool) $ do
        configOutput <- Etc.renderConfig config
        runSqlPool (runMigration migrateAll) sqlPool
        -- TODO: Log file warnings
        logInfo $ "Configuation\n" <> (displayShow configOutput)
