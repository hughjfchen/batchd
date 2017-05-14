{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module Client.Types where

import GHC.Generics
import Control.Exception
import Data.Generics hiding (Generic)

data ClientException = ClientException String
  deriving (Data, Typeable, Generic)

instance Exception ClientException

instance Show ClientException where
  show (ClientException e) = e

data CrudMode =
    View
  | Add
  | Update
  | Delete
  deriving (Eq, Show, Data, Typeable)

