{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module StoreService.Web.Names.Registration
  ( registrationHandler,
    revealHandler,
    retryHandler,
    registrationChangedResponse,
    registrationRefusalResponse,
    retryRefusalResponse,
    heldFor,
    versionParam,
  )
where

import Control.Concurrent.STM (atomically)
import qualified Control.Exception as E
import Control.Logger.Simple (logNote)
import Control.Monad (join)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.Int (Int64)
import Data.Maybe (isJust, maybeToList)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import Network.HTTP.Types (status200, status400, status409, status503)
import Network.Wai (Request, Response, ResponseReceived, queryString)
import Simplex.Messaging.Agent.Store.Common (withTransaction)
import Simplex.Messaging.Parsers (dropPrefix, parseAll, taggedObjectJSON)
import Simplex.Messaging.Util (eitherToMaybe, tshow)
import StoreService.Config (boundedDecimal)
import StoreService.Names.Orders (OrdersEnv (..), WriteRefusal (..), versionWritten)
import StoreService.Names.Phases (awaitChange, publish)
import StoreService.Names.Registration (RegistrationId (..))
import StoreService.Names.Reveal (RevealRefusal (..), checkReveal, isRepeat, linksValid)
import StoreService.Names.Store (BrokenInvariant (..), Commit (..), NameRegistration (..), OrderPhase (..), getRegistration, updateRegistration)
import StoreService.Names.Turns (withRegistrationTurn)
import StoreService.Names.View (OrderView, RegistrationRefusal (..), lapseMoment, orderView, registrationAt, registrationVersion)
import StoreService.Names.Worker (Retried (..), RetryRefusal (..), retryRegistration)
import StoreService.Web.Http (HttpEnv, Respond, badRequest, holdsFull, jsonResponse, maxBodyBytes, notFound, readBoundedBody, withHoldSlot)
import StoreService.Web.Names.Codes (codeRefusalStatus)

-- | A reveal taken, or the one stored already sent again.
data RevealAnswer = RARevealed

$(JQ.deriveToJSON (taggedObjectJSON $ dropPrefix "RA") ''RevealAnswer)

-- | GET /api/registration/:id, held while its version is seenVersion.
registrationHandler :: OrdersEnv -> HttpEnv -> Int -> RegistrationId -> Request -> Respond -> IO ResponseReceived
registrationHandler OrdersEnv {oeStore, oeConfig, oeContracts, oePhases, oeNow} http hold rid req respond =
  readNow >>= \case
    Nothing -> respond notFound
    Just (now, r@NameRegistration {nrVersion})
      | versionParam req == Just nrVersion ->
          withHoldSlot http (awaitChange oePhases rid (registrationVersion oeStore rid) nrVersion (heldFor hold now $ maybeToList $ lapseMoment r))
            >>= maybe (respond holdsFull) (const $ readNow >>= maybe (respond notFound) answer)
      | otherwise -> answer (now, r)
  where
    readNow = oeNow >>= \now -> fmap (now,) <$> withTransaction oeStore (`getRegistration` rid)
    answer (now, r) = respond . jsonResponse status200 =<< orderView oeStore oeConfig oeContracts now (registrationAt now r)

-- | What a reveal decided in the name's turn, with the version it wrote; the publish and the answer come after the turn.
data RevealDecision
  = RDAccepted (Maybe Int64)
  | RDRefused RevealRefusal (Maybe Int64)
  | RDChanged
  | RDGone

-- | POST /api/registration/:id/reveal, its checks in the contract's order, from the stored commitment in the name's turn.
revealHandler :: OrdersEnv -> RegistrationId -> Request -> Respond -> IO ResponseReceived
revealHandler env@OrdersEnv {oeStore, oeConfig, oeContracts, oeTurns, oePhases, oeNow} rid@(RegistrationId ridText) req respond =
  withTransaction oeStore (`getRegistration` rid) >>= \case
    Nothing -> respond notFound
    Just r ->
      readBoundedBody maxBodyBytes req >>= \case
        Just body -> case J.eitherDecode body of
          Right request -> withRegistrationTurn oeStore oeTurns r (decide request) >>= answer . maybe RDGone (either (const RDChanged) id)
          Left e -> logNote ("POST /api/registration/:id/reveal refused: a malformed reveal: " <> T.pack e) >> respond badRequest
        Nothing -> answer $ RDRefused (RVBadRequest "the body is over its size limit") Nothing
  where
    decide request r@NameRegistration {nrReveal} = do
      now <- oeNow
      case nrReveal of
        Just stored -> pure $ if isRepeat request stored then RDAccepted Nothing else RDRefused (RVBadRequest "another reveal is stored") Nothing
        Nothing -> case nrPhase (registrationAt now r) of
          OCommitted c@Commit {revealBefore, linksRefusedAt} ->
            checkReveal oeConfig oeContracts now r revealBefore request >>= \case
              Left refusal -> pure $ RDRefused refusal Nothing
              Right rv
                | linksValid rv -> write now (RDAccepted . Just) r {nrReveal = Just rv}
                | isJust linksRefusedAt -> pure $ RDRefused RVInvalidLink Nothing
                | otherwise -> write now (RDRefused RVInvalidLink . Just) r {nrPhase = OCommitted (c :: Commit) {linksRefusedAt = Just now}}
          _ -> pure $ RDRefused (RVBadRequest "the order is not committed") Nothing
    write now decided r =
      withTransaction oeStore (\db -> versionWritten <$> updateRegistration db r now) >>= \case
        Right v -> pure $ decided v
        Left WRChanged -> pure RDChanged
        Left (WRRefused refusal) -> E.throwIO $ BrokenInvariant $ "registration " <> ridText <> " is live while committed, yet its reveal was refused: " <> tshow refusal
    answer = \case
      RDAccepted v -> published v >> respond (jsonResponse status200 RARevealed)
      RDRefused refusal v -> do
        published v
        logNote ("POST /api/registration/:id/reveal refused: " <> tshow refusal)
        respond $ jsonResponse (revealRefusalStatus refusal) refusal
      RDChanged -> respond =<< registrationChangedResponse env rid
      RDGone -> respond notFound
    published = mapM_ (atomically . publish oePhases rid)
    revealRefusalStatus = \case
      RVBadRequest {} -> status400
      RVInvalidLink -> status400
      RVChainUnavailable -> status503

-- | POST /api/registration/:id/retry, Try again in the name's turn; the publish and the answer come after the turn.
retryHandler :: OrdersEnv -> RegistrationId -> Request -> Respond -> IO ResponseReceived
retryHandler env@OrdersEnv {oeStore, oeTurns, oePhases} rid _ respond =
  withTransaction oeStore (`getRegistration` rid) >>= \case
    Nothing -> respond notFound
    Just r -> withRegistrationTurn oeStore oeTurns r (retryRegistration env) >>= maybe (respond notFound) (answer . either (const RTChanged) id)
  where
    answer = \case
      RTWritten v -> do
        atomically $ publish oePhases rid v
        respond . maybe notFound (jsonResponse status200) =<< currentView env rid
      RTChanged -> respond =<< registrationChangedResponse env rid
      RTRefused refusal -> do
        logNote ("POST /api/registration/:id/retry refused: " <> tshow refusal)
        respond $ retryRefusalResponse refusal

retryRefusalResponse :: RetryRefusal -> Response
retryRefusalResponse refusal = jsonResponse status refusal
  where
    status = case refusal of
      RFNotFailed -> status400
      RFLinksRefused -> status400
      RFSendsUsedUp -> status400
      RFCode {refusal = code} -> codeRefusalStatus code
      RFUnread -> status503

-- | The registration's current view, for a request that lost the race to change it.
registrationChangedResponse :: OrdersEnv -> RegistrationId -> IO Response
registrationChangedResponse env = registrationRefusalResponse env RRRegistrationChanged

-- | A refusal with the registration's current view, so the page follows its state.
registrationRefusalResponse :: OrdersEnv -> (OrderView -> RegistrationRefusal) -> RegistrationId -> IO Response
registrationRefusalResponse env refusal rid = maybe notFound (jsonResponse status409 . refusal) <$> currentView env rid

-- | The registration's view as it reads now.
currentView :: OrdersEnv -> RegistrationId -> IO (Maybe OrderView)
currentView OrdersEnv {oeStore, oeConfig, oeContracts, oeNow} rid =
  withTransaction oeStore (`getRegistration` rid) >>= traverse (\r -> oeNow >>= \now -> orderView oeStore oeConfig oeContracts now (registrationAt now r))

-- | The hold, cut to end just past the next moment at which the answer changes with time alone.
heldFor :: Int -> UTCTime -> [UTCTime] -> Int
heldFor hold now moments = fromInteger $ minimum $ toInteger hold : [ceiling (diffUTCTime moment now * microsPerSecond) + 1 | moment <- moments, moment >= now]
  where
    microsPerSecond = 1000000

-- | Nothing unless seenVersion is a decimal version, so any other value answers at once.
versionParam :: Request -> Maybe Int64
versionParam req = join (lookup "seenVersion" $ queryString req) >>= eitherToMaybe . parseAll (boundedDecimal 0 maxBound)
