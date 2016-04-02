{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

import GHC.Generics
import Control.Monad
import qualified Data.Aeson as Aeson
import Data.Yaml
import qualified Data.Map as M
import Data.Maybe
import Data.List (intercalate)
import Data.Char (toLower)
import Data.Generics hiding (Generic)
import Data.Dates
import Network.HTTP.Client
import Network.HTTP.Types.Status (statusCode)
import System.Console.CmdArgs
import System.FilePath
import System.Environment (lookupEnv)
import Text.Printf

import CommonTypes
import qualified Database
import Schedule
import Config

data ClientConfig = ClientConfig {
    ccManagerUrl :: Maybe String,
    ccQueue :: Maybe String,
    ccType :: Maybe String,
    ccHost :: Maybe String
  }
  deriving (Show, Data, Typeable, Generic)

defaultConfig :: ClientConfig
defaultConfig = ClientConfig Nothing Nothing Nothing Nothing

instance FromJSON ClientConfig where
  parseJSON = Aeson.genericParseJSON (jsonOptions "cc")

data CrudMode =
    View
  | Add
  | Update
  | Delete
  deriving (Show, Data, Typeable)

data Batch =
    Enqueue {
      managerUrl :: Maybe String,
      queueName :: Maybe String,
      typeName :: Maybe String,
      hostName :: Maybe String,
      command :: [String],
      parameters :: [String]
    }
  | List {
      managerUrl :: Maybe String,
      status :: Maybe String,
      queueToList :: [String]
    }
  | Queue {
      managerUrl :: Maybe String,
      queueMode :: CrudMode,
      queueObject :: String,
      scheduleName :: Maybe String,
      hostName :: Maybe String,
      force :: Bool
    }
  | Schedule {
      managerUrl :: Maybe String,
      scheduleMode :: CrudMode,
      scheduleNames :: [String],
      periods :: [String],
      weekdays :: [WeekDay],
      force :: Bool
    }
  | Type {
      managerUrl :: Maybe String,
      types :: [String]
    }
  | Stats {
      managerUrl :: Maybe String,
      queueToStat :: [String]
    }
  deriving (Show, Data, Typeable)

defaultUrl :: String
defaultUrl = "http://localhost:" ++ show defaultManagerPort

defaultQueue :: String
defaultQueue = "default"

defaultType :: String
defaultType = "command"

getConfigParam :: Maybe String -> String -> Maybe String -> String -> IO String
getConfigParam cmdline varname cfg dflt = do
  case cmdline of
    Just val -> return val
    Nothing -> do
      mbEnv <- lookupEnv varname
      case mbEnv of
        Just val -> return val
        Nothing -> return $ fromMaybe dflt cfg
    
getConfigParam' :: Maybe String -> String -> Maybe String -> IO (Maybe String)
getConfigParam' cmdline varname cfg = do
  case cmdline of
    Just val -> return $ Just val
    Nothing -> do
      mbEnv <- lookupEnv varname
      case mbEnv of
        Just val -> return $ Just val
        Nothing -> return cfg

loadClientConfig :: IO ClientConfig
loadClientConfig = do
  mbPath <- locateConfig "" "client.yaml"
  case mbPath of
    Nothing -> return defaultConfig
    Just path -> do
      r <- decodeFileEither path
      case r of
        Left err -> fail $ "Can't parse client config:\n" ++ show err
        Right cfg -> return cfg
    
getManagerUrl :: Maybe String -> ClientConfig -> IO String
getManagerUrl cmdline cfg =
  getConfigParam cmdline "BATCH_MANAGER_URL" (ccManagerUrl cfg) defaultUrl

getHostName :: Maybe String -> ClientConfig -> IO (Maybe String)
getHostName cmdline cfg =
  getConfigParam' cmdline "BATCH_HOST" (ccHost cfg)

getTypeName :: Maybe String -> ClientConfig -> IO String
getTypeName cmdline cfg =
  getConfigParam cmdline "BATCH_TYPE" (ccType cfg) defaultType

getQueueName :: Maybe String -> ClientConfig -> IO String
getQueueName cmdline cfg =
  getConfigParam cmdline "BATCH_QUEUE" (ccQueue cfg) defaultQueue

managerUrlAnn = Nothing &= name "url" &= typ defaultUrl &= help "batchd manager API URL"

enqueue :: Batch
enqueue = Enqueue {
    managerUrl = managerUrlAnn,
    queueName = def &= name "queue" &= typ "QUEUE" &= help "queue name",
    typeName = def &= name "type" &= typ "TYPE" &= help "job type name",
    hostName = def &= name "host" &= typ "HOST" &= help "worker host name",
    command = def &= typ "COMMAND PARAMETERS" &= args,
    parameters = def &= typ "NAME=VALUE" &= help "job parameters specified by name"
  } &= help "put a new job into queue"

list :: Batch
list = List {
    managerUrl = managerUrlAnn,
    status = def &= typ "STATUS" &= help "list only jobs of specified status",
    queueToList = def &= args &= typ "QUEUE"
  } &= help "list queues or jobs"

queue :: Batch
queue = Queue {
    managerUrl = managerUrlAnn,
    queueMode = enum [
                  Add &= help "create new queue",
                  Update &= help "modify queue",
                  Delete &= help "delete queue"],
    queueObject = defaultQueue &= argPos 0 &= typ "QUEUE",
    scheduleName = def &= typ "SCHEDULE" &= help "queue schedule name",
    hostName = Nothing &= name "host" &= typ "HOST" &= help "default host name for queue",
    force = False &= help "force non-empty queue deletion"
  } &= help "create, update or delete queues"
    
schedule :: Batch
schedule = Schedule {
    managerUrl = managerUrlAnn,
    scheduleMode =  enum [
                      View &= name "ls" &= help "list available schedules",
                      Add &= help "create new schedule",
                      Update &= help "modify schedule",
                      Delete &= help "delete (unused) schedule"],
    scheduleNames = def &= typ "SCHEDULE" &= args,
    periods = [] &= typ "HH:MM:SS HH:MM:SS" &= help "time of day period(s)",
    weekdays = [] &= typ "WEEKDAY" &= help "week day(s)",
    force = False &= help "delete also all queues which use this schedule and their jobs"
  } &= help "create, update or delete schedules"

typesList :: Batch
typesList = Type {
    managerUrl = managerUrlAnn,
    types = [] &= typ "TYPE" &= args
  } &= name "type"
    &= help "show defined job types"

stats :: Batch
stats = Stats {
    managerUrl = managerUrlAnn,
    queueToStat = [] &= typ "QUEUE" &= args
  } &= help "print statistics on queue or on all jobs"

parseParams :: [ParamDesc] -> Batch -> JobParamInfo
parseParams desc e = 
    let posNames = map piName desc
        ordered = M.fromList $ zip posNames (command e)
        byName = M.fromList $ map parseOne (parameters e)
    in  M.union byName ordered
  where
    parseOne :: String -> (String, String)
    parseOne s = case break (== '=') s of
                   (key, (_:value)) -> (key, value)
                   (key, []) -> (key, "")

doPut :: ToJSON a => Manager -> String -> a -> IO ()
doPut manager urlStr object = do
  url <- parseUrl urlStr
  let request = url {
                  method="PUT",
                  requestBody = RequestBodyLBS $ Aeson.encode object
                }
  httpLbs request manager
  return ()

doPost :: ToJSON a => Manager -> String -> a -> IO ()
doPost manager urlStr object = do
  url <- parseUrl urlStr
  let request = url {
                  method="POST",
                  requestBody = RequestBodyLBS $ Aeson.encode object
                }
  httpLbs request manager
  return ()

doDelete :: Manager -> String -> IO ()
doDelete manager urlStr = do
  url <- parseUrl urlStr
  let request = url { method="DELETE" }
  httpLbs request manager
  return ()

doGet :: FromJSON a => Manager -> String -> IO a
doGet manager urlStr = do
  url <- parseUrl urlStr
  responseLbs <- httpLbs url manager
  case Aeson.eitherDecode (responseBody responseLbs) of
    Left err -> fail err
    Right res -> return res

doEnqueue :: Manager -> Batch -> IO ()
doEnqueue manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  t <- getTypeName (typeName opts) cfg
  jtr <- loadTemplate t
  case jtr of
    Left err -> fail $ show err
    Right jtype -> do
      qname <- getQueueName (queueName opts) cfg
      host <- getHostName (hostName opts) cfg

      let job = JobInfo {
          jiId = 0,
          jiQueue = qname,
          jiType = t,
          jiSeq = 0,
          jiCreateTime = zeroUtcTime,
          jiStatus = New,
          jiTryCount = 0,
          jiHostName = host,
          jiResultTime = Nothing,
          jiExitCode = Nothing,
          jiStdout = Nothing,
          jiStderr = Nothing,
          jiParams = parseParams (jtParams jtype) opts
        }

      let url = baseUrl </> "queue" </> qname
      doPut manager url job

doList :: Manager -> Batch -> IO ()
doList manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  case queueToList opts of
    [] -> do
      let url = baseUrl </> "queue"
      response <- doGet manager url
      forM_ response $ \queue -> do
        printf "%s:\t%s\t%s\n"
               (Database.queueName queue)
               (Database.queueScheduleName queue)
               (fromMaybe "*" $ Database.queueHostName queue)

    qnames ->
      forM_ qnames $ \qname -> do
        statusOpt <- parseStatus (Just New) (fail "Invalid status") (status opts)
        let statusStr = case statusOpt of
                          Nothing -> "?status=all"
                          Just st -> case status opts of
                                       Nothing -> ""
                                       _ -> "?status=" ++ map toLower (show st)
        let url = baseUrl </> "queue" </> qname ++ statusStr
        response <- doGet manager url
        forM_ response $ \job -> do
          printf "#%d: [%d]\t%s\t%s\n" (jiId job) (jiSeq job) (jiType job) (show $ jiStatus job)
          forM_ (M.assocs $ jiParams job) $ \(name, value) -> do
            printf "\t%s:\t%s\n" name value

doStats :: Manager -> Batch -> IO ()
doStats manager opts = do
    cfg <- loadClientConfig
    baseUrl <- getManagerUrl (managerUrl opts) cfg
    case queueToStat opts of
      [] -> do
        let url = baseUrl </> "stats"
        response <- doGet manager url
        forM_ (M.assocs response) $ \rec -> do
          let qname = fst rec :: String
              stat = snd rec :: M.Map JobStatus Int
          putStrLn $ qname ++ ":"
          printStats stat
      qnames -> do
        forM_ qnames $ \qname -> do
          putStrLn $ qname ++ ":"
          let url = baseUrl </> "stats" </> qname
          response <- doGet manager url
          printStats response
  where
    printStats :: M.Map JobStatus Int -> IO ()
    printStats stat =
      forM_ (M.assocs stat) $ \(st, cnt) ->
          printf "\t%s:\t%d\n" (show st) cnt

addQueue :: Manager -> Batch -> IO ()
addQueue manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  let queue = Database.Queue {
                Database.queueName = queueObject opts,
                Database.queueScheduleName = fromMaybe "anytime" (scheduleName opts),
                Database.queueHostName = hostName opts
              }
  let url = baseUrl </> "queue"
  doPut manager url queue

updateQueue :: Manager -> Batch -> IO ()
updateQueue manager opts = do
    cfg <- loadClientConfig
    baseUrl <- getManagerUrl (managerUrl opts) cfg
    let queue = object $
                  toList "schedule_name" (scheduleName opts) ++
                  toList "host_name" (hostName opts)
    let url = baseUrl </> "queue" </> queueObject opts
    doPost manager url queue
  where
    toList _ Nothing = []
    toList name (Just str) = [name .= str]

deleteQueue :: Manager -> Batch -> IO ()
deleteQueue manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  let forceStr = if force opts then "?forced=true" else ""
  let url = baseUrl </> "queue" </> queueObject opts ++ forceStr
  doDelete manager url

doListSchedules :: Manager -> Batch -> IO ()
doListSchedules manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  let url = baseUrl </> "schedule"
  response <- doGet manager url
  let check = if null (scheduleNames opts)
                then const True
                else \si -> sName si `elem` scheduleNames opts
  forM_ response $ \si -> do
    when (check si) $ do
      putStrLn $ sName si ++ ":"
      case sWeekdays si of
        Nothing -> putStrLn "\tany weekday"
        Just lst -> putStrLn $ "\t" ++ intercalate ", " (map show lst)
      case sTime si of
        Nothing -> putStrLn "\tany time of day"
        Just lst -> putStrLn $ "\t" ++ intercalate ", " (map show lst)

doAddSchedule :: Manager -> Batch -> IO ()
doAddSchedule manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  when (length (scheduleNames opts) /= 1) $
    fail $ "Exactly one schedule name must be specified when creating a schedule"
  let ts = forM (periods opts) $ \str -> do
             parsePeriod str
  case ts of
    Left err -> fail $ "Can't parse period description: " ++ show err
    Right times -> do
      let url = baseUrl </> "schedule"
      let schedule = ScheduleInfo {
                       sName = head (scheduleNames opts),
                       sWeekdays = if null (weekdays opts) then Nothing else Just (weekdays opts),
                       sTime = if null times then Nothing else Just times
                     }
      doPut manager url schedule

doDeleteSchedule :: Manager -> Batch -> IO ()
doDeleteSchedule manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  when (length (scheduleNames opts) /= 1) $
    fail $ "Exactly one schedule name must be specified when deleting a schedule"
  let sname = head (scheduleNames opts)
  let forceStr = if force opts then "?forced=true" else ""
  let url = baseUrl </> "schedule" </> sname ++ forceStr
  doDelete manager url

doType :: Manager -> Batch -> IO ()
doType manager opts = do
  cfg <- loadClientConfig
  baseUrl <- getManagerUrl (managerUrl opts) cfg
  let url = baseUrl </> "type"
  response <- doGet manager url
  let check = if null (types opts)
                then const True
                else \jt -> jtName jt `elem` types opts
  forM_ response $ \jt -> do
    when (check jt) $ do
      putStrLn $ jtName jt ++ ":"
      putStrLn $ "\tTemplate:\t" ++ jtTemplate jt
      putStrLn $ "\tOn fail:\t" ++ show (jtOnFail jt)
      putStrLn $ "\tHost:\t" ++ fromMaybe "*" (jtHostName jt)
      putStrLn $ "\tParameters:"
      forM_ (jtParams jt) $ \desc -> do
        putStrLn $ "\t* Name:\t" ++ piName desc
        putStrLn $ "\t  Type:\t" ++ show (piType desc)
        putStrLn $ "\t  Title:\t" ++ piTitle desc
        putStrLn $ "\t  Default:\t" ++ piDefault desc

main :: IO ()
main = do
  let mode = cmdArgsMode $ modes [enqueue, list &= name "ls", queue, schedule, typesList, stats]
  opts <- cmdArgsRun mode

  manager <- newManager defaultManagerSettings

  case opts of
    Enqueue {} -> doEnqueue manager opts
    List {} -> doList manager opts
    Stats {} -> doStats manager opts
    Type {} -> doType manager opts
    Queue {} ->
      case queueMode opts of
        Add -> addQueue manager opts
        Update -> updateQueue manager opts
        Delete -> deleteQueue manager opts
    Schedule {} -> 
      case scheduleMode opts of
        View -> doListSchedules manager opts
        Add -> doAddSchedule manager opts
        Delete -> doDeleteSchedule manager opts

