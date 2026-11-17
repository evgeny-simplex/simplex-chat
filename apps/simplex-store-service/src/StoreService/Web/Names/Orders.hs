{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module StoreService.Web.Names.Orders
  ( Answer (..),
    OrderAnswer (..),
    InvoiceOrder (..),
    answerNow,
    sendAnswer,
    refused,
    nameInvoiceHandler,
    codeOrderHandler,
    spendHandler,
    nameInvoiceView,
    orderRefusalResponse,
  )
where

import Control.Concurrent.STM (atomically)
import qualified Control.Exception as E
import Control.Logger.Simple (logError, logNote, logWarn)
import Control.Monad (forM_, unless, (<=<))
import Control.Monad.Except (ExceptT (..), liftEither, runExceptT)
import Data.Aeson ((.:), (.:?))
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.Maybe (isJust, maybeToList)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, addUTCTime)
import Network.HTTP.Types (status200, status400, status403, status409, status503)
import Network.Wai (Request, Response, ResponseReceived)
import Simplex.Chat.Badges.Code (parseNameCode)
import Simplex.Chat.PaymentService.Types (CurrencyAmount (..), InvoiceStatus (..), ServicePaymentMethod (..))
import Simplex.Messaging.Agent.Store.Common (withTransaction)
import qualified Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Names.Record (USDCents)
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, taggedObjectJSON)
import Simplex.Messaging.Util (isAsyncCancellation, tshow)
import StoreService.Catalog (catalogCurrency)
import StoreService.Config (NamesConfig (..), ServiceConfig)
import StoreService.Names.Balances (Spend (..), checkSpendBalance, coveredOrderInsert, differenceOrderInsert)
import StoreService.Names.Chain (hex)
import StoreService.Names.Codes (CodeRefusal (..), readPrepaidCode)
import StoreService.Names.Orders
import StoreService.Names.Registration (OrderFields (..), RegistrationId (..), orderMessage, spendMessage)
import StoreService.Names.Store (BalanceInsertRefused (..), BrokenInvariant (..), NameRegistration (..), NewRegistration (..), OrderHash, OrderPayment (..), OrderTerms (..), PaidOrder (..), PrepaidCode (..), createPaidRegistration, getRegistration, newRegistrationId, orderHash, paymentInvoice)
import StoreService.Names.Turns (withBalanceTurn, withLabelTurn)
import StoreService.Names.View (OrderView, orderView, registrationAt)
import StoreService.Orders (publishRegistration)
import StoreService.Providers (OrderDraft (..), Provider (..), ProviderInvoice (..), expiresItself, providerErrorText)
import StoreService.Store.Invoices (InvoiceRow (..), NewNameInvoice (..), getInvoice, insertNameInvoice, newInvoiceId, truncateToSecond)
import StoreService.Waiters (Waiters, publish)
import StoreService.Web.Http (CheckoutClient, HttpEnv, InvoiceView, ProductView (..), Respond, checkoutClient, confirmationsFor, internalError, invoiceAt, invoiceView, invoiceWindow, jsonResponse, limitedCheckout, nameBodyBytes, notFound, providerFor, providerNamed, providerUnavailable, readBoundedBody, retryAfterResponse)
import StoreService.Web.Names.Codes (codeRefusalStatus)

-- | A name order's answer: the order, placed without an invoice, or its invoice.
data OrderAnswer = OAPlaced {registrationId :: RegistrationId} | OAInvoiced {invoice :: InvoiceView OrderView}

$(JQ.deriveToJSON (taggedObjectJSON $ dropPrefix "OA") ''OrderAnswer)

-- | A name paid by an invoice in the method, at the price the page read, within an invoice amount's range.
data InvoiceOrder = InvoiceOrder
  { order :: OrderRequest,
    method :: ServicePaymentMethod,
    price :: CurrencyAmount
  }

-- | A name paid with a prepaid code, as typed.
data CodeOrder = CodeOrder {order :: OrderRequest, code :: Text}

-- | Another name paid from an order's balance: the price, and the balance the page read, both above 0 and within an invoice
-- amount's range, with a method for the difference exactly when the price is above the balance.
data SpendRequest = SpendRequest
  { signed :: SignedFields,
    price :: CurrencyAmount,
    balance :: CurrencyAmount,
    method :: Maybe ServicePaymentMethod
  }

$(JQ.deriveFromJSON defaultJSON ''InvoiceOrder)

$(JQ.deriveFromJSON defaultJSON ''CodeOrder)

