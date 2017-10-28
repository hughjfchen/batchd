{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}

import Data.Semigroup ((<>))
import Options.Applicative
import Data.Text.Format.Heavy
import System.Log.Heavy

import System.Batchd.Common.Types
import System.Batchd.Common.Localize
import System.Batchd.Common.Config
import System.Batchd.Daemon.Types (runDaemon, forkDaemon, setupTranslations)
import qualified Daemon.Logging as Log
import Daemon.Database
import Daemon.Manager as Manager
import Daemon.Dispatcher as Dispatcher

parser :: Parser DaemonMode
parser =
  hsubparser
    (  command "both"       (info (pure Both) (progDesc "run both manager and dispatcher"))
    <> command "manager"    (info (pure Manager) (progDesc "run manager"))
    <> command "dispatcher" (info (pure Dispatcher) (progDesc "run dispatcher"))
    )
  <|> pure Both

parserInfo :: ParserInfo DaemonMode
parserInfo = info (parser <**> helper)
               (fullDesc
               <> header "batchd - the batchd toolset daemon server-side program"
               <> progDesc "process client requests and / or execute batch jobs" )

main :: IO ()
main = do
  cmd <- execParser parserInfo
  cfgR <- loadGlobalConfig
  case cfgR of
    Left err -> fail $ show err
    Right cfg -> do
      let mode = if cmd == Both
                   then dbcDaemonMode cfg
                   else cmd
      let logSettings = Log.getLoggingSettings cfg
      runDaemon cfg Nothing logSettings $ do
        System.Batchd.Daemon.Types.setupTranslations translationPolicy
        tr <- getTranslations
        $(Log.debug) "Loaded translations: {}" (Single $ show tr)
        $(Log.debug) "Loaded global configuration file: {}" (Single $ show cfg)
        connectPool
        case mode of
          Manager    -> Manager.runManager
          Dispatcher -> Dispatcher.runDispatcher
          Both -> do
            forkDaemon $ Manager.runManager
            Dispatcher.runDispatcher

