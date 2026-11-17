{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module StoreService.Web.Names.Codes (codeCheckHandler, codeRefusalStatus) where

import Control.Logger.Simple (logNote)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Network.HTTP.Types (Status, status200, status400, status409)
import Network.Wai (Request, Response, ResponseReceived)
import Simplex.Chat.Badges.Code (parseNameCode)
import Simplex.Messaging.Agent.Store.Common (DBStore)
import Simplex.Messaging.Parsers (defaultJSON)
import StoreService.Names.Codes (CodeRefusal (..), CodeState, codeState, readPrepaidCode)
import StoreService.Names.Orders (OrderRefusal (..))
import StoreService.Names.Store (PrepaidCode (..))
import StoreService.Web.Http (Respond, badRequest, jsonResponse, maxBodyBytes, readBoundedBody)

newtype CodeCheck = CodeCheck {code :: Text}

data CodeAnswer = CodeAnswer {minLength :: Int, years :: Int, state :: CodeState}

$(JQ.deriveFromJSON defaultJSON ''CodeCheck)

$(JQ.deriveToJSON defaultJSON ''CodeAnswer)

-- | It names no registration, even for a reserved code: holding a code proves nothing about an order.
codeCheckHandler :: DBStore -> Request -> Respond -> IO ResponseReceived
codeCheckHandler st req respond =
  readBoundedBody maxBodyBytes req >>= \case
    Just body -> case J.eitherDecode body of
      Right CodeCheck {code} -> case parseNameCode code of
        Just nameCode -> do
          now <- getCurrentTime
          readPrepaidCode st nameCode >>= respond . maybe invalidCode (codeAnswer now)
        Nothing -> respond invalidCode
      Left e -> logNote ("POST /api/code/check refused: a malformed code check: " <> T.pack e) >> respond badRequest
    Nothing -> respond badRequest
  where
    invalidCode = jsonResponse status400 ORCode {refusal = CRInvalid}

codeAnswer :: UTCTime -> PrepaidCode -> Response
codeAnswer now code@PrepaidCode {pcMinLength, pcYears} = jsonResponse status200 CodeAnswer {minLength = pcMinLength, years = pcYears, state = codeState now code}

-- | Not 404 for an unknown code, which the page reads as not found whatever the body.
codeRefusalStatus :: CodeRefusal -> Status
codeRefusalStatus = \case
  CRInvalid -> status400
  _ -> status409