-- | The signed fields beside the spend's own.
instance J.FromJSON SpendRequest where
  parseJSON = J.withObject "SpendRequest" $ \o -> do
    signed <- J.parseJSON (J.Object o)
    price <- o .: "price"
    balance <- o .: "balance"
    method <- o .:? "method"
    pure SpendRequest {signed, price, balance, method}

-- | An order's answer and the work its commit leaves, both done after the name's turn, so a slow client holds no turn.
data Answer = Answer {aResponse :: Response, aAfter :: IO ()}

answerNow :: Response -> Answer
answerNow aResponse = Answer {aResponse, aAfter = pure ()}

sendAnswer :: Respond -> Answer -> IO ResponseReceived
sendAnswer respond Answer {aResponse, aAfter} = aAfter >> respond aResponse

-- | POST /api/invoice for a name, its body already read and decoded.
nameInvoiceHandler :: OrdersEnv -> HttpEnv -> CheckoutClient -> ServiceConfig -> [Provider] -> Waiters -> InvoiceOrder -> Respond -> IO ResponseReceived
nameInvoiceHandler env@OrdersEnv {oeStore} http client cfg providers waiters InvoiceOrder {order = req, method = ioMethod, price = CurrencyAmount cents} respond
  | nCodesOnly (oeConfig env) = sendAnswer respond =<< refuse ORCodesOnly
  | otherwise = sendAnswer respond =<< answerOrder env what req (OTInvoice ioMethod ioPrice) (resentOrder env cfg) newOrder
  where
    what = "POST /api/invoice (name)"
    refuse = refused what
    ioPrice = fromIntegral cents
    OrderRequest {orFields = fields@OrderFields {ofLabelHash, ofLength, ofDuration}, orTimestamp} = req
    newOrder hash now = do
      let years = orderYears fields $ nYears $ oeConfig env
          checks =
            [ pure $ checkTimestamp now orTimestamp,
              pure $ checkDuration (oeConfig env) now years ofDuration,
              checkTerms (oeConfig env) (oeContracts env) fields,
              checkNameFree (oeContracts env) oeStore ofLabelHash,
              checkPrice (oeContracts env) ofLength years ioPrice
            ]
          insert new paid db at =
            createPaidRegistration db new Nothing paid at >>= \case
              Right () -> pure $ Right ()
              Left BIRLiveOrder -> pure $ Left OROrderExists
              Left BIRBalanceChanged -> E.throwIO $ BrokenInvariant "an order holding no balance was refused at a balance"
      runExceptT (mapM_ ExceptT checks) >>= \case
        Left refusal -> refuse refusal
        Right () -> createAtProvider env http client cfg providers waiters what InvoicedOrder {ivRequest = req, ivOrderHash = hash, ivHolders = [], ivMethod = ioMethod, ivPrice = ioPrice, ivAmount = ioPrice, ivInsert = insert}

-- | An order paid by invoice: its order hash, the holders its transaction closes, the order's price, what its invoice asks
-- (less than the price when a balance paid the rest), and its insert after the invoice row's.
data InvoicedOrder = InvoicedOrder
  { ivRequest :: OrderRequest,
    ivOrderHash :: OrderHash,
    ivHolders :: [NameRegistration],
    ivMethod :: ServicePaymentMethod,
    ivPrice :: USDCents,
    ivAmount :: USDCents,
    ivInsert :: NewRegistration -> PaidOrder -> DB.Connection -> UTCTime -> IO (Either OrderRefusal ())
  }

