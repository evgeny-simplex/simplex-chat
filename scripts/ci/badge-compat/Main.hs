module Main where

import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Server (simplexChatServer)
import Simplex.Chat.Badges.Ledger (addMonths)
import Simplex.Chat.Controller (ChatConfig (..))
import Simplex.Chat.Terminal (terminalChatConfig)
import Simplex.Chat.Terminal.Main (simplexChatCLI)
import Simplex.Messaging.Encoding.String (StrEncoding, strDecode)
import System.Environment (getEnv)

main :: IO ()
main = do
  address <- decodedEnv "STORE_SERVICE_ADDRESS"
  issuerKey <- decodedEnv "BADGE_ISSUER_KEY"
  presetServer <- decodedEnv "SMP_PRESET_SERVER"
  clockFile <- getEnv "BADGE_CLOCK_FILE"
  simplexChatCLI
    terminalChatConfig
      { badgeServiceAddress = Just address,
        badgePublicKeys = issuerKey <$ badgePublicKeys terminalChatConfig,
        shortLinkPresetServers = pure presetServer,
        badgeCurrentTime = readFile clockFile >>= \months -> addMonths (read months) <$> badgeCurrentTime terminalChatConfig,
        badgeDevRequests = True
      }
    (Just simplexChatServer)

decodedEnv :: StrEncoding a => String -> IO a
decodedEnv name = getEnv name >>= either (fail . ((name <> ": ") <>)) pure . strDecode . encodeUtf8 . T.pack
