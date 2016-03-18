{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables, TemplateHaskell, GeneralizedNewtypeDeriving, DeriveGeneric, StandaloneDeriving, OverloadedStrings #-}

module Types where

import GHC.Generics
import Control.Applicative
import Control.Monad.Reader
import Control.Monad.Except
import Control.Monad.Logger
import Control.Monad.Trans.Resource
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Generics hiding (Generic)
import Data.Char
import Data.List (isPrefixOf)
import Data.Dates
import Data.Aeson as Aeson
import Data.Aeson.Types
import Database.Persist
import Database.Persist.TH
import Database.Persist.Sql as Sql
import Web.Scotty.Trans as Scotty
import System.Exit

data ParamType =
    String
  | Integer
  | InputFile
  | OutputFile
  deriving (Eq, Show, Data, Typeable, Generic)

data JobType = JobType {
    jtName :: String,
    jtTemplate :: String,
    jtOnFail :: OnFailAction,
    jtParams :: M.Map String ParamType
  }
  deriving (Eq, Show, Data, Typeable, Generic)

data OnFailAction =
    Continue
  | RetryNow Int
  | RetryLater Int
  deriving (Eq, Show, Read, Data, Typeable, Generic)

instance ToJSON OnFailAction where
  toJSON Continue = Aeson.String "continue"
  toJSON (RetryNow n) = object ["retry" .= object ["when" .= ("now" :: T.Text), "count" .= n]]
  toJSON (RetryLater n) = object ["retry" .= object ["when" .= ("later" :: T.Text), "count" .= n]]

instance FromJSON OnFailAction where
  parseJSON (Aeson.String "continue") = return Continue
  parseJSON (Aeson.String "retry") = return (RetryNow 1)
  parseJSON (Object v) = do
    r <- v .: "retry"
    case r of
      Object retry -> do
          now <- retry .:? "when" .!= True
          count <- retry .:? "count" .!= 1
          if now
            then return $ RetryNow count
            else return $ RetryLater count
      _ -> typeMismatch "retry" r
  parseJSON invalid = typeMismatch "on fail" invalid

data JobStatus =
    New
  | Processing
  | Done
  | Failed
  deriving (Eq, Show, Read, Data, Typeable, Generic)

instance ToJSON JobStatus
instance FromJSON JobStatus

deriving instance Generic WeekDay
instance ToJSON WeekDay
instance FromJSON WeekDay

data Error =
    QueueExists
  | QueueNotExists
  | QueueNotEmpty
  | JobNotExists
  | InvalidJobType String
  | InvalidJobStatus
  | UnknownError String
  deriving (Eq, Show, Data, Typeable)

instance ScottyError Error where
  stringError e = UnknownError e
  showError e = TL.pack (show e)

type Result a = ExceptT Error IO a

derivePersistField "WeekDay"
derivePersistField "JobStatus"
derivePersistField "ExitCode"

type DB a = ReaderT SqlBackend (ExceptT Error (NoLoggingT (ResourceT IO))) a
type DBIO a = ReaderT SqlBackend (NoLoggingT (ResourceT IO)) a

throwR :: Error -> DB a
throwR ex = lift $ throwError ex

dbio :: DB a -> DBIO (Either Error a)
dbio action = do
  backend <- ask
  x <- lift $ runExceptT $ runReaderT action backend
  case x of
    Left err -> do
        liftIO $ print err
        return $ Left err
    Right r -> return $ Right r

newtype ConnectionM a = ConnectionM {
    runConnection :: ReaderT Sql.ConnectionPool IO a
  }
  deriving (Applicative,Functor,Monad,MonadIO, MonadReader Sql.ConnectionPool)

type Action a = ActionT Error ConnectionM a

runDBA :: DB a -> Action a
runDBA qry = do
  pool <- lift ask
  r <- liftIO $ runResourceT $ runNoLoggingT (Sql.runSqlPool (dbio qry) pool)
  case r of
    Left err -> Scotty.raise err
    Right x -> return x

runDBA' :: DB a -> Action (Either Error a)
runDBA' qry = do
  pool <- lift ask
  r <- liftIO $ runResourceT $ runNoLoggingT (Sql.runSqlPool (dbio qry) pool)
  return r

runDB :: DB a -> ConnectionM (Either Error a)
runDB qry = do
  pool <- ask
  liftIO $ runResourceT $ runNoLoggingT $ Sql.runSqlPool (dbio qry) pool

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

jsonOptions :: String -> Data.Aeson.Types.Options
jsonOptions prefix = defaultOptions {fieldLabelModifier = camelCaseToUnderscore . stripPrefix prefix}

parseUpdate :: (PersistField t, FromJSON t) => EntityField v t -> T.Text -> Value -> Parser (Maybe (Update v))
parseUpdate field label (Object v) = do
  mbValue <- v .:? label
  let upd = case mbValue of
              Nothing -> Nothing
              Just value -> Just (field =. value)
  return upd

instance FromJSON JobType where
  parseJSON = genericParseJSON (jsonOptions "jt")

instance FromJSON ParamType where
  parseJSON = genericParseJSON $ defaultOptions {fieldLabelModifier = camelCaseToUnderscore}

