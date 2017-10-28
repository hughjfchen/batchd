{-# LANGUAGE DeriveDataTypeable, ScopedTypeVariables, TemplateHaskell, GeneralizedNewtypeDeriving, DeriveGeneric, StandaloneDeriving, OverloadedStrings, FlexibleInstances, RecordWildCards #-}

module System.Batchd.Common.Types where

import GHC.Generics
import Control.Exception
import Control.Monad
import Data.Generics hiding (Generic)
import Data.Int
import Data.Char
import Data.String
import Data.Time
import Data.List (isPrefixOf)
import Database.Persist
import Database.Persist.TH
import qualified Data.Map as M
import qualified Data.HashMap.Strict as H
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Aeson as Aeson
import Data.Aeson.Types
import qualified Data.Text.Format.Heavy as F
import qualified Data.Text.Format.Heavy.Parse.Braces as PF
import Data.Yaml (ParseException (..))
import Data.Dates
import qualified System.Posix.Syslog as Syslog
import System.Log.Heavy
import System.Exit

defaultManagerPort :: Int
defaultManagerPort = 9681

data ParamType =
    String
  | Integer
  | InputFile
  | OutputFile
  deriving (Eq, Show, Data, Typeable, Generic)

data ParamDesc = ParamDesc {
    piName :: String,
    piType :: ParamType,
    piTitle :: String,
    piDefault :: String
  }
  deriving (Eq, Show, Data, Typeable, Generic)

data JobType = JobType {
    jtName :: String,
    jtTitle :: Maybe String,
    jtTemplate :: String,
    jtOnFail :: OnFailAction,
    jtHostName :: Maybe String,
    jtMaxJobs :: Maybe Int,
    jtParams :: [ParamDesc]
  }
  deriving (Eq, Show, Data, Typeable, Generic)

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

instance FromJSON ParamType where
  parseJSON = genericParseJSON $ defaultOptions {fieldLabelModifier = camelCaseToUnderscore}

instance ToJSON ParamType where
  toJSON = genericToJSON $ defaultOptions {fieldLabelModifier = camelCaseToUnderscore}

instance FromJSON ParamDesc where
  parseJSON (Object v) = do
    name <- v .: "name" 
    tp <- v .: "type"
    title <- v .:? "title" .!= name
    dflt <- v .:? "default" .!= ""
    return $ ParamDesc name tp title dflt
  parseJSON invalid = typeMismatch "parameter description" invalid

instance ToJSON ParamDesc where
  toJSON = genericToJSON (jsonOptions "pi")

instance FromJSON JobType where
  parseJSON = genericParseJSON (jsonOptions "jt")

instance ToJSON JobType where
  toJSON = genericToJSON (jsonOptions "jt")

-- | What to do if job execution fails
data OnFailAction =
    Continue       -- ^ Continue to the next job
  | RetryNow Int   -- ^ Leave the job in the queue and retry execution.
                   --   Not more than @n@ times.
  | RetryLater Int -- ^ Put the job to the end of queue, to be executed later.
                   --   Not more than @n@ times.
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
          nowStr <- retry .:? "when" .!= "now"
          now <- case nowStr of
                   "now" -> return True
                   "later" -> return False
                   _ -> fail $ "Unknown retry type specification: " ++ nowStr
          count <- retry .:? "count" .!= 1
          if now
            then return $ RetryNow count
            else return $ RetryLater count
      _ -> typeMismatch "retry" r
  parseJSON invalid = typeMismatch "on fail" invalid

-- | Job execution status
data JobStatus =
    New         -- ^ Just created, waiting for polling process to peek it.
  | Waiting     -- ^ Waiting for free worker.
  | Processing  -- ^ Being processed by the worker.
  | Done        -- ^ Successfully executed.
  | Failed      -- ^ Execution failed.
  | Postponed   -- ^ Execution postponed. This status can be set only manually.
  deriving (Eq, Ord, Show, Read, Data, Typeable, Generic)

instance ToJSON JobStatus
instance FromJSON JobStatus

newtype ByStatus a = ByStatus (M.Map JobStatus a)
  deriving (Eq, Show, Data, Typeable, Generic)

instance ToJSON a => ToJSON (ByStatus a) where
  toJSON (ByStatus m) = object $ map go $ M.assocs m
    where
      go (st,x) = (T.pack $ map toLower $ show st) .= toJSON x

instance FromJSON a => FromJSON (ByStatus a) where
  parseJSON (Object v) = do
      pairs <- forM (H.toList v) go
      return $ ByStatus $ M.fromList pairs
    where
      go (key,val) = do
        Just st <- parseStatus Nothing (fail "invalid status") (Just key) 
        cnt <- parseJSON val
        return (st, cnt)

deriving instance Generic WeekDay
instance ToJSON WeekDay
instance FromJSON WeekDay

-- | Recognized error types.
data Error =
    QueueExists String
  | QueueNotExists String
  | QueueNotEmpty
  | ScheduleUsed
  | ScheduleNotExists String
  | JobNotExists
  | InvalidJobType ParseException
  | InvalidHost ParseException
  | InvalidDbCfg ParseException
  | InvalidHostControllerConfig ParseException
  | InvalidConfig ParseException
  | InvalidJobStatus (Maybe B.ByteString)
  | FileNotExists FilePath
  | InsufficientRights String
  | InvalidStartTime
  | SqlError SomeException
  | UnknownError String

instance Show Error where
  show (QueueNotExists name) = "Queue does not exist: " ++ name
  show (QueueExists name) = "Queue already exists: " ++ name
  show QueueNotEmpty = "Queue is not empty"
  show (ScheduleNotExists name) = "Schedule does not exist: " ++ name
  show ScheduleUsed = "Schedule is used by queues"
  show JobNotExists = "Job does not exist"
  show (InvalidJobType e) = "Invalid job type: " ++ show e
  show (InvalidHost e) = "Invalid host description: " ++ show e
  show (InvalidDbCfg e) = "Invalid database config: " ++ show e
  show (InvalidHostControllerConfig e) = "Invalid host controller config: " ++ show e
  show (InvalidConfig e) = "Invalid config: " ++ show e
  show (InvalidJobStatus Nothing) = "Invalid job status"
  show (InvalidJobStatus (Just s)) = "Invalid job status: " ++ show s
  show (FileNotExists path) = "File does not exist: " ++ path
  show (InsufficientRights msg) = "Insufficient privileges: " ++ msg
  show InvalidStartTime = "Job start time does not match queue schedule"
  show (SqlError exc) = "SQL exception: " ++ show exc
  show (UnknownError e) = "Unhandled error: " ++ e

instance Exception Error

type JobParamInfo = M.Map String String

data JobInfo = JobInfo {
    jiId :: Int64,
    jiQueue :: String,
    jiType :: String,
    jiSeq :: Int,
    jiUserName :: String,
    jiCreateTime :: UTCTime,
    jiStartTime :: Maybe UTCTime,
    jiStatus :: JobStatus,
    jiTryCount :: Int,
    jiHostName :: Maybe String,
    jiResultTime :: Maybe UTCTime,
    jiExitCode :: Maybe ExitCode,
    jiStdout :: Maybe T.Text,
    jiStderr :: Maybe T.Text,
    jiParams :: JobParamInfo
  }
  deriving (Generic, Show)

instance ToJSON JobInfo where
  toJSON = genericToJSON (jsonOptions "ji")

zeroUtcTime :: UTCTime
zeroUtcTime = UTCTime (ModifiedJulianDay 0) 0

instance FromJSON JobInfo where
  parseJSON (Object v) =
    JobInfo
      <$> v .:? "id" .!= 0
      <*> v .:? "queue" .!= ""
      <*> v .: "type"
      <*> v .:? "seq" .!= 0
      <*> v .:? "user_name" .!= "<unknown>"
      <*> v .:? "create_time" .!= zeroUtcTime
      <*> v .:? "start_time"
      <*> v .:? "status" .!= New
      <*> v .:? "try_count" .!= 0
      <*> v .:? "host_name"
      <*> v .:? "result_time"
      <*> v .:? "exit_code"
      <*> v .:? "stdout"
      <*> v .:? "stderr"
      <*> v .:? "params" .!= M.empty
  parseJSON invalid = typeMismatch "job" invalid

data UserInfo = UserInfo {
    uiName :: String,
    uiPassword :: String
  } deriving (Generic, Show)

instance ToJSON UserInfo where
  toJSON = genericToJSON (jsonOptions "ui")

instance FromJSON UserInfo where
  parseJSON = genericParseJSON (jsonOptions "ui")

lookupParam :: String -> [ParamDesc] -> Maybe ParamDesc
lookupParam _ [] = Nothing
lookupParam name (p:ps)
  | piName p == name = Just p
  | otherwise = lookupParam name ps

getParamType :: JobType -> String -> Maybe ParamType
getParamType jt name = piType `fmap` lookupParam name (jtParams jt)

-- | Remote host description
data Host = Host {
    hName :: String,
    hHostName :: String,
    hPublicKey :: Maybe String,
    hPrivateKey :: Maybe String,
    hPassphrase :: String,
    hUserName :: String,
    hPort :: Int,
    hMaxJobs :: Maybe Int,
    hController :: String,
    hInputDirectory :: String,
    hOutputDirectory :: String,
    hStartupCommands :: [String]
  }
  deriving (Eq, Show, Data, Typeable, Generic)

instance FromJSON Host where
  parseJSON (Object v) =
    Host
      <$> v .: "name"
      <*> v .: "host_name"
      <*> v .:? "public_key"
      <*> v .:? "private_key"
      <*> v .:? "passphrase" .!= ""
      <*> v .: "user_name"
      <*> v .:? "port" .!= 22
      <*> v .:? "max_jobs"
      <*> v .:? "controller" .!= "local"
      <*> v .:? "input_directory" .!= "."
      <*> v .:? "output_directory" .!= "."
      <*> v .:? "startup_commands" .!= []
  parseJSON invalid = typeMismatch "host definition" invalid

-- | Supported database drivers
data DbDriver = Sqlite | PostgreSql
  deriving (Eq, Show, Data, Typeable, Generic)

instance ToJSON DbDriver
instance FromJSON DbDriver

-- | Daemon execution mode
data DaemonMode =
    Manager     -- ^ Manager thread only
  | Dispatcher  -- ^ Dispatcher thread only
  | Both        -- ^ Both manager and dispatcher threads
  deriving (Data, Typeable, Show, Eq, Generic)

instance ToJSON DaemonMode
instance FromJSON DaemonMode

data AuthMode =
    AuthDisabled
  | AuthConfig {
    authBasicEnabled :: Bool,
    authHeaderEnabled :: Bool,
    authStaticSalt :: String
  }
  deriving (Data, Typeable, Show, Eq, Generic)

instance ToJSON AuthMode where
  toJSON AuthDisabled = Aeson.String "disable"
  toJSON (AuthConfig {..}) = object ["basic" .= authBasicEnabled, "header" .= authHeaderEnabled, "staticSalt" .= authStaticSalt]

instance FromJSON AuthMode where
  parseJSON (Aeson.String "disable") = return AuthDisabled
  parseJSON (Object v) =
    AuthConfig
      <$> v .:? "basic" .!= True
      <*> v .:? "header" .!= False
      <*> v .:? "static_salt" .!= defaultStaticSalt

defaultAuthMode :: AuthMode
defaultAuthMode = AuthConfig True False defaultStaticSalt

data AuthMethod = BasicAuth | HeaderAuth
  deriving (Data, Typeable, Show, Read, Eq, Generic)

instance ToJSON AuthMethod where
  toJSON BasicAuth = Aeson.String "basic"
  toJSON HeaderAuth = Aeson.String "header"

instance FromJSON AuthMethod where
  parseJSON (Aeson.String "basic") = return BasicAuth
  parseJSON (Aeson.String "header") = return HeaderAuth
  parseJSON x = typeMismatch "auth method" x

authMethods :: AuthMode -> [AuthMethod]
authMethods AuthDisabled = []
authMethods (AuthConfig {..}) =
  (if authBasicEnabled then [BasicAuth] else []) ++
  (if authHeaderEnabled then [HeaderAuth] else [])

data LogTarget =
    LogSyslog
  | LogStdout
  | LogStderr
  | LogFile FilePath
  deriving (Eq, Show, Data, Typeable, Generic)

instance ToJSON LogTarget where
  toJSON LogSyslog = Aeson.String "syslog"
  toJSON LogStdout = Aeson.String "stdout"
  toJSON LogStderr = Aeson.String "stderr"
  toJSON (LogFile path) = toJSON path

instance FromJSON LogTarget where
  parseJSON (Aeson.String "syslog") = return LogSyslog
  parseJSON (Aeson.String "stdout") = return LogStdout
  parseJSON (Aeson.String "stderr") = return LogStderr
  parseJSON (Aeson.String path) = return $ LogFile $ T.unpack path
  parseJSON invalid = typeMismatch "log target" invalid

data LogConfig = LogConfig {
    lcTarget :: LogTarget,
    lcFormat :: F.Format,
    lcLevel :: Level,
    lcFilter :: [(String, Level)]
  }
  deriving (Eq, Show, Typeable, Generic)

defaultLogConfig :: LogConfig
defaultLogConfig = LogConfig LogSyslog defaultLogFormat info_level []

defaultLogFormat :: F.Format
defaultLogFormat = "{time} [{level:~l}] {source} ({fullcontext}): {message}\n"

instance ToJSON LogConfig where
  toJSON = genericToJSON (jsonOptions "lc")

instance ToJSON F.Format where
  toJSON fmt = toJSON (show fmt)

instance FromJSON LogConfig where
  parseJSON (Object v) = LogConfig
    <$> v .:? "target" .!= LogSyslog
    <*> parseLogFormat (v .:? "format")
    <*> v .:? "level" .!= info_level
    <*> parseFilter (v .:? "filter" .!= M.empty)
    where
      parseFilter :: Parser (M.Map String Level) -> Parser [(String, Level)]
      parseFilter = fmap M.assocs

      parseLogFormat :: Parser (Maybe TL.Text) -> Parser F.Format
      parseLogFormat p = do
        mbString <- p
        case mbString of
          Nothing -> return defaultLogFormat
          Just str -> case PF.parseFormat str of
                        Left err -> fail $ show err
                        Right fmt -> return fmt

-- | Global daemon configuration
data GlobalConfig = GlobalConfig {
      dbcDaemonMode :: DaemonMode      -- ^ Daemon execution mode
    , dbcManagerPort :: Int            -- ^ Network port for manager to listen
    , dbcDriver :: DbDriver            -- ^ Type of DB backend
    , dbcConnectionString :: T.Text    -- ^ DB connection string
    , dbcWorkers :: Int                -- ^ Number of worker threads
    , dbcPollTimeout :: Int            -- ^ Queue polling timeout, in seconds
    , dbcLogging :: LogConfig          -- ^ Logging configuration
    , dbcAuth :: AuthMode              -- ^ Authentication configuration
    , dbcWebClientPath :: Maybe String -- ^ Path to web client HTML\/JS\/CSS files
    , dbcAllowedOrigin :: Maybe String -- ^ Allowed Origin for CORS
    , dbcStoreDone :: Int              -- ^ How long to store executed jobs, in days.
  }
  deriving (Eq, Show, Typeable, Generic)

defaultStaticSalt :: String
defaultStaticSalt = "1234567890abcdef"

instance ToJSON GlobalConfig where
  toJSON = genericToJSON (jsonOptions "dbc")

instance FromJSON GlobalConfig where
  parseJSON (Object v) =
    GlobalConfig
      <$> v .:? "daemon" .!= Both
      <*> v .:? "manager_port" .!= defaultManagerPort
      <*> v .:? "driver" .!= Sqlite
      <*> v .:? "connection_string" .!= ":memory:"
      <*> v .:? "workers" .!= 1
      <*> v .:? "poll_timeout" .!= 10
      <*> v .:? "logging" .!= defaultLogConfig
      <*> v .:? "auth" .!= defaultAuthMode
      <*> v .:? "web_client_path"
      <*> v .:? "allowed_origin"
      <*> v .:? "store_done" .!= 2
  parseJSON invalid = typeMismatch "global configuration" invalid

event_level :: Level
event_level = Level "EVENT" 350 Syslog.Info

verbose_level :: Level
verbose_level = Level "VERBOSE" 450 Syslog.Info

instance FromJSON Level where
  parseJSON (Aeson.String "debug") = return debug_level
  parseJSON (Aeson.String "verbose") = return verbose_level
  parseJSON (Aeson.String "info") = return info_level
  parseJSON (Aeson.String "warning") = return warn_level
  parseJSON (Aeson.String "error") = return error_level
  parseJSON invalid = typeMismatch "logging level" invalid

instance ToJSON Level where
  toJSON l =
    case levelName l of
      "DEBUG" -> Aeson.String "debug"
      "VERBOSE" -> Aeson.String "verbose"
      "INFO" -> Aeson.String "info"
      "WARN" -> Aeson.String "warning"
      "ERROR" -> Aeson.String "error"
      name -> Aeson.String name

deriving instance Data Syslog.Priority
deriving instance Typeable Syslog.Priority

deriving instance Data Level
deriving instance Typeable Level

parseStatus :: (Eq s, IsString s, Monad m) => Maybe JobStatus -> m (Maybe JobStatus) -> Maybe s -> m (Maybe JobStatus)
parseStatus dflt _ Nothing = return dflt
parseStatus _ _ (Just "all") = return Nothing
parseStatus _ _ (Just "new") = return $ Just New
parseStatus _ _ (Just "waiting") = return $ Just Waiting
parseStatus _ _ (Just "processing") = return $ Just Processing
parseStatus _ _ (Just "done") = return $ Just Done
parseStatus _ _ (Just "failed") = return $ Just Failed
parseStatus _ _ (Just "postponed") = return $ Just Postponed
parseStatus _ handle (Just _) = handle

instance ToJSON ExitCode where
  toJSON ExitSuccess = Number (fromIntegral 0)
  toJSON (ExitFailure n) = Number (fromIntegral n)

instance FromJSON ExitCode where
  parseJSON (Number 0) = return ExitSuccess
  parseJSON (Number n) = return $ ExitFailure $ round n
  parseJSON x = typeMismatch "exit code" x

data ExecException = ExecException SomeException
  deriving (Typeable)

instance Exception ExecException

instance Show ExecException where
  show (ExecException e) = "Exception during command execution: " ++ show e

data UploadException = UploadException FilePath SomeException
  deriving (Typeable)

instance Exception UploadException

instance Show UploadException where
  show (UploadException path e) = "Exception uploading file `" ++ path ++ "': " ++ show e

data DownloadException = DownloadException FilePath SomeException
  deriving (Typeable)

instance Exception DownloadException

instance Show DownloadException where
  show (DownloadException path e) = "Exception downloading file `" ++ path ++ "': " ++ show e

derivePersistField "WeekDay"
derivePersistField "JobStatus"
derivePersistField "ExitCode"

-- | Supported user permissions.
data Permission =
    SuperUser
  | CreateJobs
  | ViewJobs
  | ManageJobs
  | ViewQueues
  | ManageQueues
  | ViewSchedules
  | ManageSchedules
  deriving (Eq, Show, Read, Data, Typeable, Generic)

derivePersistField "Permission"

instance FromJSON Permission where
  parseJSON = genericParseJSON $ defaultOptions {fieldLabelModifier = camelCaseToUnderscore}

instance ToJSON Permission where
  toJSON = genericToJSON $ defaultOptions {fieldLabelModifier = camelCaseToUnderscore}

parseUpdate :: (PersistField t, FromJSON t) => EntityField v t -> T.Text -> Value -> Parser (Maybe (Update v))
parseUpdate field label (Object v) = do
  mbValue <- v .:? label
  let upd = case mbValue of
              Nothing -> Nothing
              Just value -> Just (field =. value)
  return upd

parseUpdateMaybe :: (PersistField t, FromJSON t) => EntityField v (Maybe t) -> T.Text -> Value -> Parser (Maybe (Update v))
parseUpdateMaybe field label (Object v) = do
  if label `H.member` v
    then do
      mbValue <- v .:? label
      return $ Just $ field =. mbValue
    else return Nothing

parseUpdateStar :: (PersistField t, FromJSON t, IsString t, Eq t)
             => EntityField v (Maybe t) -> T.Text -> Value -> Parser (Maybe (Update v))
parseUpdateStar field label (Object v) = do
  mbValue <- v .:? label
  let upd = case mbValue of
              Nothing -> Nothing
              Just "*" -> Just (field =. Nothing)
              Just value -> Just (field =. Just value)
  return upd

bstrToString :: B.ByteString -> String
bstrToString bstr = map (chr . fromIntegral) $ B.unpack bstr

stringToBstr :: String -> B.ByteString
stringToBstr str = B.pack $ map (fromIntegral . ord) str
