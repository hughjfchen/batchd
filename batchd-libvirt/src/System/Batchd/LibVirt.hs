{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.Batchd.LibVirt
  (
    LibVirt (..),
    Selector (..)
  ) where

import Control.Exception
import Control.Concurrent
import Data.Time
import Data.Aeson
import System.Batchd
import System.LibVirt as V

data LibVirt = LibVirt {
    lvEnableStartStop :: Bool
  , lvConnectionString :: String
  }
  deriving (Show)

instance FromJSON LibVirt where
  parseJSON (Object v) =
    LibVirt
    <$> v .:? "enable_start_stop" .!= True
    <*> v .:? "connection_string" .!= "qemu:///system"

instance HostController LibVirt where
  data Selector LibVirt = LibVirtSelector FilePath

  doesSupportStartStop l = lvEnableStartStop l

  initController (LibVirtSelector name) _ = do
    r <- loadHostControllerConfig name
    case r of
      Left err -> throw err
      Right lib -> return lib

  startHost l name = do
    withConnection (lvConnectionString l) $ \conn -> do
        putStrLn "connect ok"
        mbdom <- do
                 x <- try $ lookupDomainName conn name
                 case x of
                   Left (e :: V.Error) -> do
                                          putStrLn "lookupDomainName:"
                                          print e
                                          return Nothing
                   Right dom -> return (Just dom)
        case mbdom of
          Just dom -> do
            di <- getDomainInfo dom
            putStrLn $ "domain got ok: " ++ show di
            case diState di of
              DomainRunning -> return ()
              DomainPaused -> resumeDomain dom >> return ()
              DomainShutoff -> do
                       createDomain dom
                       return ()
              st -> fail $ "Don't know what to do with virtual domain " ++ name ++ " in state " ++ show st
          Nothing -> fail $ "Domain is not defined in hypervisor: " ++ name

  stopHost l name = do
    withConnection (lvConnectionString l) $ \conn -> do
        mbdom <- do
                 x <- try $ lookupDomainName conn name
                 case x of
                   Left (e :: V.Error) -> do
                                          print e
                                          return Nothing
                   Right dom -> return (Just dom)
        case mbdom of
          Nothing -> fail $ "No such domain on hypervisor: " ++ name
          Just dom -> do
            shutdownDomain dom
            return ()