-- | The invoice is made at the provider first, then the order is written with its invoice row; an order not written has its invoice cancelled there.
createAtProvider :: OrdersEnv -> HttpEnv -> CheckoutClient -> ServiceConfig -> [Provider] -> Waiters -> Text -> InvoicedOrder -> IO Answer
createAtProvider env@OrdersEnv {oeStore, oeConfig, oeNow} http client cfg providers waiters what InvoicedOrder {ivRequest = req@OrderRequest {orOwner, orFields}, ivOrderHash, ivHolders, ivMethod, ivPrice, ivAmount, ivInsert} =
  case providerFor providers ivMethod of
    Nothing -> do
      logNote (what <> " refused: no provider configured for " <> tshow ivMethod)
      pure $ answerNow providerUnavailable
    Just provider -> limitedCheckout http client ivMethod (pure . answerNow) $ do
      invId <- newInvoiceId
      now <- truncateToSecond <$> oeNow
      let amount = CurrencyAmount $ fromIntegral ivAmount
      pCreateInvoice provider ivMethod OrderDraft {odAmount = amount, odCurrency = catalogCurrency, odReference = "name:" <> hex ivOrderHash} >>= \case
        Left e -> do
          logError (what <> " failed at the provider: " <> providerErrorText e)
          pure $ answerNow providerUnavailable
        Right ProviderInvoice {piProviderRef, piDestination} -> do
          rid <- newRegistrationId
          let invoice = NewNameInvoice {nniInvoiceId = invId, nniProvider = pProvider provider, nniProviderRef = piProviderRef, nniAmount = amount, nniCurrency = catalogCurrency, nniDestination = piDestination, nniExpiresAt = addUTCTime (invoiceWindow cfg ivMethod) now, nniCreatedAt = now}
              registration = NewRegistration {nrgId = rid, nrgOwner = orOwner, nrgOrder = orFields, nrgYears = nYears oeConfig, nrgOrderHash = ivOrderHash}
              paid = PaidOrder {poMethod = ivMethod, poPrice = ivPrice, poInvoiceId = invId}
          placeOrder env req ivHolders (\db at -> insertNameInvoice db invoice >> ivInsert registration paid db at)
            `E.catch` strandedBy provider piProviderRef
            >>= \case
            Left refusal -> do
              logWarn (what <> ": the order was refused, so invoice " <> piProviderRef <> " is cancelled at the provider")
              (\a -> a {aAfter = cancelAtProvider provider piProviderRef}) <$> refused what refusal
            Right closed -> do
              row_ <- getInvoice oeStore invId
              registration_ <- withTransaction oeStore (`getRegistration` rid)
              response <- case (row_, registration_) of
                (Just row, Just r) -> invoiceViewResponse env cfg r row
                _ -> internalError <$ logError (what <> ": the order of invoice " <> piProviderRef <> " is not readable after its commit")
              pure Answer {aResponse = response, aAfter = announceClosed env providers waiters closed}
  where
    -- An invoice created at the provider for an order that was not written would stay payable with nothing watching it.
    strandedBy :: Provider -> Text -> E.SomeException -> IO a
    strandedBy provider ref e = do
      unless (isAsyncCancellation e) $ do
        logError (what <> ": the order was not written, so invoice " <> ref <> " is cancelled at the provider: " <> tshow e)
        cancelAtProvider provider ref
      E.throwIO e

-- | An exact resend, answered with its order as it reads now: the invoice view, or the id of an order without an invoice.
resentOrder :: OrdersEnv -> ServiceConfig -> UTCTime -> NameRegistration -> IO Answer
resentOrder env@OrdersEnv {oeStore} cfg now r@NameRegistration {nrId = rid@(RegistrationId ridText), nrPayment} = case nrPayment of
  OPInvoice _ invId -> invoiceAnswer invId
  OPDifference _ _ invId -> invoiceAnswer invId
  OPBalance _ -> pure $ answerNow $ registrationAnswer rid
  -- the hash of an invoice or spend order never matches a code order's
  OPCode _ -> E.throwIO $ BrokenInvariant $ "an invoice or spend order's hash matched code order " <> ridText
  where
    invoiceAnswer invId = getInvoice oeStore invId >>= maybe (E.throwIO $ BrokenInvariant $ "the invoice of order " <> ridText <> " is missing") (fmap answerNow . invoiceViewResponse env cfg (registrationAt now r) . invoiceAt now)

invoiceViewResponse :: OrdersEnv -> ServiceConfig -> NameRegistration -> InvoiceRow -> IO Response
invoiceViewResponse env cfg r row = jsonResponse status200 . OAInvoiced <$> nameInvoiceView env (confirmationsFor cfg) row r

registrationAnswer :: RegistrationId -> Response
registrationAnswer registrationId = jsonResponse status200 OAPlaced {registrationId}

refused :: Text -> OrderRefusal -> IO Answer
refused what refusal = answerNow (orderRefusalResponse refusal) <$ logNote (what <> " refused: " <> tshow refusal)

overLimit :: Text
overLimit = "a body over its size limit"

