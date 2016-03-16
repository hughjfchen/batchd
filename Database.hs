{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
module Database where

import GHC.Generics
import Control.Monad
import Data.Generics hiding (Generic)
import Data.List (isPrefixOf)
import Data.Char
import Data.Maybe
import Data.Dates
import Data.Time
import Data.Aeson
import Data.Aeson.Types

import           Control.Monad.IO.Class  (liftIO)
import Control.Monad.Logger (runNoLoggingT, runStdoutLoggingT)
import           Database.Persist
import           Database.Persist.Sql as Sql
import           Database.Persist.Sqlite as Sqlite
import           Database.Persist.TH
import qualified Database.Esqueleto as E
import Database.Esqueleto ((^.))

import Types

getPool :: IO Sql.ConnectionPool
getPool = runStdoutLoggingT (Sqlite.createSqlitePool "test.db" 4)

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
JobParam json
  jobId JobId
  name String
  value String
  UniqParam jobId name

Job
  type String
  queueId QueueId
  seq Int
  status JobStatus default=New
  UniqJobSeq queueId seq

Queue
  name String
  scheduleId ScheduleId
  UniqQueue name

Schedule
  name String

ScheduleTime
  scheduleId ScheduleId
  begin TimeOfDay
  end TimeOfDay

ScheduleWeekDay
  scheduleId ScheduleId
  weekDay WeekDay
|]

deriving instance Eq ScheduleTime
deriving instance Show ScheduleTime

data JobInfo = JobInfo {
    jiType :: String,
    jiSeq :: Int,
    jiStatus :: JobStatus,
    jiParams :: [JobParam]
  }
  deriving (Generic)

stripPrefix :: String -> String -> String
stripPrefix prefix str =
  if prefix `isPrefixOf` str
    then drop (length prefix) str
    else str

camelCaseToUnderscore :: String -> String
camelCaseToUnderscore = go False
  where
    go _ [] = []
    go False (x:xs) = toLower x : go True xs
    go True (x:xs)
      | isUpper x = '_' : toLower x : go True xs
      | otherwise = x : go True xs

instance ToJSON JobInfo where
  toJSON = genericToJSON (defaultOptions {fieldLabelModifier = camelCaseToUnderscore . stripPrefix "ji"})

instance FromJSON JobInfo where
  parseJSON = genericParseJSON (defaultOptions {fieldLabelModifier = camelCaseToUnderscore . stripPrefix "ji"})

loadJob :: Key Job -> DB JobInfo
loadJob jid = do
  mbJob <- get jid
  case mbJob of
    Nothing -> throwR JobNotExists
    Just j -> do
      ps <- selectList [JobParamJobId ==. jid] []
      let params = map entityVal ps
      return $ JobInfo (jobType j) (jobSeq j) (jobStatus j) params

getAllQueues :: DB [Entity Queue]
getAllQueues = selectList [] []

getAllJobs :: Key Queue -> DB [Entity Job]
getAllJobs qid = selectList [JobQueueId ==. qid] [Asc JobSeq]

getJobs :: String -> Maybe JobStatus -> DB [Entity Job]
getJobs qname mbStatus = do
  let filt = case mbStatus of
               Nothing -> []
               Just status -> [JobStatus ==. status]
  qr <- getQueue qname
  case qr of
    Nothing -> throwR QueueNotExists
    Just qe -> selectList ([JobQueueId ==. entityKey qe] ++ filt) [Asc JobSeq]

loadJobs :: String -> Maybe JobStatus -> DB [JobInfo]
loadJobs qname mbStatus = do
  jes <- getJobs qname mbStatus
  forM jes $ \je -> do
    loadJob (entityKey je)

equals = (E.==.)
infix 4 `equals`

getLastJobSeq :: Key Queue -> DB Int
getLastJobSeq qid = do
  lst <- E.select $
         E.from $ \job -> do
         E.where_ (job ^. JobQueueId `equals` E.val qid)
         return $ E.max_ (job ^. JobSeq)
  case map E.unValue lst of
    (Just r:_) -> return r
    _ -> return 0

deleteQueue :: String -> Bool -> DB ()
deleteQueue name forced = do
  mbQueue <- getBy (UniqQueue name)
  case mbQueue of
    Nothing -> throwR QueueNotExists
    Just qe -> do
      js <- selectFirst [JobQueueId ==. entityKey qe] []
      if isNothing js || forced
        then delete (entityKey qe)
        else throwR QueueNotEmpty

addQueue :: String -> Key Schedule -> DB (Key Queue)
addQueue name scheduleId = do
  r <- insertUnique $ Queue name scheduleId
  case r of
    Just qid -> return qid
    Nothing -> throwR QueueExists

getQueue :: String -> DB (Maybe (Entity Queue))
getQueue name = getBy (UniqQueue name)

enqueue :: String -> JobInfo -> DB (Key Job)
enqueue qname jinfo = do
  mbQueue <- getQueue qname
  case mbQueue of
    Nothing -> throwR QueueNotExists
    Just qe -> do
      seq <- getLastJobSeq (entityKey qe)
      let job = Job (jiType jinfo) (entityKey qe) (seq+1) (jiStatus jinfo)
      jid <- insert job
      forM_ (jiParams jinfo) $ \param -> do
        let param' = param {jobParamJobId = jid}
        insert_ param'
      return jid

