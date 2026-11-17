{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module StoreService.Names.View
  ( ViewReads (..),
    ViewRead (..),
    OrderView (..),
    PhaseView (..),
    PaidWith (..),
    BalanceView (..),
    SignedTerms (..),
    RegistrationRefusal (..),
    orderView,
    phaseView,
    readViewChain,
    toOrderView,
    balanceView,
    addressText,
    registrationAt,
    lapseMoment,
    registrationVersion,
  )
where

import Control.Concurrent.Async (concurrently)
import Control.Logger.Simple (logWarn)
import qualified Data.Aeson.TH as JQ
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Word (Word64)
import Simplex.Messaging.Agent.Store.Common (DBStore, withTransaction)
import Simplex.Messaging.Encoding.String (strEncode)
import Simplex.Messaging.Eth.Address (Address)
import Simplex.Messaging.Names.Record (USDCents)
import Simplex.Messaging.Parsers (defaultJSON, dropPrefix, taggedObjectJSON)
import Simplex.Messaging.SimplexName (LabelHash (..))
import Simplex.Messaging.Util (safeDecodeUtf8, tshow)
import Simplex.Chat.PaymentService.Types (ServicePaymentMethod)
import StoreService.Config (NamesConfig)
import StoreService.Names.Chain (ChainError, ChainSeconds, TxHash, chainTime, hex)
import StoreService.Names.Community (Acceptance, AcceptanceAsked, Community, acceptanceOf, communityOf, currentAcceptance)
import StoreService.Names.Contracts (Contracts (ctDeadline, ctViewSlots), sponsorNonce)
import StoreService.Names.Profiles (deadlineIn, withSlot)
import StoreService.Names.Registration (AgreedTerms (..), CommunityName, RegistrationId (..))
import StoreService.Names.Store (Balance (..), BalanceHold (..), BalanceUse (..), Commit (..), CommitStep, FailReason (..), HoldState, LateWait, NameRegistration (..), NameReveal (..), OrderPayment (..), OrderPhase (..), failedFrom, getBalance, getRegistration, heldBy, lateWait, paymentInvoice)

-- | A committed order's chain reads: the sponsor's nonce, and the acceptance of the terms of the name's kind until a reveal is stored.
data ViewReads = ViewReads
  { vrIntentNonce :: ViewRead Word64,
    vrAcceptance :: ViewRead AcceptanceAsked
  }
  deriving (Eq, Show)

-- | A read that failed is logged once, as it becomes VRUnread.
data ViewRead a = VRNotAsked | VRUnread | VRRead {value :: a}
  deriving (Eq, Show, Functor)

-- | An order as its link shows it. The secret, the signatures and the links of its reveal, and the ids of other orders, are not shown.
data OrderView = OrderView
  { registrationId :: RegistrationId,
    version :: Int64,
    labelHash :: Text,
    label :: Maybe Text,
    owner :: Address,
    commitment :: Text,
    sealed :: Text,
    terms :: SignedTerms,
    years :: Int,
    duration :: Word64,
    price :: USDCents,
    moves :: Int,
    payment :: PaidWith,
    balance :: Maybe BalanceView,
    latePayment :: Maybe LateWait,
    phase :: PhaseView,
    community :: Maybe Community
  }
  deriving (Show)

-- | The terms an order agreed to, with the hash in its 0x form.
data SignedTerms = SignedTerms {communityName :: CommunityName, termsHash :: Text}
  deriving (Show)

-- | The order's phase, with the chain reads of a committed order.
data PhaseView
  = PVUnpaid {live :: Bool}
  | PVQueued {commitStep :: Maybe CommitStep}
  | PVCommitting {commitTx :: Maybe TxHash}
  | PVCommitted {commit :: Commit, intentNonce :: ViewRead Word64, acceptance :: ViewRead Acceptance}
  | PVRegistering {commit :: Commit, registerTx :: TxHash}
  | PVRegistered {commitStep :: Maybe CommitStep, registeredTx :: Maybe (TxHash, Maybe Word64), expiresAt :: ChainSeconds, registeredAt :: UTCTime}
  | PVTaken {commitStep :: Maybe CommitStep, lastRegisterTx :: Maybe TxHash}
  | PVFailed {commitStep :: Maybe CommitStep, lastRegisterTx :: Maybe TxHash, failedAt :: UTCTime, reason :: FailReason}
  deriving (Show)

-- | What paid the order, without the ids of the paying order, its invoice and its code.
data PaidWith
  = PWInvoice {method :: ServicePaymentMethod}
  | PWDifference {method :: ServicePaymentMethod, fromBalance :: USDCents}
  | PWBalance {fromBalance :: USDCents}
  | PWCode
  deriving (Show)

-- | The holder is not named, so an order's link discloses no other order; an overdue hold reads as none.
data BalanceView = BalanceView {amount :: USDCents, hold :: Maybe HoldState, refunded :: USDCents}
  deriving (Eq, Show)

-- | A request that met the order changed, or at its limit of moves, answered with the order as it reads now.
data RegistrationRefusal
  = RRRegistrationChanged {registration :: OrderView}
  | RRMoveLimit {registration :: OrderView}
  deriving (Show)

$(JQ.deriveToJSON (taggedObjectJSON $ dropPrefix "VR") ''ViewRead)

$(JQ.deriveToJSON defaultJSON ''SignedTerms)

$(JQ.deriveToJSON (taggedObjectJSON $ dropPrefix "PV") ''PhaseView)

$(JQ.deriveToJSON (taggedObjectJSON $ dropPrefix "PW") ''PaidWith)

$(JQ.deriveToJSON defaultJSON ''BalanceView)

$(JQ.deriveToJSON defaultJSON ''OrderView)

$(JQ.deriveToJSON (taggedObjectJSON $ dropPrefix "RR") ''RegistrationRefusal)

-- | The balance as it reads at the given time, when a hold may have become overdue, and what a closed order's late money waits on.
orderView :: DBStore -> NamesConfig -> Contracts -> UTCTime -> NameRegistration -> IO OrderView
orderView st cfg ct now r = do
  (balance, late) <- withTransaction st $ \db -> do
    balance <- getBalance db (nrId r) now
    late <- maybe (pure Nothing) (lateWait db) (paymentInvoice $ nrPayment r)
    pure (balance, late)
  toOrderView cfg r balance late <$> phaseView ct r

-- | Only a committed order's view reads the chain.
phaseView :: Contracts -> NameRegistration -> IO PhaseView
phaseView ct r = case nrPhase r of
  OUnpaid live -> pure PVUnpaid {live}
  OQueued commitStep -> pure PVQueued {commitStep}
  OCommitting commitTx -> pure PVCommitting {commitTx}
  OCommitted commit -> (\ViewReads {vrIntentNonce, vrAcceptance} -> PVCommitted {commit, intentNonce = vrIntentNonce, acceptance = acceptanceOf <$> vrAcceptance}) <$> readViewChain ct r
  ORegistering commit registerTx -> pure PVRegistering {commit, registerTx}
  ORegistered commitStep registeredTx expiresAt registeredAt -> pure PVRegistered {commitStep, registeredTx, expiresAt, registeredAt}
  OTaken commitStep lastRegisterTx -> pure PVTaken {commitStep, lastRegisterTx}
  OFailed commitStep lastRegisterTx failedAt reason -> pure PVFailed {commitStep, lastRegisterTx, failedAt, reason}

-- | The intent nonce, and the acceptance until a reveal is stored, of a committed order.
readViewChain :: Contracts -> NameRegistration -> IO ViewReads
readViewChain ct NameRegistration {nrId = RegistrationId rid, nrOwner, nrLabelHash, nrReveal} = do
  deadline <- deadlineIn $ ctDeadline ct
  withSlot deadline (ctViewSlots ct) (concurrently (sponsorNonce ct nrOwner) acceptanceRead) >>= \case
    Just (nonce, acceptance_) -> ViewReads <$> readOf "intent nonce" nonce <*> maybe (pure VRNotAsked) (readOf "terms acceptance") acceptance_
    Nothing -> unread <$ logWarn ("names: the view of registration " <> rid <> " read the chain in no slot within its deadline")
  where
    acceptanceRead = maybe (Just <$> currentAcceptance ct nrLabelHash nrOwner) (const $ pure Nothing) nrReveal
    readOf :: Text -> Either ChainError a -> IO (ViewRead a)
    readOf what = either (\e -> VRUnread <$ logWarn ("names: the view of registration " <> rid <> " could not read the " <> what <> ": " <> tshow e)) (pure . VRRead)
    unread = ViewReads {vrIntentNonce = VRUnread, vrAcceptance = maybe VRUnread (const VRNotAsked) nrReveal}

toOrderView :: NamesConfig -> NameRegistration -> Maybe Balance -> Maybe LateWait -> PhaseView -> OrderView
toOrderView cfg r balance latePayment phase =
  OrderView
    { registrationId = nrId,
      version = nrVersion,
      labelHash = hex lh,
      label = rvLabel <$> nrReveal,
      owner = nrOwner,
      commitment = hex nrCommitment,
      sealed = nrSealed,
      terms = SignedTerms {communityName = atCommunityName, termsHash = hex atTermsHash},
      years = nrYears,
      duration = nrDuration,
      price = nrPrice,
      moves = nrMoves,
      payment = case nrPayment of
        OPInvoice method _ -> PWInvoice {method}
        OPDifference BalanceUse {buUsed} method _ -> PWDifference {method, fromBalance = buUsed}
        OPBalance BalanceUse {buUsed} -> PWBalance {fromBalance = buUsed}
        OPCode _ -> PWCode,
      balance = balanceView <$> balance,
      latePayment,
      phase,
      community = communityOf cfg (nrLabelHash r) atCommunityName
    }
  where
    NameRegistration {nrId, nrVersion, nrLabelHash = LabelHash lh, nrReveal, nrOwner, nrCommitment, nrSealed} = r
    NameRegistration {nrYears, nrDuration, nrPrice, nrPayment, nrMoves, nrAgreedTerms = AgreedTerms {atCommunityName, atTermsHash}} = r

balanceView :: Balance -> BalanceView
balanceView b@Balance {blAmount, blRefunded} = BalanceView {amount = blAmount, hold = bhState <$> heldBy b, refunded = blRefunded}

-- | EIP-55, as the page compares owners.
addressText :: Address -> Text
addressText = safeDecodeUtf8 . strEncode

-- | Versions start at 1, so a registration deleted during a hold reads as changed.
registrationVersion :: DBStore -> RegistrationId -> IO Int64
registrationVersion st rid = maybe 0 nrVersion <$> withTransaction st (`getRegistration` rid)

-- | Past revealBefore with no reveal, the commitment can no longer register, so it reads failed.
registrationAt :: UTCTime -> NameRegistration -> NameRegistration
registrationAt now r = case lapseMoment r of
  Just lapse | now > lapse -> r {nrPhase = failedFrom lapse FRNotSignedInTime $ nrPhase r}
  _ -> r

lapseMoment :: NameRegistration -> Maybe UTCTime
lapseMoment = \case
  NameRegistration {nrPhase = OCommitted Commit {revealBefore}, nrReveal = Nothing} -> Just $ chainTime revealBefore
  _ -> Nothing
