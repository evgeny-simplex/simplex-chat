{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Chat.Payments
  ( PaymentRequest (..),
    PaymentPayee (..),
    PaymentNetwork (..),
    LightningPayee (..),
    PaymentToken (..),
    AddressChecksum (..),
  )
where

import qualified Data.Aeson.TH as JQ
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (UTCTime)
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, enumJSON, sumTypeJSON)

data PaymentRequest = PaymentRequest
  { payee :: PaymentPayee,
    alternatives :: [LightningPayee],
    amount :: Maybe Text,
    token :: Maybe PaymentToken,
    label :: Maybe Text,
    message :: Maybe Text,
    walletUri :: Text
  }
  deriving (Eq, Show)

data PaymentPayee
  = PPAddress {network :: PaymentNetwork, address :: Text, checksum :: AddressChecksum}
  | PPLightning {lightning :: LightningPayee}
  deriving (Eq, Show)

data PaymentNetwork
  = PNBitcoin
  | PNEthereum {chainId :: Maybe Int64}
  | PNMonero
  | PNZcash
  | PNSolana
  | PNLitecoin
  | PNDogecoin
  | PNBitcoinCash
  deriving (Eq, Show)

data LightningPayee
  = LPInvoice {invoice :: Text, description :: Maybe Text, expiresAt :: UTCTime}
  | LPOffer {offer :: Text}
  | LPLnurl {lnurl :: Text, host :: Text}
  deriving (Eq, Show)

data PaymentToken = PaymentToken {address :: Text, checksum :: AddressChecksum}
  deriving (Eq, Show)

data AddressChecksum = ACVerified | ACUnchecked
  deriving (Eq, Show)

instance StrEncoding PaymentRequest where
  strEncode PaymentRequest {walletUri} = encodeUtf8 walletUri
  strDecode _ = Left "not a payment URI"

$(JQ.deriveJSON (enumJSON $ dropPrefix "AC") ''AddressChecksum)

$(JQ.deriveJSON (sumTypeJSON $ dropPrefix "PN") ''PaymentNetwork)

$(JQ.deriveJSON (sumTypeJSON $ dropPrefix "LP") ''LightningPayee)

$(JQ.deriveJSON (sumTypeJSON $ dropPrefix "PP") ''PaymentPayee)

$(JQ.deriveJSON defaultJSON ''PaymentToken)

$(JQ.deriveJSON defaultJSON ''PaymentRequest)
