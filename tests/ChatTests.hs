module ChatTests where

import ChatTests.ChatList
import ChatTests.ChatRelays
import ChatTests.DBUtils
import ChatTests.Direct
import ChatTests.Files
import ChatTests.Forward
import ChatTests.Groups
import ChatTests.Local
import ChatTests.Profiles
import ChatTests.Utils (it)
import Control.Monad (forM_)
import Test.Hspec hiding (it)

chatTests :: SpecWith TestParams
chatTests = do
  describe "direct tests" chatDirectTests
  pgdelCopies 1
  describe "forward tests" chatForwardTests
  pgdelCopies 2
  describe "group tests" chatGroupTests
  pgdelCopies 3
  describe "chat relay tests" chatRelayTests
  pgdelCopies 4
  describe "local chats tests" chatLocalChatsTests
  pgdelCopies 5
  describe "file tests" chatFileTests
  pgdelCopies 6
  describe "profile tests" chatProfileTests
  pgdelCopies 7
  describe "chat list pagination tests" chatListTests
  pgdelCopies 8

pgdelCopies :: Int -> SpecWith TestParams
pgdelCopies n =
  describe ("pgdel " <> show n) $
    forM_ [1 :: Int, 2] $ \i -> it ("delete user copy " <> show i) testDeleteUser