answerOrder :: OrdersEnv -> Text -> OrderRequest -> OrderTerms -> (UTCTime -> NameRegistration -> IO Answer) -> (OrderHash -> UTCTime -> IO Answer) -> IO Answer
answerOrder OrdersEnv {oeStore, oeTurns, oeNow} what order@OrderRequest {orOwner, orFields, orTimestamp, orSignature} terms resent new =
  checkSigner orOwner message orSignature >>= \case
    Left refusal -> refused what refusal
    Right () -> withLabelTurn oeTurns (ofLabelHash orFields) $ inTurns $ do
      now <- oeNow
      withTransaction oeStore (\db -> existingOrder db order hash now) >>= \case
        EOResent r -> resent now r
        EOMeets -> refused what OROrderExists
        EONew -> new hash now
  where
    hash = orderHash orOwner orFields terms
    (message, inTurns) = case terms of
      OTInvoice {} -> (orderMessage orFields orTimestamp, id)
      OTCode _ -> (orderMessage orFields orTimestamp, id)
      OTBalance Spend {spSource} -> (spendMessage spSource orFields orTimestamp, withBalanceTurn oeTurns spSource)

-- | POST /api/name/register, an order paid with a prepaid code, in the contract's order of checks.
codeOrderHandler :: OrdersEnv -> [Provider] -> Waiters -> Request -> Respond -> IO ResponseReceived
codeOrderHandler env@OrdersEnv {oeStore, oeConfig, oeContracts} providers waiters req respond =
  readBoundedBody nameBodyBytes req >>= ordered >>= sendAnswer respond
  where
    what = "POST /api/name/register"
    ordered = maybe (refuse $ ORBadRequest overLimit) (either refuse withCode . decodeRequest "code order")
    refuse = refused what
    withCode CodeOrder {order, code = codeText} =
      issuedCode codeText >>= \case
        Nothing -> refuse $ ORCode CRInvalid
        Just code@PrepaidCode {pcCodeHash} ->
          answerOrder env what order (OTCode pcCodeHash) (\_ NameRegistration {nrId} -> pure $ answerNow $ registrationAnswer nrId) (\hash now -> newOrder now order hash code)
    issuedCode = maybe (pure Nothing) (readPrepaidCode oeStore) . parseNameCode
    newOrder now order@OrderRequest {orFields = fields@OrderFields {ofLabelHash, ofDuration}, orTimestamp} hash code@PrepaidCode {pcYears} = do
      let checks =
            [ pure $ checkTimestamp now orTimestamp,
              pure $ checkDuration oeConfig now (orderYears fields pcYears) ofDuration,
              checkTerms oeConfig oeContracts fields,
              checkNameFree oeContracts oeStore ofLabelHash
            ]
      runExceptT (mapM_ ExceptT checks) >>= \case
        Left refusal -> refuse refusal
        Right () -> do
          rid <- newRegistrationId
          placeCodeOrder env order hash rid code >>= \case
            Left refusal -> refuse refusal
            Right closed -> pure Answer {aResponse = registrationAnswer rid, aAfter = announceClosed env providers waiters closed}

-- | POST /api/registration/:id/spend, another name paid from this order's balance, in the contract's order of checks,
-- under the new name's turn and then the balance's.
spendHandler :: OrdersEnv -> HttpEnv -> ServiceConfig -> [Provider] -> Waiters -> RegistrationId -> Request -> Respond -> IO ResponseReceived
spendHandler env@OrdersEnv {oeStore, oeConfig, oeContracts} http cfg providers waiters source req respond
  | nCodesOnly oeConfig = sendAnswer respond =<< refuse ORCodesOnly
  | otherwise = readBoundedBody nameBodyBytes req >>= requested >>= sendAnswer respond
  where
    what = "POST /api/registration/:id/spend"
    refuse = refused what
    requested = maybe (refuse $ ORBadRequest overLimit) (either refuse paying . (spendOf source <=< decodeRequest "spend"))
    paying (SignedFields {sfFields = fields, sfTimestamp = timestamp, sfSignature = signature}, spend) =
      withTransaction oeStore (`getRegistration` source) >>= \case
        Nothing -> pure $ answerNow notFound
        Just NameRegistration {nrOwner} -> do
          let order = OrderRequest {orOwner = nrOwner, orFields = fields, orTimestamp = timestamp, orSignature = signature}
          answerOrder env what order (OTBalance spend) (resentOrder env cfg) $ \hash now ->
            runExceptT (checked now order spend) >>= either refuse (place order hash spend)
    checked now OrderRequest {orFields = fields@OrderFields {ofLabelHash, ofLength, ofDuration}, orTimestamp} spend@Spend {spPrice} = do
      let years = orderYears fields $ nYears oeConfig
      liftEither $ checkTimestamp now orTimestamp
      liftEither $ checkDuration oeConfig now years ofDuration
      ExceptT $ checkTerms oeConfig oeContracts fields
      holder <- ExceptT $ checkSpendBalance oeStore spend now
      ExceptT $ checkNameFree oeContracts oeStore ofLabelHash
      ExceptT $ checkPrice oeContracts ofLength years spPrice
      pure holder
    place order@OrderRequest {orOwner, orFields} hash spend@Spend {spPrice, spBalance, spMethod} holder = case spMethod of
      Nothing -> do
        rid <- newRegistrationId
        let new = NewRegistration {nrgId = rid, nrgOwner = orOwner, nrgOrder = orFields, nrgYears = nYears oeConfig, nrgOrderHash = hash}
        placeOrder env order (maybeToList holder) (coveredOrderInsert spend new) >>= \case
          Left refusal -> refuse refusal
          Right closed -> pure Answer {aResponse = registrationAnswer rid, aAfter = announceClosed env providers waiters closed}
      Just (SPMCard _)
        | spPrice - spBalance < minCardChargeCents -> refuse $ ORBadRequest "a card difference under the card minimum"
      Just method ->
        createAtProvider env http (checkoutClient http req) cfg providers waiters what $
          InvoicedOrder {ivRequest = order, ivOrderHash = hash, ivHolders = maybeToList holder, ivMethod = method, ivPrice = spPrice, ivAmount = spPrice - spBalance, ivInsert = differenceOrderInsert spend}

