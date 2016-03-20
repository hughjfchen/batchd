{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Dispatcher (runDispatcher) where

import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Monad.Reader
import Control.Monad.IO.Class  (MonadIO, liftIO)
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.Trans.Resource
import Control.Monad.Logger (runNoLoggingT, runStdoutLoggingT)
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Yaml
import Data.Default
import Data.Time
import Data.Dates
import Database.Persist
import qualified Database.Persist.Sql as Sql
import qualified Database.Persist.Sqlite as Sqlite
import System.Environment
import System.Exit
import Text.Printf

import CommonTypes
import Types
import Config
import Database
import Schedule
import Executor

runDispatcher :: IO ()
runDispatcher = do
  cfgR <- loadDbConfig
  case cfgR of
    Left err -> fail $ show err
    Right cfg -> do
      pool <- getPool cfg
      let connInfo = ConnectionInfo cfg pool
      Sql.runSqlPool (Sql.runMigration migrateAll) (ciPool connInfo)
      jobsChan <- newChan
      resChan <- newChan
      forM_ [1..5] $ \idx ->
        forkIO $ worker idx jobsChan resChan
      forkIO $ runReaderT (runConnection (callbackListener resChan)) connInfo
      runReaderT (runConnection (dispatcher jobsChan)) connInfo

dispatcher :: Chan (Queue, JobInfo) -> ConnectionM ()
dispatcher jobsChan = do
  forever $ do
    qesr <- runDB getAllQueues
    case qesr of
      Left err -> liftIO $ print err
      Right qes -> do
        forM_ qes $ \qe -> runDB $ do
          schedule <- loadSchedule (queueSchedule $ entityVal qe)
          now <- liftIO $ getCurrentDateTime
          when (schedule `allows` now) $ do
              let QueueKey qname = entityKey qe
              mbJob <- getNextJob (entityKey qe)
              case mbJob of
                Nothing -> liftIO $ print $ "Queue " ++ qname ++ " exhaused."
                Just job -> do
                    setJobStatus job Processing
                    liftIO $ writeChan jobsChan (entityVal qe, job)
        liftIO $ threadDelay $ 10 * 1000*1000

callbackListener :: Chan (JobInfo, JobResult, OnFailAction) -> ConnectionM ()
callbackListener resChan = forever $ do
  (job, result, onFail) <- liftIO $ readChan resChan
  runDB $ do
      insert_ result
      if jobResultExitCode result == ExitSuccess
        then setJobStatus job Done
        else case onFail of
               Continue -> setJobStatus job Failed
               RetryNow m -> do
                  count <- increaseTryCount job
                  if count <= m
                    then do
                      liftIO $ putStrLn "Retry now"
                      setJobStatus job New
                    else setJobStatus job Failed
               RetryLater m -> do
                  count <- increaseTryCount job
                  if count <= m
                    then do
                      liftIO $ putStrLn "Retry later"
                      moveToEnd job
                    else setJobStatus job Failed


loadTemplateDb :: String -> DB JobType
loadTemplateDb name = do
  r <- liftIO $ Config.loadTemplate name
  case r of
    Left err -> throwR err
    Right jt -> return jt

worker :: Int -> Chan (Queue, JobInfo) -> Chan (JobInfo, JobResult, OnFailAction) -> IO ()
worker idx jobsChan resChan = forever $ do
  (queue, job) <- readChan jobsChan
  printf "[%d] got job #%d\n" idx (jiId job)
  jtypeR <- Config.loadTemplate (jiType job)
  (result, onFail) <-
      case jtypeR of
              Left err -> do
                  printf "[%d] invalid job type %s: %s\n" idx (jiType job) (show err)
                  let jid = JobKey (Sql.SqlBackendKey $ jiId job)
                  now <- getCurrentTime
                  let res = JobResult jid now (ExitFailure (-1)) T.empty (T.pack $ show err)
                  return (res, Continue)

              Right jtype -> do
                  res <- executeJob queue jtype job
                  return (res, jtOnFail jtype)

  writeChan resChan (job, result, onFail)
  printf "[%d] done job #%d\n" idx (jiId job)

process :: Queue -> JobInfo -> DB ()
process queue job = do
  liftIO $ print job
  lockJob job
  setJobStatus job Processing
  jtype <- loadTemplateDb (jiType job)
  result <- liftIO $ executeJob queue jtype job
  insert_ result
  if jobResultExitCode result == ExitSuccess
    then setJobStatus job Done
    else case jtOnFail jtype of
           Continue -> setJobStatus job Failed
           RetryNow m -> do
              count <- increaseTryCount job
              if count <= m
                then do
                  liftIO $ putStrLn "Retry now"
                  setJobStatus job New
                else setJobStatus job Failed
           RetryLater m -> do
              count <- increaseTryCount job
              if count <= m
                then do
                  liftIO $ putStrLn "Retry later"
                  moveToEnd job
                else setJobStatus job Failed
              
  

