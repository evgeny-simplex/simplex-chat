{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module StoreService.Names.Community
  ( Community (..),
    communityFor,
    communityOf,
    termsFor,
    yearsFor,
    TermsLink (..),
    termsLink,
    nameTerms,
    readableTerms,
    AcceptanceAsked (..),
    Acceptance (..),
    acceptanceOf,
    currentAcceptance,
  )
where

import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import qualified Data.Aeson.TH as JQ
import Data.Bifunctor (bimap)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import Data.Word (Word64)
import Simplex.Messaging.Eth.Address (Address)
import Simplex.Messaging.Parsers (defaultJSON)
import Simplex.Messaging.SimplexName (LabelHash)
import StoreService.Config (NamesConfig (..))
import StoreService.Names.Chain (ChainError (..), hex)
import StoreService.Names.Contracts (Contracts, Terms (..), TermsRefusal (..), concurrent, kindTerms, namePolicy, policyNonce, termsLinks, termsText, together)
import qualified StoreService.Names.Contracts as Contracts
import StoreService.Names.Registration (AgreedTerms (..), CommunityName, TermsHash)

-- | A name the policy lists: what it is for, when the service has words for it, and the years it is registered for.
data Community = Community {for :: Maybe Text, years :: Int}
  deriving (Eq, Show)

-- | The terms a page shows and signs: their link and its hash.
data TermsLink = TermsLink {link :: Text, hash :: Text}
  deriving (Eq, Show)

-- | What the page signs to accept the terms of the name's kind, with the hash in its 0x form.
data Acceptance = Acceptance {communityName :: CommunityName, policy :: Address, termsHash :: Text, nonce :: Word64}
  deriving (Eq, Show)

$(JQ.deriveToJSON defaultJSON ''Community)

$(JQ.deriveToJSON defaultJSON ''TermsLink)

$(JQ.deriveToJSON defaultJSON ''Acceptance)

communityFor :: NamesConfig -> LabelHash -> Maybe Text
communityFor NamesConfig {nCommunity} lh = M.lookup lh nCommunity

communityOf :: NamesConfig -> LabelHash -> CommunityName -> Maybe Community
communityOf cfg lh community = if community then Just Community {for = communityFor cfg lh, years = communityYears} else Nothing

termsFor :: CommunityName -> Terms -> AgreedTerms
termsFor community Terms {tmHash} = AgreedTerms {atCommunityName = community, atTermsHash = tmHash}

-- | The paid years of a community name, whatever years its code or [names] years gives.
communityYears :: Int
communityYears = 2

yearsFor :: CommunityName -> Int -> Int
yearsFor community years = if community then communityYears else years

termsLink :: Terms -> TermsLink
termsLink Terms {tmLink, tmHash} = TermsLink {link = tmLink, hash = hex tmHash}

-- | Whether the policy lists the name, and the terms it is sold under: the community terms for a listed name, else the
-- general terms.
nameTerms :: Contracts -> LabelHash -> IO (Either ChainError (CommunityName, Maybe Terms))
nameTerms ct lh = together $ (\community links -> (community, kindTerms community links)) <$> concurrent (Contracts.communityName ct lh) <*> concurrent (termsLinks ct)

readableTerms :: Contracts -> Maybe Terms -> IO (Either (Maybe Int) Terms)
readableTerms ct = maybe (pure $ Left Nothing) $ \t -> bimap waitOf (const t) <$> termsText ct t
  where
    waitOf (TRWait seconds) = Just seconds

-- | What the page signs to accept the terms of the name's kind.
data AcceptanceAsked = AcceptanceAsked {acCommunity :: CommunityName, acPolicy :: Address, acTermsHash :: TermsHash, acNonce :: Word64}
  deriving (Eq, Show)

acceptanceOf :: AcceptanceAsked -> Acceptance
acceptanceOf AcceptanceAsked {acCommunity, acPolicy, acTermsHash, acNonce} =
  Acceptance {communityName = acCommunity, policy = acPolicy, termsHash = hex acTermsHash, nonce = acNonce}

currentAcceptance :: Contracts -> LabelHash -> Address -> IO (Either ChainError AcceptanceAsked)
currentAcceptance ct lh owner = runExceptT $ do
  (acCommunity, terms) <- ExceptT $ nameTerms ct lh
  Terms {tmHash = acTermsHash} <- maybe (throwError $ ChainUnavailable "the name policy has no terms of this kind that the service takes") pure terms
  acPolicy <- ExceptT $ namePolicy ct
  acNonce <- ExceptT $ policyNonce ct owner
  pure AcceptanceAsked {acCommunity, acPolicy, acTermsHash, acNonce}