-- | Stripe refuses a USD charge under 50 cents, so the page offers only crypto for a smaller difference.
minCardChargeCents :: USDCents
minCardChargeCents = 50

spendOf :: RegistrationId -> SpendRequest -> Either OrderRefusal (SignedFields, Spend)
spendOf spSource SpendRequest {signed, price = CurrencyAmount price, balance = CurrencyAmount balance, method}
  | price == 0 || balance == 0 = Left $ ORBadRequest "a malformed spend: a price or balance not above 0"
  | isJust method /= (price > balance) = Left $ ORBadRequest "a malformed spend: the method is present exactly when the price is above the balance"
  | otherwise = Right (signed, Spend {spSource, spPrice = fromIntegral price, spBalance = fromIntegral balance, spMethod = method})

-- | After the commit, the closed orders' invoices and versions are published, and their invoices cancelled at the provider,
-- best effort, as the poller's sweep would cancel them.
announceClosed :: OrdersEnv -> [Provider] -> Waiters -> [ClosedOrder] -> IO ()
announceClosed OrdersEnv {oeStore, oePhases} providers waiters closed = do
  atomically $ forM_ closed $ \ClosedOrder {coRegistration = NameRegistration {nrId, nrPayment}, coVersion} -> do
    forM_ (paymentInvoice nrPayment) $ \invId -> publish waiters invId ISExpired
    publishRegistration (Just oePhases) (nrId, coVersion)
  forM_ closed $ \ClosedOrder {coRegistration = NameRegistration {nrPayment}} ->
    forM_ (paymentInvoice nrPayment) $ \invId ->
      getInvoice oeStore invId >>= mapM_ (\InvoiceRow {irProvider, irProviderRef} -> forM_ (providerNamed providers irProvider) $ \p -> unless (expiresItself irProvider) $ cancelAtProvider p irProviderRef)

cancelAtProvider :: Provider -> Text -> IO ()
cancelAtProvider Provider {pCancelInvoice} ref =
  pCancelInvoice ref >>= \case
    Left e -> logWarn ("names: cancelling invoice " <> ref <> " at the provider failed: " <> providerErrorText e)
    Right () -> pure ()

nameInvoiceView :: OrdersEnv -> Maybe Int -> InvoiceRow -> NameRegistration -> IO (InvoiceView OrderView)
nameInvoiceView OrdersEnv {oeStore, oeConfig, oeContracts, oeNow} confirmations row r = do
  now <- oeNow
  invoiceView confirmations row . PRName <$> orderView oeStore oeConfig oeContracts now r

orderRefusalResponse :: OrderRefusal -> Response
orderRefusalResponse refusal = case refusal of
  ORTermsUnavailable {wait = Just seconds} -> retryAfterResponse status503 refusal seconds
  _ -> jsonResponse status refusal
  where
    status = case refusal of
      ORBadRequest {} -> status400
      ORInvalidName -> status400
      OROrderExists -> status409
      ORNameTaken -> status409
      ORNameCheckUnavailable -> status503
      ORCatalogChanged {} -> status409
      ORCode {refusal = code} -> codeRefusalStatus code
      ORPriceTooHigh {} -> status409
      ORBalanceChanged {} -> status409
      ORTermsChanged {} -> status409
      ORTermsUnavailable {} -> status503
      ORCodesOnly -> status403
