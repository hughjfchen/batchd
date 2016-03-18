
module SSH where

import Control.Monad
import Data.Maybe
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Yaml
import Network.SSH.Client.LibSSH2
import System.FilePath
import System.Environment
import System.Exit

import Types
import Database

getKnownHosts :: IO FilePath
getKnownHosts = do
  home <- getEnv "HOME"
  return $ home </> ".ssh" </> "known_hosts"

getDfltPublicKey :: IO FilePath
getDfltPublicKey = do
  home <- getEnv "HOME"
  return $ home </> ".ssh" </> "id_rsa.pub"

getDfltPrivateKey :: IO FilePath
getDfltPrivateKey = do
  home <- getEnv "HOME"
  return $ home </> ".ssh" </> "id_rsa"

loadHost :: String -> IO Host
loadHost name = do
  r <- decodeFileEither (name ++ ".yaml")
  case r of
    Left err -> fail (show err)
    Right host -> return host

loadTemplate :: String -> IO JobType
loadTemplate name = do
  r <- decodeFileEither (name ++ ".yaml")
  case r of
    Left err -> fail (show err)
    Right jt -> return jt

processOnHost :: Host -> JobType -> JobInfo -> String -> IO (ExitCode, T.Text)
processOnHost h jtype job command = do
  known_hosts <- getKnownHosts
  def_public_key <- getDfltPublicKey
  def_private_key <- getDfltPrivateKey
  let passphrase = fromMaybe "" $ hPassphrase h
      public_key = fromMaybe def_public_key $ hPublicKey h
      private_key = fromMaybe def_private_key $ hPrivateKey h
      user = hUserName h
      port = fromMaybe 22 $ hPort h
      hostname = hHostName h

  putStrLn $ "CONNECTING TO " ++ hostname
  print h
  withSSH2 known_hosts public_key private_key passphrase user hostname port $ \session -> do
      uploadFiles (getInputFiles jtype job) session
      (ec,out) <- execCommands session [command]
      downloadFiles (getOutputFiles jtype job) session
      let outText = TL.toStrict $ TLE.decodeUtf8 (head out)
          ec' = if ec == 0
                  then ExitSuccess
                  else ExitFailure ec
      return (ec', outText)

getParamType :: JobType -> String -> Maybe ParamType
getParamType jt name = M.lookup name (jtParams jt)

getInputFiles :: JobType -> JobInfo -> [FilePath]
getInputFiles jt job =
  [value | (name, value) <- M.assocs (jiParams job), getParamType jt name == Just InputFile]

getOutputFiles :: JobType -> JobInfo -> [FilePath]
getOutputFiles jt job =
  [value | (name, value) <- M.assocs (jiParams job), getParamType jt name == Just OutputFile]

uploadFiles :: [FilePath] -> Session -> IO ()
uploadFiles files session =
  forM_ files $ \path ->
    scpSendFile session 0o777 path path

downloadFiles :: [FilePath] -> Session -> IO ()
downloadFiles files session =
  forM_ files $ \path ->
    scpReceiveFile session path path
