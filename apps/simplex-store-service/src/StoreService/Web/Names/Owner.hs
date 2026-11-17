{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The requests only the owner code can sign: find and another name.
module StoreService.Web.Names.Owner (findHandler, retargetHandler) where

import Control.Concurrent.STM (atomically)
import Control.Logger.Simple (logError, logNote)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Data.Aeson ((.:))
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import qualified Data.Aeson.Types as JT
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Word (Word64)
import Network.HTTP.Types (status200)
import Network.Wai (Request, Response, ResponseReceived)
import Simplex.Chat.PaymentService.Types (InvoiceId)
import Simplex.Messaging.Agent.Store.Common (withTransaction)
import Simplex.Messaging.Crypto.Secp256k1 (RecoverableSignature)
import Simplex.Messaging.Encoding.String (strParseJSON)
import Simplex.Messaging.Eth.Address (Address)
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.SimplexName (LabelHash (..))
import Simplex.Messaging.Util (tshow)
import StoreService.Config (NamesConfig (..))
import StoreService.Names.Chain (hex)
import StoreService.Names.Orders
import StoreService.Names.Phases (publish)
import StoreService.Names.Registration (OrderFields (..), RegistrationId (..), findMessage, parseAnyCaseAddress, retargetMessage)
import StoreService.Names.Store (BalanceUse (..), NamePhase (..), NameRegistration (..), findRegistrations, getRegistration, namePhase, paymentBalance, paymentInvoice)
import StoreService.Names.Turns (withRegistrationTurns)
import StoreService.Names.View (RegistrationRefusal (..), orderView, registrationAt)
import StoreService.Web.Http (Respond, internalError, jsonResponse, maxBodyBytes, nameBodyBytes, notFound, readBoundedBody)
import StoreService.Names.Worker (Retried (..), checkFailedOrder)
import StoreService.Web.Names.Orders (Answer (..), answerNow, refused, sendAnswer)
import StoreService.Web.Names.Registration (registrationChangedResponse, registrationRefusalResponse, retryRefusalResponse)

data FindRequest = FindRequest
  { frOwner :: Address,
    frTimestamp :: Word64,
    frSignature :: RecoverableSignature
  }

-- | The owner in any case.
instance J.FromJSON FindRequest where
  parseJSON = J.withObject "FindRequest" $ \o -> do
    frOwner <- JT.explicitParseField (J.withText "owner" $ either (fail . show) pure . parseAnyCaseAddress) o "owner"
    frTimestamp <- o .: "timestamp"
    frSignature <- JT.explicitParseField (strParseJSON "signature") o "signature"
    pure FindRequest {frOwner, frTimestamp, frSignature}

-- | The owner's orders, newest first.
newtype FindAnswer = FindAnswer {registrations :: [FoundOrder]}

-- | balanceSource: the order whose balance paid this one; heldBy: the order whose invoice holds this one's balance.
data FoundOrder = FoundOrder
  { registrationId :: RegistrationId,
    invoiceId :: Maybe InvoiceId,
    phase :: NamePhase,
    createdAt :: UTCTime,
    labelHash :: Text,
    sealed :: Text,
    balanceSource :: Maybe RegistrationId,
    heldBy :: Maybe RegistrationId
  }

$(JQ.deriveToJSON defaultJSON ''FoundOrder)

$(JQ.deriveToJSON defaultJSON ''FindAnswer)

-- | POST /api/registration/find, the owner's orders newest first.
findHandler :: OrdersEnv -> Request -> Respond -> IO ResponseReceived
findHandler OrdersEnv {oeStore, oeNow} req respond =
  readBoundedBody maxBodyBytes req >>= requested >>= sendAnswer respond
  where
    requested = maybe (refuse $ ORBadRequest "a find request over its size limit") (either refuse found . decodeRequest "find request")
    found FindRequest {frOwner, frTimestamp, frSignature} = do
      now <- oeNow
      runExceptT (mapM_ ExceptT [checkSigner frOwner (findMessage frOwner frTimestamp) frSignature, pure $ checkTimestamp now frTimestamp]) >>= \case
        Left refusal -> refuse refusal
        Right () -> do
          rs <- withTransaction oeStore (\db -> findRegistrations db frOwner now)
          pure $ answerNow $ jsonResponse status200 FindAnswer {registrations = map (\(r, holder) -> foundOrder (registrationAt now r) holder) rs}
    refuse = refused "POST /api/registration/find"

foundOrder :: NameRegistration -> Maybe RegistrationId -> FoundOrder
foundOrder NameRegistration {nrId, nrPayment, nrPhase, nrCreatedAt, nrLabelHash = LabelHash lh, nrSealed} heldBy =
  FoundOrder
    { registrationId = nrId,
      invoiceId = paymentInvoice nrPayment,
      phase = namePhase nrPhase,
      createdAt = nrCreatedAt,
      labelHash = hex lh,
      sealed = nrSealed,
      balanceSource = buSource <$> paymentBalance nrPayment,
      heldBy
    }

-- | POST /api/registration/:id/name, another name or other links, under the turns of both names.
retargetHandler :: OrdersEnv -> RegistrationId -> Request -> Respond -> IO ResponseReceived
retargetHandler env@OrdersEnv {oeStore, oeConfig, oeContracts, oeTurns, oeNow} rid@(RegistrationId ridText) req respond =
  readBoundedBody nameBodyBytes req >>= requested >>= sendAnswer respond
  where
    requested = maybe (refuse $ ORBadRequest "a move over its size limit") (either refuse signed . decodeRequest "move")
    signed SignedFields {sfFields = fields, sfTimestamp = timestamp, sfSignature = signature} =
      withTransaction oeStore (`getRegistration` rid) >>= \case
        Nothing -> pure $ answerNow notFound
        Just r@NameRegistration {nrOwner} ->
          checkSigner nrOwner (retargetMessage rid fields timestamp) signature >>= \case
            Left refusal -> refuse refusal
            Right () ->
              withRegistrationTurns oeStore oeTurns r (ofLabelHash fields) (inTurns fields timestamp)
                >>= maybe (pure $ answerNow notFound) (either (const changed) pure)
    inTurns fields timestamp stored = do
      now <- oeNow
      moveTo now (registrationAt now stored) fields timestamp
    moveTo now r@NameRegistration {nrPhase} fields timestamp
      | orderFieldsOf r == fields = answerNow . jsonResponse status200 <$> orderView oeStore oeConfig oeContracts now r
      | Left refusal <- checkTimestamp now timestamp = refuse refusal
      | not (movable r) = refuse $ ORBadRequest "the order is not movable"
      | namePhase nrPhase == PFailed =
          checkFailedOrder env r >>= \case
            Right () -> moveChecked now r fields
            Left (RTWritten v) -> written env rid v <$> registrationChangedResponse env rid
            Left RTChanged -> changed
            Left (RTRefused refusal) -> answerNow (retryRefusalResponse refusal) <$ logNote (what <> " refused: " <> tshow refusal)
      | otherwise = moveChecked now r fields
    moveChecked now r@NameRegistration {nrMoves, nrYears} fields@OrderFields {ofLabelHash, ofDuration}
      | nrMoves >= nMaxOrderMoves oeConfig = answerNow <$> registrationRefusalResponse env RRMoveLimit rid
      | otherwise =
          runExceptT (mapM_ ExceptT [checkMoveMeets oeStore r fields now, pure $ checkDuration oeConfig now years ofDuration, checkTerms oeConfig oeContracts fields, checkNameFree oeContracts oeStore ofLabelHash]) >>= \case
            Left refusal -> refuse refusal
            Right () -> write now r fields
      where
        years = orderYears fields nrYears
    write now r fields =
      retargetOrder env r fields >>= \case
        Right v -> movedAnswer now v
        Left WRChanged -> changed
        Left (WRRefused refusal) -> refuse refusal
    movedAnswer now v =
      withTransaction oeStore (`getRegistration` rid) >>= \case
        Just r -> written env rid v . jsonResponse status200 <$> orderView oeStore oeConfig oeContracts now (registrationAt now r)
        Nothing -> answerNow internalError <$ logError ("POST /api/registration/:id/name: order " <> ridText <> " is not readable after its move")
    changed = answerNow <$> registrationChangedResponse env rid
    what = "POST /api/registration/:id/name"
    refuse = refused what

-- | Published after the turn, as the answer is sent.
written :: OrdersEnv -> RegistrationId -> Int64 -> Response -> Answer
written OrdersEnv {oePhases} rid v aResponse = Answer {aResponse, aAfter = atomically $ publish oePhases rid v}

