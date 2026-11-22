{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Bots.StoreService.BadgeCompatTests (badgeCompatTests) where

import Bots.StoreService.BotTests
import Bots.StoreService.FakeStore (FakeStore (..), appleSubscriptionOriginalId, googleSubscriptionToken, googleSupporterToken)
import Bots.StoreService.WebTests (fieldOf, jsonObject, newStubState, pollerFor, prepareStaticDir, rcv, sampleProviderInvoice, setSignals, statusOf, stubProvider, testBTCPayConfig, testServiceConfig, webGet, webRequestBody, withListener)
import ChatClient (smpServerStr, smpTestPort, testPort, testServerKeyHash)
import ChatTests.DBUtils
import ChatTests.Utils
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM (TMVar, TVar, atomically, newEmptyTMVar, newTVarIO, putTMVar, stateTVar, takeTMVar)
import Control.Exception (bracket)
import qualified Control.Exception as E
import Control.Monad (foldM, forM_, forever, void)
import qualified Data.Aeson as J
import qualified Data.Aeson.Key as JK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Functor ((<&>))
import Data.Int (Int64)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromJust, isJust)
import qualified Network.WebSockets as WS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime, nominalDay)
import Simplex.Chat.Badges (BadgeCredential, BadgeInfo (..), BadgeMasterKey (..), BadgeRequest (..), BadgeType (..), VerifiedBadgeRequest (..), issueBadge)
import Simplex.Chat.Badges.Code (BadgeCode, badgeCodeHash, badgeCodeText, randomBadgeCode)
import Simplex.Chat.Badges.Ledger (addMonths, debitEntry, emptyEntry, endOfMondayAfter, grantEntry, issueEntry)
import Simplex.Chat.Badges.Types (BadgeCodePaymentStatus (..), BadgeOfferId (..), BadgePriceId (..), BadgePurchaseStatus (..))
import Simplex.Chat.Bot.Store (withDB')
import Simplex.Chat.Controller (ChatConfig (..), ChatController (..))
import Simplex.Chat.Options (CoreChatOpts (..))
import Simplex.Chat.Options.DB
import Simplex.Chat.PaymentService (googlePurchaseRef)
import Simplex.Chat.PaymentService.Types (InvoiceId (..), InvoiceStatus (..), PaymentProvider (..))
import Simplex.Chat.Store.Shared (insertedRowId)
import Simplex.Chat.StoreService
import Simplex.Messaging.Agent.Store.Common (DBStore, withTransaction)
import Simplex.Messaging.Agent.Store.DB (Binary (..))
import qualified Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Agent.Store.Interface (migrateDBSchema)
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfig (..), MigrationConfirmation (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Encoding.String (strEncode, textEncode)
import Simplex.Messaging.TMap (TMap)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Util (tshow)
import StoreService.Config (BadgeIssuerKey (..), ServiceConfig (..))
import StoreService.Options (StoreServiceOpts (..))
import StoreService.Poller (runOnePass)
import StoreService.Providers (PaymentSignal (..), Provider (..))
import StoreService.Store (BadgeCounts (..), CodeTracker (..), CreditedPurchase (..), FundingCredit (..), IssuedCode (..), KeyRedemption (..), ManagedGroup (..), PurchaseSubscription (..), ServicePurchase (..), badgeCounts, getBadgeCode, getCodePurchaseForKey, getCodeTracker, getCurrentIssuance, getLedgerEntries, getManagedGroup, getPurchaseByKey, getPurchaseSubscription, getStorePaymentCredit, getSubscriptionCharge)
import StoreService.Store.Invoices (InvoiceProduct (..), InvoiceRow (..), getInvoice, getInvoiceByProviderRef, markCodePaid, readCatalogRows, truncateToSecond, unpaidRefs)
import StoreService.Web.Http (holdMicros)
import System.Directory (createDirectoryIfMissing, renameFile)
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath ((</>))
import System.IO (IOMode (..), withFile)
import System.Process (CreateProcess (..), StdStream (..), cleanupProcess, createProcess, proc)
import System.Timeout (timeout)
import Test.Hspec hiding (it)
import UnliftIO.Temporary (withTempDirectory)
#if defined(dbPostgres)
import Database.PostgreSQL.Simple (Only (..), Query, (:.) (..))
import StoreService.Store.Postgres.Migrations (storeServiceSchemaMigrations)
#else
import Database.SQLite.Simple (Only (..), Query, (:.) (..))
import StoreService.Store.SQLite.Migrations (storeServiceSchemaMigrations)
#endif

badgeCompatTests :: SpecWith TestParams
badgeCompatTests = describe "master compatibility" $ do
  describe "master rows" $
    it "reads the badge rows that master writes after the names migration, and serves each badge flow on them" testMasterRows
  describe "master CLI" $ do
    it "redeems codes and reads the service's refusals as master does" $ withMasterClient testMasterRedeems
    it "renews a code badge within its month and in the next" $ withMasterClient testMasterRenews
    it "credits a Play purchase handed over with its invoice" $ withMasterClient testMasterPlayPurchase
    it "moves a Play subscription to a new device" $ withMasterClient testMasterRestore
    it "answers unsupported versions and malformed requests" $ withMasterClient testMasterUnsupported

masterLastMigration :: String
masterLastMigration = "20261012_badge_subscriptions"

data Holder = Holder {holderKey :: C.PublicKeyEd25519, holderMaster :: BadgeMasterKey}

data MasterRows = MasterRows
  { rowsAt :: UTCTime,
    singleCode :: BadgeCode,
    single :: Holder,
    multiCode :: BadgeCode,
    multi :: Holder,
    multiNext :: Holder,
    revokedCode :: BadgeCode,
    restCode :: BadgeCode,
    rest :: Holder,
    lapsedCode :: BadgeCode,
    openCode :: BadgeCode,
    partCode :: BadgeCode,
    expiredCode :: BadgeCode,
    cancelledCode :: BadgeCode,
    google :: Holder,
    movedFrom :: Holder,
    movedTo :: Holder,
    apple :: Holder
  }

newMasterRows :: IO MasterRows
newMasterRows = do
  g <- C.newRandom
  let code = randomBadgeCode g
      holder = uncurry Holder <$> newPurchaseKeys
  rowsAt <- truncateToSecond . addUTCTime (-10 * nominalDay) <$> getCurrentTime
  MasterRows rowsAt <$> code <*> holder <*> code <*> holder <*> holder <*> code <*> code <*> holder <*> code <*> code <*> code <*> code <*> code <*> holder <*> holder <*> holder <*> holder

data Seed = Seed
  { singleLedger :: [StatementEntry],
    singleCredential :: BadgeCredential,
    singleCodeId :: Int64,
    singlePurchase :: Int64,
    multiCodeId :: Int64,
    restLedger :: [StatementEntry],
    restPurchase :: Int64,
    googleLedger :: [StatementEntry],
    googleCredential :: BadgeCredential,
    googlePurchase :: Int64,
    movedFromLedger :: [StatementEntry],
    movedFromPurchase :: Int64,
    movedToLedger :: [StatementEntry],
    movedToPurchase :: Int64,
    appleLedger :: [StatementEntry],
    applePurchase :: Int64
  }

openInvoice, partInvoice, paidInvoice, expiredInvoice, cancelledInvoice :: Text
openInvoice = "inv-btc-open"
partInvoice = "inv-xmr-part"
paidInvoice = "inv-card-paid"
expiredInvoice = "inv-btc-expired"
cancelledInvoice = "inv-card-cancelled"

refOf :: Text -> Text
refOf = ("ref-" <>)

googlePayment, movedPayment, applePayment :: Text
googlePayment = "pay-google-one"
movedPayment = "pay-google-subscription"
applePayment = "pay-apple-subscription"

trackerItem :: Int64
trackerItem = 77

testMasterRows :: HasCallStack => TestParams -> IO ()
testMasterRows ps = do
  rows@MasterRows {rowsAt, single, multiCode, multiNext, revokedCode, lapsedCode, google, movedFrom} <- newMasterRows
  seeded <- newIORef Nothing
  withSeededStoreService ps (\_ store -> pure $ fakeVerifier store) (seedMasterRows rows seeded) $ \env@StoreServiceEnv {bsClock, bsController = cc} -> do
    seed@Seed {singleLedger, singleCredential, googleCredential, movedFromLedger} <- fromJust <$> readIORef seeded
    readsBack cc rows seed
    redeemed <- serviceCmd env (holderKey single) STCRedeemBadgeCode {masterKey = holderMaster single, code = badgeCodeText (singleCode rows)}
    credentialOf redeemed `shouldBe` Just singleCredential
    entriesJSON (fst $ statementOf redeemed) `shouldBe` entriesJSON singleLedger
    redeemWithKeys env (holderKey multiNext, holderMaster multiNext) multiCode >>= (`shouldSatisfy` isJust) . credentialOf
    codeUses cc multiCode `shouldReturn` Just (3, 2)
    redeemAsNewPurchase env revokedCode >>= (`shouldAnswerError` STECodeInvalid)
    redeemAsNewPurchase env lapsedCode >>= (`shouldAnswerError` STECodeExpired)
    repeated <- assertBalance env (holderKey single) (last singleLedger)
    fst (statementOf repeated) `shouldSatisfy` null
    credentialOf repeated `shouldBe` Just singleCredential
    replayed <- serviceCmd env (holderKey google) (purchaseCmd (holderMaster google) supporterPlay)
    credentialOf replayed `shouldBe` Just googleCredential
    movedAway <- assertBalance env (holderKey movedFrom) (last movedFromLedger)
    credentialOf movedAway `shouldBe` Nothing
    subscriptionOf movedAway `shouldBe` Just SSEnded
    webFlowsOnRows cc rows
    revokeCodeAs cc multiCode `shouldReturn` Right "Revoked."
    codeUses cc multiCode `shouldReturn` Just (3, 2)
    setClockAt bsClock (addMonths 1 rowsAt)
    renewed <- assertBalance env (holderKey single) (last singleLedger)
    map entryTag (fst $ statementOf renewed) `shouldBe` ["badge"]
    credentialOf renewed `shouldSatisfy` \c -> isJust c && c /= Just singleCredential

entriesJSON :: [StatementEntry] -> LB.ByteString
entriesJSON = J.encode

seedMasterRows :: MasterRows -> IORef (Maybe Seed) -> StoreServiceOpts -> BadgeIssuerKey -> DBStore -> IO ()
seedMasterRows rows seeded StoreServiceOpts {coreOptions = CoreChatOpts {dbOptions}} issuer st = do
  migrateDBSchema st (toDBOpts dbOptions chatSuffix False []) (Just "sx_badge_service_migrations") masterMigrations MigrationConfig {confirm = MCYesUp, backupPath = Nothing}
    >>= either (fail . show) pure
  now <- truncateToSecond <$> getCurrentTime
  seed <- withTransaction st $ \db -> masterWrites issuer rows now db
  writeIORef seeded (Just seed)
  where
    masterMigrations = filter ((<= masterLastMigration) . name) storeServiceSchemaMigrations

masterWrites :: BadgeIssuerKey -> MasterRows -> UTCTime -> DB.Connection -> IO Seed
masterWrites issuer MasterRows {rowsAt = t, singleCode, single, multiCode, multi, revokedCode, restCode, rest, lapsedCode, openCode, partCode, expiredCode, cancelledCode, google, movedFrom, movedTo, apple} now db = do
  forM_ catalogPrices $ DB.execute db seedBadgePriceQ
  forM_ catalogOffers $ DB.execute db seedBadgeOfferQ
  singleCodeId <- insertCode singleCode "supporter" 2 "free" 1
  DB.execute db claimCodeUseQ (t, singleCodeId)
  singlePurchase <- insertCodePurchase single "supporter" singleCodeId
  let s1 = grantEntry t "master-single-1" BTSupporter 2 SCCode (emptyEntry t BTSupporter)
      s2 = fromJust $ issueEntry t "master-single-2" s1
  void $ ledgerRow singlePurchase ("credit", Just "code", Nothing) noRefs s1
  singleCredential <- issuedRow singlePurchase single s1 s2
  multiCodeId <- insertCode multiCode "legend" 1 "paid" 3
  DB.execute db claimCodeUseQ (t, multiCodeId)
  DB.execute db setCodeGroupItemQ (trackerItem, t, multiCodeId)
  multiPurchase <- insertCodePurchase multi "legend" multiCodeId
  let m1 = grantEntry t "master-multi-1" BTLegend 1 SCCode (emptyEntry t BTLegend)
      m2 = fromJust $ issueEntry t "master-multi-2" m1
  void $ ledgerRow multiPurchase ("credit", Just "code", Nothing) noRefs m1
  void $ issuedRow multiPurchase multi m1 m2
  void $ insertCode revokedCode "supporter" 1 "free" 1
  DB.execute db revokeCodeQ (t, Binary $ badgeCodeHash revokedCode)
  restCodeId <- insertCode restCode "supporter" 3 "free" 1
  DB.execute db claimCodeUseQ (t, restCodeId)
  restPurchase <- insertCodePurchase rest "supporter" restCodeId
  let r1 = (emptyEntry t BTSupporter) {entryId = "master-rest-1", changeMonths = 3, balanceMonths = 3}
      r2 = r1 {entryId = "master-rest-2", changeMonths = -1, balanceMonths = 2, balanceStartTs = addMonths 1 t, entryType = SEDebit SDLapse}
      r3 = r2 {entryId = "master-rest-3", changeMonths = 1, balanceMonths = 3, entryType = SECredit SCSupport}
      r4 = r3 {entryId = "master-rest-4", changeMonths = -1, balanceMonths = 2, entryType = SEDebit SDSupport}
      r5 = r4 {entryId = "master-rest-5", changeMonths = -2, balanceMonths = 0, entryType = SEDebit SDRefund}
      restLedger = [r1, r2, r3, r4, r5]
  forM_ (zip restTags restLedger) $ \(tags, e) -> ledgerRow restPurchase tags noRefs e
  invoiceRows openInvoice "crypto" (Nothing, Just "bc1qmasteropen", Just "btc", Just "0.00050000") (addUTCTime 3600 now) (addUTCTime (-600) now) openCode
  invoiceRows partInvoice "crypto" (Nothing, Just "48masterpart", Just "xmr", Just "0.32095000") (addUTCTime 3600 now) (addUTCTime (-600) now) partCode
  DB.execute db upsertPaymentQ ((partInvoice, partInvoice, "crypto" :: Text, refOf partInvoice, 300 :: Int) :. ("usd" :: Text, Just ("0.10000000" :: Text), Just ("0.22095000" :: Text), 0 :: Int, "pending" :: Text, addUTCTime (-300) now, addUTCTime (-300) now))
  invoiceRows paidInvoice "stripe" (Just "pi_master_secret", Nothing, Nothing, Nothing) (addUTCTime 3600 t) t lapsedCode
  DB.execute db upsertPaymentQ ((paidInvoice, paidInvoice, "stripe" :: Text, refOf paidInvoice, 700 :: Int) :. ("usd" :: Text, Nothing :: Maybe Text, Nothing :: Maybe Text, 1 :: Int, "settled" :: Text, t, t))
  DB.execute db updateInvoiceStatusQ ("paid" :: Text, t, paidInvoice, "open" :: Text)
  DB.execute db markCodePaidQ ("paid" :: Text, addUTCTime (-nominalDay) now, Binary $ badgeCodeHash lapsedCode, "unpaid" :: Text)
  invoiceRows expiredInvoice "crypto" (Nothing, Just "bc1qmasterexpired", Just "btc", Just "0.00050000") (addUTCTime 3600 t) t expiredCode
  DB.execute db expireOverdueQ (now, now, expiredInvoice)
  invoiceRows cancelledInvoice "stripe" (Just "pi_master_cancelled_secret", Nothing, Nothing, Nothing) (addUTCTime 3600 now) (addUTCTime (-600) now) cancelledCode
  DB.execute db updateInvoiceStatusQ ("expired" :: Text, addUTCTime (-60) now, cancelledInvoice, "open" :: Text)
  insertStorePayment googlePayment "google" (googlePurchaseRef googleSupporterToken) Nothing Nothing
  googlePurchase <- insertStorePurchase google "supporter" googlePayment
  let g1 = grantEntry t "master-google-1" BTSupporter 1 (SCPayment Nothing) (emptyEntry t BTSupporter)
      g2 = fromJust $ issueEntry t "master-google-2" g1
  void $ ledgerRow googlePurchase ("credit", Just "payment", Nothing) (Just googlePayment, Nothing, Nothing, Nothing) g1
  googleCredential <- issuedRow googlePurchase google g1 g2
  insertStorePayment movedPayment "google" (googlePurchaseRef googleSubscriptionToken) (Just "renewing") (Just googleSubscriptionToken)
  DB.execute db insertSubscriptionChargeQ (("charge-g1" :: Text, movedPayment, "google-charge-1" :: Text, "subscr_badge_supporter_01" :: Text, t, addMonths 1 t) :. (Nothing :: Maybe Int, Nothing :: Maybe Text, t))
  movedFromPurchase <- insertStorePurchase movedFrom "supporter" movedPayment
  let f1 = grantEntry t "master-from-1" BTSupporter 1 (SCCharge "charge-g1") (emptyEntry t BTSupporter)
      f2 = fromJust $ issueEntry t "master-from-2" f1
      f3 = debitEntry t "master-from-3" (SDTransferOut $ holderKey movedTo) f2
  void $ ledgerRow movedFromPurchase ("credit", Just "charge", Nothing) (Nothing, Just "charge-g1", Nothing, Nothing) f1
  void $ issuedRow movedFromPurchase movedFrom f1 f2
  DB.execute db releasePaymentQ (t, movedFromPurchase, movedPayment)
  movedToPurchase <- insertStorePurchase movedTo "supporter" movedPayment
  void $ ledgerRow movedFromPurchase ("debit", Nothing, Just "transferOut") (Nothing, Nothing, Nothing, Just movedToPurchase) f3
  DB.execute db markReboundQ (t, t, movedPayment)
  let n1 = grantEntry t "master-to-1" BTSupporter 1 (SCTransferIn $ holderKey movedFrom) (emptyEntry t BTSupporter)
      n2 = fromJust $ issueEntry t "master-to-2" n1
  void $ ledgerRow movedToPurchase ("credit", Just "transferIn", Nothing) (Nothing, Nothing, Just movedFromPurchase, Nothing) n1
  void $ issuedRow movedToPurchase movedTo n1 n2
  insertStorePayment applePayment "apple" appleSubscriptionOriginalId (Just "renewing") Nothing
  DB.execute db stampSubscriptionCheckQ (now, now, applePayment)
  DB.execute db setSubscriptionStateQ ("cancelled" :: Text, now, applePayment)
  DB.execute db insertSubscriptionChargeQ (("charge-a1" :: Text, applePayment, "apple-charge-1" :: Text, "SUBSCR_BADGE_SUPPORTER_MONTH_01" :: Text, t, addMonths 1 t) :. (Just (699 :: Int), Just ("USD" :: Text), t))
  DB.execute db insertSubscriptionChargeQ (("charge-a2" :: Text, applePayment, "apple-charge-2" :: Text, "SUBSCR_BADGE_LEGEND_MONTH_01" :: Text, t, addMonths 1 t) :. (Just (6999 :: Int), Just ("USD" :: Text), t))
  applePurchase <- insertStorePurchase apple "supporter" applePayment
  let a1 = grantEntry t "master-apple-1" BTSupporter 1 (SCCharge "charge-a1") (emptyEntry t BTSupporter)
      a2 = fromJust $ issueEntry t "master-apple-2" a1
      a3 = debitEntry t "master-apple-3" (SDUpgrade $ holderKey apple) a2
      a4 = grantEntry t "master-apple-4" BTLegend 1 (SCCharge "charge-a2") a3
      a5 = fromJust $ issueEntry t "master-apple-5" a4
  void $ ledgerRow applePurchase ("credit", Just "charge", Nothing) (Nothing, Just "charge-a1", Nothing, Nothing) a1
  void $ issuedRow applePurchase apple a1 a2
  void $ ledgerRow applePurchase ("debit", Nothing, Just "upgrade") (Nothing, Nothing, Nothing, Just applePurchase) a3
  void $ ledgerRow applePurchase ("credit", Just "charge", Nothing) (Nothing, Just "charge-a2", Nothing, Nothing) a4
  void $ issuedRow applePurchase apple a4 a5
  DB.execute db setPurchaseBadgeTypeQ ("legend" :: Text, t, applePurchase)
  DB.execute db insertManagedGroupQ (1 :: Int64, "https://localhost/g#master-group" :: Text, t)
  DB.execute db markOwnerBootstrappedQ (Only (1 :: Int64))
  pure
    Seed
      { singleLedger = [s1, s2],
        singleCredential,
        singleCodeId,
        singlePurchase,
        multiCodeId,
        restLedger,
        restPurchase,
        googleLedger = [g1, g2],
        googleCredential,
        googlePurchase,
        movedFromLedger = [f1, f2, f3],
        movedFromPurchase,
        movedToLedger = [n1, n2],
        movedToPurchase,
        appleLedger = [a1, a2, a3, a4, a5],
        applePurchase
      }
  where
    noRefs = (Nothing, Nothing, Nothing, Nothing)
    restTags = [("credit", Just "opening", Nothing), ("debit", Nothing, Just "lapse"), ("credit", Just "support", Nothing), ("debit", Nothing, Just "support"), ("debit", Nothing, Just "refund")]
    insertCode :: BadgeCode -> Text -> Int -> Text -> Int -> IO Int64
    insertCode code badgeType months status limit = do
      DB.execute db insertBadgeCodeQ (Binary $ badgeCodeHash code, badgeType, months, status, limit, t)
      insertedRowId db
    insertCodePurchase :: Holder -> Text -> Int64 -> IO Int64
    insertCodePurchase Holder {holderKey, holderMaster = BadgeMasterKey mk} badgeType codeId = do
      DB.execute db insertCodePurchaseQ (holderKey, Binary mk, badgeType, badgeType, "issued" :: Text, codeId, t, t)
      insertedRowId db
    insertStorePayment :: Text -> Text -> Text -> Maybe Text -> Maybe Text -> IO ()
    insertStorePayment paymentId provider providerRef state token =
      DB.execute db insertStorePaymentQ ((paymentId, provider, providerRef, Nothing :: Maybe Int, Nothing :: Maybe Text, "settled" :: Text) :. (state, t <$ state, token, t, t))
    insertStorePurchase :: Holder -> Text -> Text -> IO Int64
    insertStorePurchase Holder {holderKey, holderMaster = BadgeMasterKey mk} badgeType paymentId = do
      DB.execute db insertStorePurchaseQ (holderKey, Binary mk, badgeType, badgeType, "issued" :: Text, paymentId, t, t)
      insertedRowId db
    ledgerRow :: Int64 -> (Text, Maybe Text, Maybe Text) -> (Maybe Text, Maybe Text, Maybe Int64, Maybe Int64) -> StatementEntry -> IO Int64
    ledgerRow purchaseId (entryType, credit, debit) (paymentId, chargeId, fromId, toId) StatementEntry {entryId, changeMonths, balanceMonths, balanceStartTs, balanceAnchorTs, balanceBadgeType, createdAt} = do
      DB.execute
        db
        insertLedgerRowQ
        ((entryId, purchaseId, changeMonths, balanceMonths, balanceStartTs, balanceAnchorTs) :. (masterBadgeType balanceBadgeType, createdAt, createdAt, entryType, credit, debit, paymentId, chargeId) :. (fromId, toId))
      insertedRowId db
    issuedRow :: Int64 -> Holder -> StatementEntry -> StatementEntry -> IO BadgeCredential
    issuedRow purchaseId Holder {holderMaster} previous issued@StatementEntry {entryId, balanceStartTs = periodEnd, balanceBadgeType, createdAt} = do
      rowId <- ledgerRow purchaseId ("debit", Nothing, Just "badge") noRefs issued
      let BadgeIssuerKey {keyIdx, secretKey} = issuer
          badgeInfo = BadgeInfo {badgeType = balanceBadgeType, badgeExpiry = endOfMondayAfter periodEnd, badgeExtra = ""}
      credential <- either fail pure =<< issueBadge keyIdx secretKey (VerifiedBadgeRequest BadgeRequest {masterKey = holderMaster, badgeInfo})
      DB.execute
        db
        insertIssuanceQ
        ((entryId, purchaseId, rowId, masterBadgeType balanceBadgeType) :. (balanceStartTs previous, periodEnd, endOfMondayAfter periodEnd, Binary (LB.toStrict $ J.encode credential), createdAt))
      pure credential
    invoiceRows :: Text -> Text -> (Maybe Text, Maybe Text, Maybe Text, Maybe Text) -> UTCTime -> UTCTime -> BadgeCode -> IO ()
    invoiceRows invoiceId provider (url, address, cryptoCurrency, cryptoAmount) expiresAt createdAt code = do
      DB.execute db insertInvoiceQ ((invoiceId, provider, 700 :: Int, 0 :: Int, Nothing :: Maybe Int, 700 :: Int, "usd" :: Text) :. (url, address, cryptoCurrency, cryptoAmount, expiresAt, "open" :: Text, createdAt, createdAt))
      DB.execute db insertInvoiceCodeQ (Binary $ badgeCodeHash code, "supporter" :: Text, 1 :: Int, "unpaid" :: Text, createdAt)
      codeId <- insertedRowId db
      DB.execute db insertBadgeCodeInvoiceQ (invoiceId, codeId, "price_supporter" :: Text, Nothing :: Maybe Text, refOf invoiceId, createdAt)
    catalogPrices :: [(Text, Text, Int, Text, Text, UTCTime)]
    catalogPrices = [("price_supporter", "supporter", 700, "usd", "active", t), ("price_legend", "legend", 7000, "usd", "active", t)]
    catalogOffers :: [(Text, Maybe Text, Int, Maybe Int, Maybe Int, Text, UTCTime)]
    catalogOffers =
      [ ("offer_3m", Just "price_legend", 3, Just 1, Nothing, "active", t),
        ("offer_12m", Just "price_legend", 12, Nothing, Just 50, "active", t),
        ("offer_3m_s", Just "price_supporter", 3, Just 1, Nothing, "active", t),
        ("offer_12m_s", Just "price_supporter", 12, Nothing, Just 50, "active", t)
      ]

masterBadgeType :: BadgeType -> Text
masterBadgeType = \case
  BTSupporter -> "supporter"
  BTLegend -> "legend"
  BTInvestor -> "investor"
  BTUnknown tag -> tag

readsBack :: HasCallStack => ChatController -> MasterRows -> Seed -> IO ()
readsBack cc@ChatController {chatStore = st} MasterRows {rowsAt, singleCode, single, multiCode, multi, revokedCode, restCode, rest, lapsedCode, openCode, google, movedFrom, movedTo, apple} seed = do
  (prices, offers) <- readCatalogRows st
  sort (map (\BadgePrice {priceId = BadgePriceId p} -> p) prices) `shouldBe` sort ["price_supporter", "price_legend"]
  sort (map (\BadgeOffer {offerId = BadgeOfferId o} -> o) offers) `shouldBe` sort ["offer_3m", "offer_12m", "offer_3m_s", "offer_12m_s"]
  forM_ invoices $ \(invoiceId, provider, status) -> do
    Just InvoiceRow {irProvider, irProviderRef, irProduct, irStatus} <- getInvoice st (InvoiceId invoiceId)
    (irProvider, irProviderRef, irProduct, irStatus) `shouldBe` (provider, refOf invoiceId, IPBadge BTSupporter 1, status)
    fmap irInvoiceId <$> getInvoiceByProviderRef st (refOf invoiceId) `shouldReturn` Just (InvoiceId invoiceId)
  fmap sort <$> unpaidRefs st (addUTCTime (-30 * nominalDay) rowsAt) `shouldReturn` ([], sort [(PPCrypto, refOf openInvoice), (PPCrypto, refOf partInvoice), (PPCrypto, refOf expiredInvoice), (PPStripe, refOf cancelledInvoice)])
  now <- getCurrentTime
  withTransaction st $ \db -> do
    let codeOf code = fmap codeFields <$> getBadgeCode db (badgeCodeHash code)
        codeFields IssuedCode {badgeType, months, paymentStatus, revokedAt, expiresAt, redeemLimit, redeemCount} = (badgeType, months, paymentStatus, isJust revokedAt, isJust expiresAt, redeemLimit, redeemCount)
    codeOf singleCode `shouldReturn` Just (BTSupporter, 2, CPSFree, False, False, 1, 1)
    codeOf multiCode `shouldReturn` Just (BTLegend, 1, CPSPaid, False, False, 3, 1)
    codeOf revokedCode `shouldReturn` Just (BTSupporter, 1, CPSFree, True, False, 1, 0)
    codeOf restCode `shouldReturn` Just (BTSupporter, 3, CPSFree, False, False, 1, 1)
    codeOf lapsedCode `shouldReturn` Just (BTSupporter, 1, CPSPaid, False, True, 1, 0)
    codeOf openCode `shouldReturn` Just (BTSupporter, 1, CPSUnpaid, False, False, 1, 0)
    fmap (\CodeTracker {trackerItemId, redeemLimit, redeemCount} -> (trackerItemId, redeemLimit, redeemCount)) <$> getCodeTracker db (multiCodeId seed) `shouldReturn` Just (trackerItem, 3, 1)
    getCodePurchaseForKey db (singleCodeId seed) (holderKey single) >>= \case
      KeyRedeemed _ -> pure ()
      _ -> expectationFailure "the redeemed code's purchase is not read back"
    getCurrentIssuance db (singlePurchase seed) now `shouldReturn` Just (singleCredential seed)
    forM_ [(single, BTSupporter), (multi, BTLegend), (rest, BTSupporter), (google, BTSupporter), (movedFrom, BTSupporter), (movedTo, BTSupporter), (apple, BTLegend)] $ \(Holder {holderKey}, badgeType) ->
      fmap (\ServicePurchase {badgeType = t} -> t) <$> getPurchaseByKey db holderKey `shouldReturn` Just badgeType
    forM_ [(singlePurchase, singleLedger), (restPurchase, restLedger), (googlePurchase, googleLedger), (movedFromPurchase, movedFromLedger), (movedToPurchase, movedToLedger), (applePurchase, appleLedger)] $ \(purchase, ledger) ->
      fmap entriesJSON <$> getLedgerEntries db (purchase seed) 0 `shouldReturn` Just (entriesJSON $ ledger seed)
    creditedTo db PPGoogle (googlePurchaseRef googleSupporterToken) `shouldReturn` Just (holderKey google, Nothing)
    creditedTo db PPGoogle (googlePurchaseRef googleSubscriptionToken) `shouldReturn` Just (holderKey movedTo, Just SSRenewing)
    creditedTo db PPApple appleSubscriptionOriginalId `shouldReturn` Just (holderKey apple, Just SSCancelled)
    fmap (\PurchaseSubscription {paymentId, provider, storedState, checkedAt} -> (paymentId, provider, storedState, isJust checkedAt)) <$> getPurchaseSubscription db (applePurchase seed)
      `shouldReturn` Just (applePayment, PPApple, SSCancelled, True)
    getSubscriptionCharge db applePayment "apple-charge-1" `shouldReturn` Just ("charge-a1", True)
    getSubscriptionCharge db applePayment "apple-charge-2" `shouldReturn` Just ("charge-a2", True)
    getSubscriptionCharge db movedPayment "google-charge-1" `shouldReturn` Just ("charge-g1", True)
    fmap (\ManagedGroup {mgGroupId, mgOwnerBootstrapped} -> (mgGroupId, mgOwnerBootstrapped)) <$> getManagedGroup db `shouldReturn` Just (1, True)
    badgeCounts db now `shouldReturn` BadgeCounts {bcPurchases = [(PSIssued, 7)], bcSubscriptions = [(SSCancelled, 1), (SSRenewing, 1)], bcOpenCodes = 1}
  rowCount cc "sx_badge_service_badge_issuances" `shouldReturn` 7
  where
    invoices =
      [ (openInvoice, PPCrypto, ISOpen),
        (partInvoice, PPCrypto, ISOpen),
        (paidInvoice, PPStripe, ISPaid),
        (expiredInvoice, PPCrypto, ISExpired),
        (cancelledInvoice, PPStripe, ISExpired)
      ]
    creditedTo db provider ref =
      getStorePaymentCredit db provider ref <&> \case
        Credited CreditedPurchase {purchaseKey, subscription} -> Just (purchaseKey, subscription)
        _ -> Nothing

webFlowsOnRows :: HasCallStack => ChatController -> MasterRows -> IO ()
webFlowsOnRows ChatController {chatStore = st} MasterRows {openCode} = do
  createDirectoryIfMissing True "tests/tmp"
  withTempDirectory "tests/tmp" "badge-compat-static" $ \root -> do
    staticDir <- prepareStaticDir root
    provider <- newIORef (newStubState (Right sampleProviderInvoice))
    let cfg = (testServiceConfig staticDir True) {btcpay = Just testBTCPayConfig}
    withListener [stubProvider provider, (stubProvider provider) {pProvider = PPStripe}] True holdMicros st cfg $ \env client -> do
      open <- webGet client ("/api/invoice/" <> unpackText openInvoice)
      statusOf open `shouldBe` 200
      o <- jsonObject open
      map (fieldOf o) ["status", "badgeType", "months", "address"] `shouldBe` map Just [J.String "open", J.String "supporter", J.Number 1, J.String "bc1qmasteropen"]
      paid <- webGet client ("/api/invoice/" <> unpackText paidInvoice) >>= jsonObject
      fieldOf paid "status" `shouldBe` Just (J.String "paid")
      fieldOf paid "settledAt" `shouldSatisfy` isJust
      cancelled <- webRequestBody client "POST" ("/api/invoice/" <> unpackText partInvoice <> "/cancel") [] ""
      statusOf cancelled `shouldBe` 409
      settledAt <- getCurrentTime
      setSignals provider [(refOf openInvoice, SigSettled (rcv 700 (Just "0.00050000")) settledAt)]
      pollerFor env >>= runOnePass
      fmap irStatus <$> getInvoice st (InvoiceId openInvoice) `shouldReturn` Just ISPaid
      withTransaction st (\db -> fmap (\IssuedCode {paymentStatus} -> paymentStatus) <$> getBadgeCode db (badgeCodeHash openCode)) `shouldReturn` Just CPSPaid
  where
    unpackText = T.unpack

seedBadgePriceQ, seedBadgeOfferQ, insertBadgeCodeQ, claimCodeUseQ, setCodeGroupItemQ, revokeCodeQ, insertCodePurchaseQ, insertStorePaymentQ, insertStorePurchaseQ, insertLedgerRowQ, insertIssuanceQ :: Query
seedBadgePriceQ = "INSERT INTO sx_badge_service_badge_prices (price_id, badge_type, month_price, currency, status, created_at) VALUES (?,?,?,?,?,?) ON CONFLICT (price_id) DO NOTHING"
seedBadgeOfferQ = "INSERT INTO sx_badge_service_badge_offers (offer_id, price_id, months, free_months, discount, status, created_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT (offer_id) DO NOTHING"
insertBadgeCodeQ = "INSERT INTO sx_badge_service_badge_codes (code_hash, badge_type, months, code_payment_status, redeem_limit, created_at) VALUES (?,?,?,?,?,?)"
claimCodeUseQ = "UPDATE sx_badge_service_badge_codes SET redeem_count = redeem_count + 1, redeemed_at = ? WHERE badge_code_id = ? AND redeem_count < redeem_limit AND revoked_at IS NULL"
setCodeGroupItemQ = "UPDATE sx_badge_service_badge_codes SET group_item_id = ?, group_item_sent_at = ? WHERE badge_code_id = ?"
revokeCodeQ = "UPDATE sx_badge_service_badge_codes SET revoked_at = ? WHERE code_hash = ? AND revoked_at IS NULL AND redeem_count < redeem_limit"
insertCodePurchaseQ = "INSERT INTO sx_badge_service_badge_purchases (purchase_key, master_key, initial_badge_type, current_badge_type, status, badge_code_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)"
insertStorePaymentQ = "INSERT INTO sx_badge_service_payments (payment_id, provider, provider_ref, amount, currency, status, subscription_state, subscription_checked_at, provider_token, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT (provider, provider_ref) DO NOTHING"
insertStorePurchaseQ = "INSERT INTO sx_badge_service_badge_purchases (purchase_key, master_key, initial_badge_type, current_badge_type, status, payment_id, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?)"
insertLedgerRowQ = "INSERT INTO sx_badge_service_badge_ledger (entry_uuid, badge_purchase_id, change_months, balance_months, balance_start_ts, balance_anchor_ts, balance_badge_type, service_created_at, created_at, entry_type, entry_credit_type, entry_debit_type, payment_id, charge_id, from_purchase_id, to_purchase_id) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
insertIssuanceQ = "INSERT INTO sx_badge_service_badge_issuances (issuance_id, badge_purchase_id, entry_id, badge_type, period_start, period_end, expiry, credential, created_at) VALUES (?,?,?,?,?,?,?,?,?)"

releasePaymentQ, markReboundQ, stampSubscriptionCheckQ, setSubscriptionStateQ, insertSubscriptionChargeQ, setPurchaseBadgeTypeQ, insertManagedGroupQ, markOwnerBootstrappedQ :: Query
releasePaymentQ = "UPDATE sx_badge_service_badge_purchases SET payment_id = NULL, updated_at = ? WHERE badge_purchase_id = ? AND payment_id = ?"
markReboundQ = "UPDATE sx_badge_service_payments SET rebound_at = ?, updated_at = ? WHERE payment_id = ?"
stampSubscriptionCheckQ = "UPDATE sx_badge_service_payments SET subscription_checked_at = ?, updated_at = ? WHERE payment_id = ?"
setSubscriptionStateQ = "UPDATE sx_badge_service_payments SET subscription_state = ?, updated_at = ? WHERE payment_id = ?"
insertSubscriptionChargeQ = "INSERT INTO sx_badge_service_subscription_charges (charge_id, payment_id, provider_charge_ref, plan_id, period_start, period_end, amount, currency, created_at) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT (payment_id, provider_charge_ref) DO NOTHING"
setPurchaseBadgeTypeQ = "UPDATE sx_badge_service_badge_purchases SET current_badge_type = ?, updated_at = ? WHERE badge_purchase_id = ?"
insertManagedGroupQ = "INSERT INTO sx_badge_service_group (group_id, group_link, owner_bootstrapped, created_at) SELECT ?,?,0,? WHERE NOT EXISTS (SELECT 1 FROM sx_badge_service_group)"
markOwnerBootstrappedQ = "UPDATE sx_badge_service_group SET owner_bootstrapped = 1 WHERE group_id = ? AND owner_bootstrapped = 0"

insertInvoiceQ, insertInvoiceCodeQ, insertBadgeCodeInvoiceQ, upsertPaymentQ, updateInvoiceStatusQ, markCodePaidQ, expireOverdueQ :: Query
insertInvoiceQ = "INSERT INTO sx_badge_service_invoices (invoice_id, provider, price, discount_amount, credit_amount, amount, currency, payment_url, payment_address, payment_crypto_currency, payment_crypto_amount, expires_at, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
insertInvoiceCodeQ = "INSERT INTO sx_badge_service_badge_codes (code_hash, badge_type, months, code_payment_status, created_at) VALUES (?,?,?,?,?)"
insertBadgeCodeInvoiceQ = "INSERT INTO sx_badge_service_badge_code_invoices (invoice_id, badge_code_id, price_id, offer_id, provider_ref, created_at) VALUES (?,?,?,?,?,?)"
upsertPaymentQ =
  "INSERT INTO sx_badge_service_payments (payment_id, invoice_id, provider, provider_ref, amount, currency, crypto_paid, crypto_due, paid_in_full, status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT (payment_id) DO UPDATE SET amount = "
    <> largerOf
    <> "(COALESCE(sx_badge_service_payments.amount, 0), excluded.amount), crypto_paid = CASE WHEN excluded.amount > COALESCE(sx_badge_service_payments.amount, 0) OR sx_badge_service_payments.crypto_paid IS NULL THEN excluded.crypto_paid ELSE sx_badge_service_payments.crypto_paid END, crypto_due = COALESCE(excluded.crypto_due, sx_badge_service_payments.crypto_due), paid_in_full = "
    <> largerOf
    <> "(sx_badge_service_payments.paid_in_full, excluded.paid_in_full), status = CASE WHEN sx_badge_service_payments.status = 'settled' THEN sx_badge_service_payments.status ELSE excluded.status END, updated_at = CASE WHEN sx_badge_service_payments.status = 'settled' THEN sx_badge_service_payments.updated_at ELSE excluded.updated_at END"
updateInvoiceStatusQ = "UPDATE sx_badge_service_invoices SET status = ?, updated_at = ? WHERE invoice_id = ? AND status = ?"
markCodePaidQ = "UPDATE sx_badge_service_badge_codes SET code_payment_status = ?, expires_at = ? WHERE code_hash = ? AND code_payment_status = ?"
expireOverdueQ = "UPDATE sx_badge_service_invoices SET status = 'expired', updated_at = ? WHERE status = 'open' AND expires_at < ? AND invoice_id = ? AND NOT EXISTS (SELECT 1 FROM sx_badge_service_payments p WHERE p.invoice_id = sx_badge_service_invoices.invoice_id AND (COALESCE(p.amount, 0) > 0 OR p.crypto_paid IS NOT NULL OR p.paid_in_full = 1)) AND EXISTS (SELECT 1 FROM sx_badge_service_badge_code_invoices ci WHERE ci.invoice_id = sx_badge_service_invoices.invoice_id)"

largerOf :: Query
#if defined(dbPostgres)
largerOf = "GREATEST"
#else
largerOf = "MAX"
#endif

data MasterCLI = MasterCLI
  { cliConn :: WS.Connection,
    cliNext :: TVar Int,
    cliAnswers :: TMap Text (TMVar J.Value)
  }

data MasterClient = MasterClient
  { clientBin :: FilePath,
    clientClock :: FilePath
  }

withMasterClient :: HasCallStack => (MasterClient -> TestParams -> IO ()) -> TestParams -> IO ()
withMasterClient test ps =
  lookupEnv "MASTER_CLIENT_BIN" >>= \case
    Nothing -> pendingWith "scripts/ci/scope-tests.sh badge-compat runs it with MASTER_CLIENT_BIN"
    Just clientBin -> do
      let clientClock = tmpPath ps </> "master-clock"
      writeFile clientClock "0"
      test MasterClient {clientBin, clientClock} ps

withMasterCLI :: HasCallStack => MasterClient -> TestParams -> StoreServiceEnv -> String -> Int -> (MasterCLI -> IO a) -> IO a
withMasterCLI MasterClient {clientBin, clientClock} ps StoreServiceEnv {bsAddress, bsClientCfg = ChatConfig {badgePublicKeys}} name n action = do
  let port = testPort (5 + n) ps
      issuerKey = maybe (error "no test issuer key") (B.unpack . strEncode) $ M.lookup testIssuerKeyIdx badgePublicKeys
      presetServer = "smp://" <> testServerKeyHash <> "@localhost:" <> smpTestPort ps
      vars = [("STORE_SERVICE_ADDRESS", bsAddress), ("BADGE_ISSUER_KEY", issuerKey), ("SMP_PRESET_SERVER", presetServer), ("BADGE_CLOCK_FILE", clientClock)]
      args = ["-d", tmpPath ps </> name, "-s", smpServerStr ps, "-p", port, "--user-display-name", name, "--yes-migrate"]
  inherited <- getEnvironment
  withFile (tmpPath ps </> name <> ".log") WriteMode $ \logH ->
    bracket (createProcess (proc clientBin args) {env = Just $ vars <> inherited, std_out = UseHandle logH, std_err = UseHandle logH}) cleanupProcess $ \_ ->
      connected (read port) (20 * 10 :: Int) $ \cliConn -> do
        cli <- MasterCLI cliConn <$> newTVarIO 0 <*> TM.emptyIO
        withAsync (forever $ routeAnswer cli) $ \_ -> action cli
  where
    connected port attempts app =
      E.try (WS.runClient "127.0.0.1" port "/" app) >>= \case
        Right r -> pure r
        Left (e :: E.IOException)
          | attempts > 0 -> threadDelay 100000 >> connected port (attempts - 1) app
          | otherwise -> E.throwIO e
    routeAnswer MasterCLI {cliConn, cliAnswers} =
      J.decode <$> WS.receiveData cliConn >>= \case
        Just (J.Object o)
          | Just (J.String corrId) <- KM.lookup "corrId" o,
            Just resp <- KM.lookup "resp" o ->
              atomically $ TM.lookup corrId cliAnswers >>= mapM_ (`putTMVar` resp)
        _ -> pure ()

cliCmd :: HasCallStack => MasterCLI -> String -> IO J.Value
cliCmd MasterCLI {cliConn, cliNext, cliAnswers} cmd = do
  (corrId, answer) <- atomically $ do
    corrId <- tshow <$> stateTVar cliNext (\i -> (i, i + 1))
    answer <- newEmptyTMVar
    TM.insert corrId answer cliAnswers
    pure (corrId, answer)
  WS.sendTextData cliConn $ J.encode $ J.object ["corrId" J..= corrId, "cmd" J..= cmd]
  timeout 60000000 (atomically $ takeTMVar answer <* TM.delete corrId cliAnswers) >>= maybe (error $ "master's CLI did not answer " <> cmd) pure

cliUntil :: HasCallStack => MasterCLI -> String -> (J.Value -> Bool) -> IO J.Value
cliUntil cli cmd done = go (60 :: Int)
  where
    go attempts = do
      r <- cliCmd cli cmd
      if done r || attempts <= 0 then pure r else threadDelay 500000 >> go (attempts - 1)

jsonAt :: [Text] -> J.Value -> Maybe J.Value
jsonAt path v = foldM (\case J.Object o -> (`KM.lookup` o) . JK.fromText; _ -> const Nothing) v path

redeemError :: J.Value -> Maybe J.Value
redeemError = jsonAt ["chatError", "errorType", "badgeRedeemError", "serviceError"]

sameLedgers :: HasCallStack => ChatController -> MasterCLI -> Int -> J.Value -> IO [(Int, Int, Maybe Text)]
sameLedgers cc cli userId state = do
  purchaseId <- maybe (error $ "no purchase in " <> show state) pure $ jsonAt ["badgeState", "badgePurchaseId"] state
  r <- cliCmd cli ("/_badge ledger " <> show userId <> " " <> LB.unpack (J.encode purchaseId))
  rows <- case J.fromJSON <$> jsonAt ["badgeLedger"] r of
    Just (J.Success entries) -> pure $ map replicated entries
    _ -> error $ "not a ledger: " <> show r
  case rows of
    (entryUuid, _, _, _, _, _) : _ -> purchaseLedgerRows cc entryUuid `shouldReturn` rows
    [] -> expectationFailure "master's client lists no ledger rows"
  pure $ map (\(_, ch, m, _, _, t) -> (ch, m, t)) rows
  where
    replicated :: StatementEntry -> ReplicatedRow
    replicated e@StatementEntry {entryId, changeMonths, balanceMonths, balanceStartTs, balanceBadgeType} =
      (entryId, changeMonths, balanceMonths, balanceStartTs, textEncode balanceBadgeType, Just $ entryTag e)

moveClocks :: MasterClient -> StoreServiceEnv -> Integer -> IO ()
moveClocks MasterClient {clientClock} StoreServiceEnv {bsClock} months = do
  setClockAt bsClock . addMonths months =<< getCurrentTime
  writeFile (clientClock <> ".new") (show months)
  renameFile (clientClock <> ".new") clientClock

testMasterRedeems :: HasCallStack => MasterClient -> TestParams -> IO ()
testMasterRedeems client ps =
  withStoreServiceEnv ps $ \env@StoreServiceEnv {bsController = cc} ->
    withMasterCLI client ps env "alice" 0 $ \alice -> do
      code <- issueCode cc BTSupporter 2
      redeemed <- cliCmd alice ("/_redeem_badge_code 1 " <> codeArg code)
      map (`jsonAt` redeemed) [["type"], ["newBadge"], ["redeemedBadge", "badge", "badgeType"], ["badgeState", "badgeType"]]
        `shouldBe` map Just [J.String "badgeRedeemed", J.Bool True, J.String "supporter", J.String "supporter"]
      sameLedgers cc alice 1 redeemed `shouldReturn` [(2, 2, Just "code"), (-1, 1, Just "badge")]
      again <- cliCmd alice ("/_redeem_badge_code 1 " <> codeArg code)
      map (`jsonAt` again) [["type"], ["newBadge"]] `shouldBe` map Just [J.String "badgeRedeemed", J.Bool False]
      void $ cliCmd alice "/create user alisa"
      unknown <- C.newRandom >>= randomBadgeCode
      redeemError <$> cliCmd alice ("/_redeem_badge_code 2 " <> codeArg unknown) `shouldReturn` Just (J.String "code_invalid")
      redeemError <$> cliCmd alice ("/_redeem_badge_code 2 " <> codeArg code) `shouldReturn` Just (J.String "code_used")
      expiring <- issueCodeAs cc BTSupporter 1 "unpaid"
      now <- getCurrentTime
      withDB' "markCodePaid" cc (\db -> markCodePaid db (badgeCodeHash expiring) (addUTCTime (-60) now)) `shouldReturn` Right ()
      redeemError <$> cliCmd alice ("/_redeem_badge_code 2 " <> codeArg expiring) `shouldReturn` Just (J.String "code_expired")

testMasterRenews :: HasCallStack => MasterClient -> TestParams -> IO ()
testMasterRenews client ps =
  withStoreServiceEnv ps $ \env@StoreServiceEnv {bsController = cc} ->
    withMasterCLI client ps env "alice" 0 $ \alice -> do
      code <- issueCode cc BTSupporter 2
      redeemed <- cliCmd alice ("/_redeem_badge_code 1 " <> codeArg code)
      ledger <- sameLedgers cc alice 1 redeemed
      repeated <- cliCmd alice "/_badge request 1"
      map (`jsonAt` repeated) [["type"], ["badgeState", "paidThrough"], ["badgeState", "monthsLeft"]]
        `shouldBe` [Just (J.String "badgeState"), jsonAt ["badgeState", "paidThrough"] redeemed, Just (J.Number 1)]
      sameLedgers cc alice 1 repeated `shouldReturn` ledger
      rowCount cc "sx_badge_service_badge_issuances" `shouldReturn` 1
      moveClocks client env 1
      renewed <- cliCmd alice "/_badge request 1"
      map (`jsonAt` renewed) [["badgeState", "paidThrough"], ["badgeState", "monthsLeft"], ["badgeState", "issueError"]]
        `shouldBe` [jsonAt ["badgeState", "paidThrough"] redeemed, Just (J.Number 0), Nothing]
      sameLedgers cc alice 1 renewed `shouldReturn` ledger <> [(-1, 0, Just "badge")]
      rowCount cc "sx_badge_service_badge_issuances" `shouldReturn` 2

testMasterPlayPurchase :: HasCallStack => MasterClient -> TestParams -> IO ()
testMasterPlayPurchase client ps =
  withStoreServiceEnv ps $ \env@StoreServiceEnv {bsController = cc} ->
    withMasterCLI client ps env "bob" 0 $ \bob -> do
      invoice <- cliCmd bob "/_badge invoice 1"
      invoiceId <- case jsonAt ["invoiceId"] invoice of
        Just (J.String i) -> pure $ T.unpack i
        _ -> error $ "no invoice in " <> show invoice
      void $ cliCmd bob (purchaseWithInvoice 1 invoiceId supporterPlay)
      credited <- cliUntil bob "/_badge state 1" $ \r -> shownAs "supporter" r && jsonAt ["storePurchases"] r == Just (J.Array mempty)
      map (`jsonAt` credited) [["badgeState", "badgeType"], ["badgeState", "shown"], ["storePurchases"]] `shouldBe` map Just [J.String "supporter", J.Bool True, J.Array mempty]
      sameLedgers cc bob 1 credited `shouldReturn` [(1, 1, Just "payment"), (-1, 0, Just "badge")]
      rowCount cc "sx_badge_service_badge_purchases" `shouldReturn` 1

testMasterRestore :: HasCallStack => MasterClient -> TestParams -> IO ()
testMasterRestore client ps =
  withStoreServiceEnv ps $ \env@StoreServiceEnv {bsController = cc, bsStore = store} -> do
    firstStart <- addUTCTime (-3600) <$> serviceNow env
    storeReports store $ subscriptionCheck SSRenewing $ Just $ storeCharge "subscr-badge-supporter-month-02" firstStart 1
    withMasterCLI client ps env "bob" 0 $ \bob -> do
      void $ cliCmd bob ("/_badge purchase 1 " <> paymentArg subscriptionPlay)
      bought <- cliUntil bob "/_badge state 1" $ shownAs "supporter"
      map (`jsonAt` bought) [["badgeState", "badgeType"], ["badgeState", "subscription", "status"]] `shouldBe` map Just [J.String "supporter", J.String "renewing"]
      sameLedgers cc bob 1 bought `shouldReturn` [(1, 1, Just "charge"), (-1, 0, Just "badge")]
      withMasterCLI client ps env "cath" 1 $ \cath -> do
        void $ cliCmd cath (restoredCmd 1 subscriptionPlay)
        restored <- cliUntil cath "/_badge state 1" $ shownAs "supporter"
        map (`jsonAt` restored) [["badgeState", "badgeType"], ["badgeState", "shown"]] `shouldBe` map Just [J.String "supporter", J.Bool True]
        sameLedgers cc cath 1 restored `shouldReturn` [(1, 1, Just "charge"), (-1, 0, Just "badge")]
      reboundPayments cc `shouldReturn` 1
      retired <- cliCmd bob "/_badge request 1"
      map (`jsonAt` retired) [["badgeState", "shown"], ["badgeState", "subscription", "status"]] `shouldBe` map Just [J.Bool False, J.String "ended"]

shownAs :: Text -> J.Value -> Bool
shownAs badgeType r = jsonAt ["badgeState", "badgeType"] r == Just (J.String badgeType) && jsonAt ["badgeState", "shown"] r == Just (J.Bool True)

testMasterUnsupported :: HasCallStack => MasterClient -> TestParams -> IO ()
testMasterUnsupported client ps =
  withStoreServiceEnv ps $ \env@StoreServiceEnv {bsAddress} ->
    withMasterCLI client ps env "alice" 0 $ \alice -> do
      let answer req = jsonAt ["responseData"] <$> cliCmd alice ("/_service_request 1 " <> bsAddress <> " " <> req)
          refused code = Just $ J.object ["code" J..= (code :: Text), "type" J..= ("error" :: Text)]
      answer "{\"version\":1,\"request\":{\"type\":\"pauseBadge\"}}" `shouldReturn` refused "unsupported_version"
      answer "{\"version\":2,\"request\":{\"type\":\"getBadgeCatalog\"}}" `shouldReturn` refused "unsupported_version"
      answer "{\"version\":1,\"request\":{\"type\":\"redeemBadgeCode\"}}" `shouldReturn` refused "bad_request"
