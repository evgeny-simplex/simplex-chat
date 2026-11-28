{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module MobileTests (mobileTests) where

import ChatClient
import ChatTests.DBUtils
import ChatTests.Utils
import Codec.Picture (PixelRGB8 (..), PixelRGBA8 (..), encodeGifImage, encodePng, generateImage)
import Codec.Picture.JPEGTurbo (encodeRGB)
import Control.Concurrent (forkIO)
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.STM
import Control.Monad (forM_)
import Control.Monad.Except
import Data.Aeson (FromJSON)
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as BS
import Data.ByteString.Internal (create)
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int32)
import Data.Time.Clock (getCurrentTime)
import Data.Word (Word8, Word32)
import Foreign.C
import Foreign.Marshal.Alloc (alloca, allocaBytes, mallocBytes)
import Foreign.Marshal.Array (peekArray)
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr
import Foreign.StablePtr
import Foreign.Storable (peek)
import GHC.IO.Encoding (setLocaleEncoding, setFileSystemEncoding, setForeignEncoding)
import qualified GHC.IO.FD as FD
import GHC.IO.Handle.FD (fdToHandle)
import ImageTests (jpegWithExif, littleEndianInt, pngShortImageData, pngSideAbove16384)
import JSONFixtures
import Simplex.Chat
import Simplex.Chat.Badges (BadgeInfo (..), BadgeRequest (..), BadgeType (..), generateMasterKey, verifyCredential)
import Simplex.Chat.Controller (ChatConfig (..), ChatController (..), ChatDatabase (..))
import Simplex.Chat.Image (ImageLimits (..), maxDecodeMemoryMB, receivedImageLimits)
import Simplex.Chat.Mobile hiding (error)
import Simplex.Chat.Mobile.Badges hiding (error)
import Simplex.Chat.Mobile.File
import Simplex.Chat.Mobile.Shared
import Simplex.Chat.Mobile.WebRTC
import Simplex.Chat.Options.DB
import Simplex.Chat.Store
import Simplex.Chat.Store.Profiles
import Simplex.Chat.Types (AgentUserId (..), Profile (..))
import Simplex.Messaging.Agent.Client (AgentClient (..))
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig (..), Env (..))
import Simplex.Messaging.Agent.Store.Shared (MigrationConfig (..), MigrationConfirmation (..))
import qualified Simplex.Messaging.Agent.Store.SQLite.DB as DB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile(..), CryptoFileArgs (..))
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, sumTypeJSON)
import System.Directory (copyFile)
import System.FilePath ((</>))
import System.IO (IOMode (..), hClose, hSetFileSize, utf8, withBinaryFile)
import System.IO.Error (tryIOError)
import System.Posix.Internals (c_open, fdStat, o_RDONLY, withFilePath)
import System.Process (createPipeFd)
import Test.Hspec hiding (it)

mobileTests :: HasCallStack => SpecWith TestParams
mobileTests = do
  describe "mobile API" $ do
    runIO $ do
      setLocaleEncoding utf8
      setFileSystemEncoding utf8
      setForeignEncoding utf8
    it "start new chat without user" testChatApiNoUser
    it "start new chat with existing user" testChatApi
    it "should set queue size via C API" testChatMigrateInitQueueCApi
    it "should encrypt/decrypt WebRTC frames" testMediaApi
    it "should encrypt/decrypt WebRTC frames via C API" testMediaCApi
    describe "should read/write encrypted files via C API" $ do
      it "latin1 name" $ testFileCApi "test"
      it "utf8 name 1" $ testFileCApi "тест"
      it "utf8 name 2" $ testFileCApi "👍"
      it "no exception on missing file" testMissingFileCApi
    describe "should encrypt/decrypt files via C API" $ do
      it "latin1 name" $ testFileEncryptionCApi "test"
      it "utf8 name 1" $ testFileEncryptionCApi "тест"
      it "utf8 name 2" $ testFileEncryptionCApi "👍"
      it "no exception on missing file" testMissingFileEncryptionCApi
    describe "validate name" $ do
      it "should convert invalid name to a valid name" testValidNameCApi
    describe "JSON length" $ do
      it "should compute length of JSON encoded string" testChatJsonLengthCApi
    describe "Parsers" $ do
      it "should parse server address" testChatParseServer
      it "should parse and sanitize URI" testChatParseUri
    describe "Badges" $ do
      it "should generate key and issue badge via C API, verify credential" testBadgeKeygenIssueCApi
    describe "Images" $ do
      it "should resize image to data URI via C API" testResizeImageUriCApi
      it "should resize image to data size via C API" testResizeImageCApi
      it "should choose image format by transparency via C API" testResizeImageAutoFormatCApi
      it "should resize JPEG with a side above 16384 via C API" testResizeLargeJpegCApi
      it "should resize image from a file path via C API" testResizeImageFileCApi
      it "should resize image from a file descriptor via C API" testResizeImageFdCApi
      it "should refuse malformed PNG via C API" testResizeMalformedPngCApi
    describe "Image API" $ do
      it "should open pictures within a size via C API" testImageOpenCApi
      it "should write chat_image_info in its C layout via C API" testImageInfoLayoutCApi
      it "should write frames in premultiplied RGBA and BGRA via C API" testImageFrameCApi
      it "should apply EXIF orientation via C API" testImageOrientationCApi
      it "should return the status of pictures that do not open via C API" testImageStatusCApi
      it "should open encrypted picture files via C API" testImageEncryptedFileCApi
      it "should apply the limits of pictures from others and of picked pictures via C API" testImageLimitsCApi
      it "should refuse invalid frame arguments via C API" testImageFrameArgumentsCApi
      it "should open pictures on several threads via C API" testImageThreadsCApi

noActiveUser :: LB.ByteString
noActiveUser =
#if defined(darwin_HOST_OS) && defined(swiftJSON)
  noActiveUserSwift
#else
  noActiveUserTagged
#endif

activeUserExists :: LB.ByteString
activeUserExists =
#if defined(darwin_HOST_OS) && defined(swiftJSON)
  activeUserExistsSwift
#else
  activeUserExistsTagged
#endif

activeUser :: LB.ByteString
activeUser =
#if defined(darwin_HOST_OS) && defined(swiftJSON)
  activeUserSwift
#else
  activeUserTagged
#endif

chatStarted :: LB.ByteString
chatStarted =
#if defined(darwin_HOST_OS) && defined(swiftJSON)
  chatStartedSwift
#else
  chatStartedTagged
#endif

connectionsDiff :: LB.ByteString
connectionsDiff =
#if defined(darwin_HOST_OS) && defined(swiftJSON)
  connectionsDiffSwift
#else
  connectionsDiffTagged
#endif

parsedMarkdown :: LB.ByteString
parsedMarkdown =
#if defined(darwin_HOST_OS) && defined(swiftJSON)
  parsedMarkdownSwift
#else
  parsedMarkdownTagged
#endif

testChatApiNoUser :: TestParams -> IO ()
testChatApiNoUser ps = do
  let tmp = tmpPath ps
      dbPrefix = tmp </> "1"
  Right cc <- chatMigrateInit dbPrefix "" "yesUp"
  Left (DBMErrorNotADatabase _) <- chatMigrateInit dbPrefix "myKey" "yesUp"
  chatSendCmd cc "/u" `shouldReturn` noActiveUser
  chatSendCmd cc "/_start" `shouldReturn` noActiveUser
  chatSendCmd cc "/create user alice Alice" `shouldReturn` activeUser
  chatSendCmd cc "/_start" `shouldReturn` chatStarted

testChatApi :: TestParams -> IO ()
testChatApi ps = do
  let tmp = tmpPath ps
      dbPrefix = tmp </> "1"
  Right ChatDatabase {chatStore, agentStore} <- createChatDatabase (ChatDbOpts dbPrefix "myKey" DB.TQOff True) (MigrationConfig MCYesUp Nothing)
  insertUser agentStore
  ts <- getCurrentTime
  Right _ <- withTransaction chatStore $ \db -> runExceptT $ createUserRecordAt db (AgentUserId 1) False False aliceProfile {preferences = Nothing} True ts
  Right cc <- chatMigrateInit dbPrefix "myKey" "yesUp"
  Left (DBMErrorNotADatabase _) <- chatMigrateInit dbPrefix "" "yesUp"
  Left (DBMErrorNotADatabase _) <- chatMigrateInit dbPrefix "anotherKey" "yesUp"
  chatSendCmd cc "/u" `shouldReturn` activeUser
  chatSendCmd cc "/create user alice Alice" `shouldReturn` activeUserExists
  chatSendCmd cc "/_start" `shouldReturn` chatStarted
  chatRecvMsg cc `shouldReturn` connectionsDiff
  chatRecvMsgWait cc 10000 `shouldReturn` ""
  chatParseMarkdown "hello" `shouldBe` "{}"
  chatParseMarkdown "*hello*" `shouldBe` parsedMarkdown

testChatMigrateInitQueueCApi :: TestParams -> IO ()
testChatMigrateInitQueueCApi ps = do
  cPath <- newCString $ tmpPath ps </> "1"
  cKey <- newCString ""
  cConfirm <- newCString "yesUp"
  alloca $ \ctrlPtr -> do
    let migrateInit queueSize = peekCAString =<< cChatMigrateInitQueue cPath cKey cConfirm queueSize ctrlPtr
    migrateInit 0 `shouldReturn` jsonStr DBMInvalidQueueSize
    migrateInit (-1) `shouldReturn` jsonStr DBMInvalidQueueSize
    migrateInit 65536 `shouldReturn` jsonStr DBMOk
    ChatController {config = ChatConfig {tbqSize}, smpAgent = AgentClient {agentEnv = Env {config = AgentConfig {tbqSize = agentQSize}}}} <- deRefStablePtr =<< peek ctrlPtr
    tbqSize `shouldBe` 65536
    agentQSize `shouldBe` 65536
  where
    jsonStr = LB.unpack . J.encode

testMediaApi :: HasCallStack => TestParams -> IO ()
testMediaApi ps = do
  let tmp = tmpPath ps
  Right c@ChatController {random = g} <- chatMigrateInit (tmp </> "1") "" "yesUp"
  cc <- newStablePtr c
  key <- atomically $ C.randomBytes 32 g
  frame <- atomically $ C.randomBytes 100 g
  let keyStr = strEncode key
      reserved = B.replicate (C.authTagSize + C.gcmIVSize) 0
      frame' = frame <> reserved
  Right encrypted <- runExceptT $ chatEncryptMedia cc keyStr frame'
  encrypted `shouldNotBe` frame'
  B.length encrypted `shouldBe` B.length frame'
  runExceptT (chatDecryptMedia keyStr encrypted) `shouldReturn` Right frame'

testMediaCApi :: HasCallStack => TestParams -> IO ()
testMediaCApi ps = do
  let tmp = tmpPath ps
  Right c@ChatController {random = g} <- chatMigrateInit (tmp </> "1") "" "yesUp"
  cc <- newStablePtr c
  key <- atomically $ C.randomBytes 32 g
  frame <- atomically $ C.randomBytes 100 g
  let keyStr = strEncode key
      reserved = B.replicate (C.authTagSize + C.gcmIVSize) 0
      frame' = frame <> reserved
  encrypted <- test (cChatEncryptMedia cc) keyStr frame'
  encrypted `shouldNotBe` frame'
  test cChatDecryptMedia keyStr encrypted `shouldReturn` frame'
  where
    test :: HasCallStack => (CString -> Ptr Word8 -> CInt -> IO CString) -> ByteString -> ByteString -> IO ByteString
    test f keyStr frame = do
      let len = B.length frame
          cLen = fromIntegral len
      ptr <- mallocBytes len
      putByteString ptr frame
      cKeyStr <- newCAString $ BS.unpack keyStr
      (f cKeyStr ptr cLen >>= peekCAString) `shouldReturn` ""
      getByteString ptr cLen

instance FromJSON WriteFileResult where
  parseJSON = $(JQ.mkParseJSON (sumTypeJSON $ dropPrefix "WF") ''WriteFileResult)

instance FromJSON ReadFileResult where
  parseJSON = $(JQ.mkParseJSON (sumTypeJSON $ dropPrefix "RF") ''ReadFileResult)

testFileCApi :: FilePath -> TestParams -> IO ()
testFileCApi fileName ps = do
  let tmp = tmpPath ps
  cc <- mkCCPtr tmp
  src <- B.readFile "./tests/fixtures/test.pdf"
  let path = tmp </> (fileName <> ".pdf")
  cPath <- newCString path
  let len = B.length src
      cLen = fromIntegral len
  ptr <- mallocBytes $ B.length src
  putByteString ptr src
  r <- peekCAString =<< cChatWriteFile cc cPath ptr cLen
  Just (WFResult cfArgs@(CFArgs key nonce)) <- jDecode r
  let encryptedFile = CryptoFile path $ Just cfArgs
  CF.getFileContentsSize encryptedFile `shouldReturn` fromIntegral (B.length src)
  cKey <- encodedCString key
  cNonce <- encodedCString nonce
  -- the returned pointer contains 0, buffer length as Word32, then buffer
  ptr' <- cChatReadFile cPath cKey cNonce
  peek ptr' `shouldReturn` (0 :: Word8)
  sz :: Word32 <- peek (ptr' `plusPtr` 1)
  let sz' = fromIntegral sz
  contents <- create sz' $ \toPtr -> copyBytes toPtr (ptr' `plusPtr` 5) sz'
  contents `shouldBe` src
  sz' `shouldBe` len

testMissingFileCApi :: TestParams -> IO ()
testMissingFileCApi ps = do
  let tmp = tmpPath ps
  let path = tmp </> "missing_file"
  cPath <- newCString path
  CFArgs key nonce <- atomically . CF.randomArgs =<< C.newRandom
  cKey <- encodedCString key
  cNonce <- encodedCString nonce
  ptr <- cChatReadFile cPath cKey cNonce
  peek ptr `shouldReturn` 1
  err <- peekCAString (ptr `plusPtr` 1)
  err `shouldContain` "missing_file: openBinaryFile: does not exist"

testFileEncryptionCApi :: FilePath -> TestParams -> IO ()
testFileEncryptionCApi fileName ps = do
  let tmp = tmpPath ps
  cc <- mkCCPtr tmp
  let fromPath = tmp </> (fileName <> ".source.pdf")
  copyFile "./tests/fixtures/test.pdf" fromPath
  src <- B.readFile fromPath
  cFromPath <- newCString fromPath
  let toPath = tmp </> (fileName <> ".encrypted.pdf")
  cToPath <- newCString toPath
  r <- peekCAString =<< cChatEncryptFile cc cFromPath cToPath
  Just (WFResult cfArgs@(CFArgs key nonce)) <- jDecode r
  CF.getFileContentsSize (CryptoFile toPath $ Just cfArgs) `shouldReturn` fromIntegral (B.length src)
  cKey <- encodedCString key
  cNonce <- encodedCString nonce
  let toPath' = tmp </> (fileName <> ".decrypted.pdf")
  cToPath' <- newCString toPath'
  "" <- peekCAString =<< cChatDecryptFile cToPath cKey cNonce cToPath'
  B.readFile toPath' `shouldReturn` src

testMissingFileEncryptionCApi :: TestParams -> IO ()
testMissingFileEncryptionCApi ps = do
  let tmp = tmpPath ps
  cc <- mkCCPtr tmp
  let fromPath = tmp </> "missing_file.source.pdf"
      toPath = tmp </> "missing_file.encrypted.pdf"
  cFromPath <- newCString fromPath
  cToPath <- newCString toPath
  r <- peekCAString =<< cChatEncryptFile cc cFromPath cToPath
  Just (WFError err) <- jDecode r
  err `shouldContain` fromPath
  CFArgs key nonce <- atomically . CF.randomArgs =<< C.newRandom
  cKey <- encodedCString key
  cNonce <- encodedCString nonce
  let toPath' = tmp </> "missing_file.decrypted.pdf"
  cToPath' <- newCString toPath'
  err' <- peekCAString =<< cChatDecryptFile cToPath cKey cNonce cToPath'
  err' `shouldContain` toPath

mkCCPtr :: FilePath -> IO (StablePtr ChatController)
mkCCPtr tmp = either (error . show) newStablePtr =<< chatMigrateInit (tmp </> "1") "" "yesUp"

testValidNameCApi :: TestParams -> IO ()
testValidNameCApi _ = do
  let goodName = "Джон Доу 👍"
  cName1 <- cChatValidName =<< newCString goodName
  peekCString cName1 `shouldReturn` goodName
  cName2 <- cChatValidName =<< newCString " @'Джон'  Доу   👍 "
  peekCString cName2 `shouldReturn` goodName

testChatJsonLengthCApi :: TestParams -> IO ()
testChatJsonLengthCApi _ = do
  cInt1 <- cChatJsonLength =<< newCString "Hello!"
  cInt1 `shouldBe` 6
  cInt2 <- cChatJsonLength =<< newCString "こんにちは！"
  cInt2 `shouldBe` 18

testChatParseServer :: TestParams -> IO ()
testChatParseServer _ = do
  pure ()

testChatParseUri :: TestParams -> IO ()
testChatParseUri _ = do
  pure ()

-- Generate a server keypair and issue a badge credential via the C FFI,
-- constructing the request from the typed records, then verify the issued
-- credential's BBS signature on the Haskell side.
testBadgeKeygenIssueCApi :: TestParams -> IO ()
testBadgeKeygenIssueCApi _ = do
  g <- C.newRandom
  IssuerKeyPair {publicKey, secretKey} <- ffiResult =<< (peekCString =<< cChatBadgeKeygen)
  mk <- generateMasterKey g
  badgeExpiry <- getCurrentTime
  let req = BadgeIssueReq {badgeKeyIdx = 1, secretKey, request = BadgeRequest {masterKey = mk, badgeInfo = BadgeInfo {badgeType = BTSupporter, badgeExpiry, badgeExtra = ""}}}
  cred <- ffiResult =<< (peekCString =<< cChatBadgeIssue =<< newCString (LB.unpack (J.encode req)))
  verifyCredential publicKey cred `shouldReturn` True

testResizeImageUriCApi :: TestParams -> IO ()
testResizeImageUriCApi _ = do
  (ptr, len) <- cBuffer =<< B.readFile "./tests/fixtures/test.jpg"
  uri <- peekCAString =<< cChatResizeImageUri ptr len 14000
  uri `shouldStartWith` "data:image/jpg;base64,"
  length uri `shouldSatisfy` (<= 14000)
  (webpPtr, webpLen) <- cBuffer =<< B.readFile "./tests/fixtures/webp/lossy.webp"
  webpUri <- peekCAString =<< cChatResizeImageUri webpPtr webpLen 14000
  webpUri `shouldStartWith` "data:image/jpg;base64,"
  length webpUri `shouldSatisfy` (<= 14000)
  (ptr', len') <- cBuffer "not an image"
  (peekCAString =<< cChatResizeImageUri ptr' len' 14000) `shouldReturn` ""

testResizeImageCApi :: TestParams -> IO ()
testResizeImageCApi _ = do
  (ptr, len) <- cBuffer =<< B.readFile "./tests/fixtures/test.jpg"
  let resizeToDataSize png = do
        Right bytes <- B64.decode . BS.pack <$> (peekCAString =<< cChatResizeImage ptr len 100000 png)
        B.length bytes `shouldSatisfy` (<= 100000)
        pure bytes
  B.take 2 <$> resizeToDataSize 0 `shouldReturn` "\xFF\xD8"
  B.take 8 <$> resizeToDataSize 1 `shouldReturn` "\x89PNG\r\n\x1a\n"

testResizeImageAutoFormatCApi :: TestParams -> IO ()
testResizeImageAutoFormatCApi _ = do
  B.take 2 <$> resizeWithAutoFormat "./tests/fixtures/test.jpg" `shouldReturn` "\xFF\xD8"
  B.take 8 <$> resizeWithAutoFormat "./tests/fixtures/logo-large-rgba.png" `shouldReturn` "\x89PNG\r\n\x1a\n"
  where
    resizeWithAutoFormat path = do
      (ptr, len) <- cBuffer =<< B.readFile path
      Right bytes <- B64.decode . BS.pack <$> (peekCAString =<< cChatResizeImage ptr len 100000 (-1))
      pure bytes

testResizeLargeJpegCApi :: TestParams -> IO ()
testResizeLargeJpegCApi _ = do
  (ptr, len) <- cBuffer =<< encodeRGB 90 Nothing (generateImage (\_ _ -> PixelRGB8 128 128 128) 20000 16)
  Right bytes <- B64.decode . BS.pack <$> (peekCAString =<< cChatResizeImage ptr len 261120 (-1))
  B.take 2 bytes `shouldBe` "\xFF\xD8"

testResizeImageFileCApi :: TestParams -> IO ()
testResizeImageFileCApi ps = do
  uri <- peekCAString =<< withCString "./tests/fixtures/test.jpg" (`cChatResizeImageFileUri` 14000)
  uri `shouldStartWith` "data:image/jpg;base64,"
  length uri `shouldSatisfy` (<= 14000)
  Right bytes <- B64.decode . BS.pack <$> (peekCAString =<< withCString "./tests/fixtures/logo-large-rgba.png" (\path -> cChatResizeImageFile path 100000 (-1)))
  B.take 8 bytes `shouldBe` "\x89PNG\r\n\x1a\n"
  Right webpBytes <- B64.decode . BS.pack <$> (peekCAString =<< withCString "./tests/fixtures/webp/lossless-alpha.webp" (\path -> cChatResizeImageFile path 100000 (-1)))
  B.take 8 webpBytes `shouldBe` "\x89PNG\r\n\x1a\n"
  animatedUri <- peekCAString =<< withCString "./tests/fixtures/webp/animated.webp" (`cChatResizeImageFileUri` 14000)
  animatedUri `shouldStartWith` "data:image/png;base64,"
  length animatedUri `shouldSatisfy` (<= 14000)
  writeFixture "api/images/resize-file-uri" $ J.object ["webp/animated.webp" J..= animatedUri]
  (peekCAString =<< withCString "./tests/fixtures/missing.jpg" (`cChatResizeImageFileUri` 14000)) `shouldReturn` ""
  oversized <- oversizedJpegFile ps
  (peekCAString =<< withCString oversized (`cChatResizeImageFileUri` 14000)) `shouldReturn` ""

testResizeImageFdCApi :: TestParams -> IO ()
testResizeImageFdCApi ps = do
  jpeg <- openFd "./tests/fixtures/test.jpg"
  jpegFile <- fdStat jpeg
  uri <- peekCAString =<< cChatResizeImageFdUri jpeg 14000
  uri `shouldStartWith` "data:image/jpg;base64,"
  length uri `shouldSatisfy` (<= 14000)
  isOpen jpeg jpegFile `shouldReturn` False
  piped <- pipeFd =<< B.readFile "./tests/fixtures/test.jpg"
  pipedFile <- fdStat piped
  pipedUri <- peekCAString =<< cChatResizeImageFdUri piped 14000
  pipedUri `shouldStartWith` "data:image/jpg;base64,"
  isOpen piped pipedFile `shouldReturn` False
  pdf <- openFd "./tests/fixtures/test.pdf"
  pdfFile <- fdStat pdf
  (peekCAString =<< cChatResizeImageFd pdf 100000 (-1)) `shouldReturn` ""
  isOpen pdf pdfFile `shouldReturn` False
  dir <- withFilePath "./tests/fixtures" $ \path -> c_open path o_RDONLY 0
  dirFile <- fdStat dir
  (peekCAString =<< cChatResizeImageFdUri dir 14000) `shouldReturn` ""
  isOpen dir dirFile `shouldReturn` False
  (peekCAString =<< cChatResizeImageFdUri 1000000 14000) `shouldReturn` ""
  (peekCAString =<< cChatResizeImageFdUri (-1) 14000) `shouldReturn` ""
  oversized <- openFd =<< oversizedJpegFile ps
  oversizedFile <- fdStat oversized
  (peekCAString =<< cChatResizeImageFdUri oversized 14000) `shouldReturn` ""
  isOpen oversized oversizedFile `shouldReturn` False
  where
    openFd path = FD.fdFD . fst <$> FD.openFile path ReadMode False
    isOpen fd file = either (const False) (== file) <$> tryIOError (fdStat fd)
    pipeFd s = do
      (r, w) <- createPipeFd
      h <- fdToHandle w
      _ <- forkIO $ B.hPut h s >> hClose h
      pure r

oversizedJpegFile :: TestParams -> IO FilePath
oversizedJpegFile ps = do
  let path = tmpPath ps </> "oversized.jpg"
  copyFile "./tests/fixtures/test.jpg" path
  withBinaryFile path ReadWriteMode (`hSetFileSize` (fromIntegral maxDecodeMemoryMB * 1048576 + 1))
  pure path

testResizeMalformedPngCApi :: TestParams -> IO ()
testResizeMalformedPngCApi _ = do
  refused pngShortImageData
  refused pngSideAbove16384
  where
    refused png = do
      (ptr, len) <- cBuffer png
      (peekCAString =<< cChatResizeImageUri ptr len 14000) `shouldReturn` ""
      (peekCAString =<< cChatResizeImage ptr len 261120 (-1)) `shouldReturn` ""

testImageOpenCApi :: TestParams -> IO ()
testImageOpenCApi _ =
  forM_ pictures $ \(file, (w, h), alpha) ->
    forM_ [openImageFile, openPickedFile] $ \open -> do
      (info, image) <- open ("./tests/fixtures/" <> file) 400 400
      info `shouldBe` OIOpened ImageInfo {frameWidth = w, frameHeight = h, frameCount = 1, loopCount = 0, hasAlpha = alpha}
      fst <$> readFrame image w h 0 `shouldReturn` 0
      fst <$> readFrame image w h 0 `shouldReturn` (-1)
      cChatImageRewind image
      fst <$> readFrame image w h 1 `shouldReturn` 0
      cChatImageClose image
  where
    pictures =
      [ ("test.jpg", (400, 225), False),
        ("logo-large-rgba.png", (400, 114), True),
        ("webp/lossy.webp", (128, 128), False),
        ("webp/animated.webp", (160, 128), True)
      ]

testImageInfoLayoutCApi :: TestParams -> IO ()
testImageInfoLayoutCApi _ = allocaBytes 24 $ \info -> do
  image <- withCString "./tests/fixtures/logo-large-rgba.png" $ \path -> cChatImageOpenFile path nullPtr nullPtr 400 400 (castPtr info)
  peekArray 6 info `shouldReturn` ([400, 114, 1, 0, 1, 0] :: [Int32])
  cChatImageClose image
  _ <- withCString "./tests/fixtures/test.pdf" $ \path -> cChatImageOpenFile path nullPtr nullPtr 400 400 (castPtr info)
  peekArray 6 info `shouldReturn` [0, 0, 0, 0, 0, 1]
  _ <- withCString "./tests/fixtures/missing.jpg" $ \path -> cChatImageOpenFile path nullPtr nullPtr 400 400 (castPtr info)
  peekArray 6 info `shouldReturn` [0, 0, 0, 0, 0, 2]

testImageFrameCApi :: TestParams -> IO ()
testImageFrameCApi _ = do
  (info, image) <- openDataUri ("data:image/png;base64," <> B64.encode (LB.toStrict $ encodePng $ generateImage pixel 2 2)) 2 2
  info `shouldBe` OIOpened ImageInfo {frameWidth = 2, frameHeight = 2, frameCount = 1, loopCount = 0, hasAlpha = True}
  paddedRows image 0 `shouldReturn` B.pack [100, 50, 25, 128, 10, 20, 30, 255, 238, 238, 238, 238, 0, 0, 0, 0, 255, 255, 255, 255, 238, 238, 238, 238]
  cChatImageRewind image
  paddedRows image 1 `shouldReturn` B.pack [25, 50, 100, 128, 30, 20, 10, 255, 238, 238, 238, 238, 0, 0, 0, 0, 255, 255, 255, 255, 238, 238, 238, 238]
  cChatImageClose image
  where
    pixel :: Int -> Int -> PixelRGBA8
    pixel x y = case (x, y) of
      (0, 0) -> PixelRGBA8 200 100 50 128
      (1, 0) -> PixelRGBA8 10 20 30 255
      (0, _) -> PixelRGBA8 0 0 0 0
      _ -> PixelRGBA8 255 255 255 255
    paddedRows image format = allocaBytes 24 $ \pixels -> do
      fillBytes pixels 238 24
      cChatImageNextFrame image pixels 12 format `shouldReturn` 0
      B.packCStringLen (castPtr pixels, 24)

testImageOrientationCApi :: TestParams -> IO ()
testImageOrientationCApi _ = do
  jpeg <- encodeRGB 100 Nothing $ generateImage quadrant 64 32
  forM_ [(1, (64, 32), [red, green, blue, white]), (6, (32, 64), [blue, red, white, green])] $ \(orientation, (w, h), colours) -> do
    (OIOpened ImageInfo {frameWidth, frameHeight}, image) <- openDataUri ("data:image/jpg;base64," <> B64.encode (jpegWithExif False 8 orientation jpeg)) 64 64
    (frameWidth, frameHeight) `shouldBe` (w, h)
    (0, frame) <- readFrame image w h 0
    [snap $ B.unpack $ B.take 3 $ B.drop ((y * w + x) * 4) frame | y <- [h `div` 4, 3 * h `div` 4], x <- [w `div` 4, 3 * w `div` 4]] `shouldBe` colours
    cChatImageClose image
  where
    quadrant x y = case (x < 32, y < 16) of
      (True, True) -> PixelRGB8 255 0 0
      (False, True) -> PixelRGB8 0 255 0
      (True, False) -> PixelRGB8 0 0 255
      (False, False) -> PixelRGB8 255 255 255
    red = [255, 0, 0]
    green = [0, 255, 0]
    blue = [0, 0, 255]
    white = [255, 255, 255]
    snap :: [Word8] -> [Word8]
    snap = map (\c -> if c > 127 then 255 else 0)

testImageStatusCApi :: TestParams -> IO ()
testImageStatusCApi ps = do
  let gif = LB.toStrict $ encodeGifImage $ generateImage (\_ _ -> 0) 16 16
      gifPath = tmpPath ps </> "test.gif"
  B.writeFile gifPath gif
  jpeg <- B.readFile "./tests/fixtures/test.jpg"
  forM_
    [ openImageFile gifPath 64 64,
      openPickedFile gifPath 64 64,
      openDataUri ("data:image/gif;base64," <> B64.encode gif) 64 64,
      openImageFile "./tests/fixtures/test.pdf" 64 64
    ]
    $ \open -> do
      (info, image) <- open
      info `shouldBe` OIUnsupported
      castStablePtrToPtr image `shouldBe` nullPtr
  forM_
    [ openImageFile "./tests/fixtures/missing.jpg" 64 64,
      openPickedFile "./tests/fixtures/missing.jpg" 64 64,
      openImageFile "./tests/fixtures/test.jpg" 0 64,
      openPickedFile "./tests/fixtures/test.jpg" 64 (-1),
      openDataUri ("data:image/png;base64," <> B64.encode pngShortImageData) 64 64,
      openDataUri ("data:image/jpg;base64," <> B.take 100 (B64.encode jpeg)) 64 64,
      openDataUri "data:image/jpg;base64,***" 64 64,
      openDataUri ("data:text/plain;base64," <> B64.encode jpeg) 64 64,
      openDataUri (B64.encode jpeg) 64 64
    ]
    $ \open -> do
      (info, image) <- open
      info `shouldBe` OIRefused
      castStablePtrToPtr image `shouldBe` nullPtr

testImageEncryptedFileCApi :: TestParams -> IO ()
testImageEncryptedFileCApi ps = do
  g <- C.newRandom
  args@(CFArgs key nonce) <- atomically $ CF.randomArgs g
  CFArgs otherKey _ <- atomically $ CF.randomArgs g
  let path = tmpPath ps </> "encrypted.jpg"
  Right () <- runExceptT . CF.writeFile (CryptoFile path $ Just args) . LB.fromStrict =<< B.readFile "./tests/fixtures/test.jpg"
  cKey <- encodedCString key
  cNonce <- encodedCString nonce
  cOtherKey <- encodedCString otherKey
  let open cKey' cNonce' = openedImage $ withCString path $ \cPath -> openImage $ cChatImageOpenFile cPath cKey' cNonce' 400 400
  open cKey cNonce `shouldReturn` OIOpened ImageInfo {frameWidth = 400, frameHeight = 225, frameCount = 1, loopCount = 0, hasAlpha = False}
  open cOtherKey cNonce `shouldReturn` OIRefused
  open cKey nullPtr `shouldReturn` OIRefused
  open nullPtr cNonce `shouldReturn` OIRefused

testImageLimitsCApi :: TestParams -> IO ()
testImageLimitsCApi ps = do
  webp <- B.readFile "./tests/fixtures/webp/lossless-alpha-9000x9000.webp"
  forM_ [(4320, opened64), (4321, OIRefused)] $ \(h, fromOthers) -> do
    let picture = webpWithSides 4320 h webp
        path = tmpPath ps </> ("4320x" <> show h <> ".webp")
    B.writeFile path picture
    openedImage (openImageFile path 64 64) `shouldReturn` fromOthers
    openedImage (openDataUri ("data:image/webp;base64," <> B64.encode picture) 64 64) `shouldReturn` fromOthers
    openedImage (openPickedFile path 64 64) `shouldReturn` opened64
  let large = tmpPath ps </> "large.jpg"
  copyFile "./tests/fixtures/test.jpg" large
  withBinaryFile large ReadWriteMode (`hSetFileSize` (fromIntegral (memoryLimitMB receivedImageLimits) * 1048576 + 1))
  openedImage (openImageFile large 400 400) `shouldReturn` OIRefused
  openedImage (openPickedFile large 400 400) `shouldReturn` OIOpened ImageInfo {frameWidth = 400, frameHeight = 225, frameCount = 1, loopCount = 0, hasAlpha = False}
  where
    opened64 = OIOpened ImageInfo {frameWidth = 64, frameHeight = 64, frameCount = 1, loopCount = 0, hasAlpha = True}

testImageFrameArgumentsCApi :: TestParams -> IO ()
testImageFrameArgumentsCApi _ = do
  (_, image) <- openImageFile "./tests/fixtures/webp/lossy.webp" 128 128
  allocaBytes (128 * 128 * 4) $ \pixels -> do
    cChatImageNextFrame image pixels 512 2 `shouldReturn` (-1)
    cChatImageNextFrame image pixels 511 0 `shouldReturn` (-1)
    cChatImageNextFrame image nullPtr 512 0 `shouldReturn` (-1)
    cChatImageNextFrame (castPtrToStablePtr nullPtr) pixels 512 0 `shouldReturn` (-1)
    cChatImageNextFrame image pixels 512 0 `shouldReturn` 0
  cChatImageRewind $ castPtrToStablePtr nullPtr
  cChatImageClose $ castPtrToStablePtr nullPtr
  cChatImageClose image

testImageThreadsCApi :: TestParams -> IO ()
testImageThreadsCApi _ = do
  let pictures = concat $ replicate 4 ["test.jpg", "logo-large-rgba.png", "webp/lossy.webp", "webp/lossless-alpha.webp"]
  frames <- mapM pictureFrame pictures
  forConcurrently pictures pictureFrame `shouldReturn` frames
  where
    pictureFrame file = do
      (OIOpened ImageInfo {frameWidth, frameHeight}, image) <- openImageFile ("./tests/fixtures/" <> file) 400 400
      (0, frame) <- readFrame image frameWidth frameHeight 0
      frame <$ cChatImageClose image

openImage :: (Ptr OpenedImage -> IO (StablePtr ChatImage)) -> IO (OpenedImage, StablePtr ChatImage)
openImage open = alloca $ \info -> do
  image <- open info
  opened <- peek info
  pure (opened, image)

openImageFile :: FilePath -> CInt -> CInt -> IO (OpenedImage, StablePtr ChatImage)
openImageFile path w h = withCString path $ \cPath -> openImage $ cChatImageOpenFile cPath nullPtr nullPtr w h

openPickedFile :: FilePath -> CInt -> CInt -> IO (OpenedImage, StablePtr ChatImage)
openPickedFile path w h = withCString path $ \cPath -> openImage $ cChatImageOpenPickedFile cPath w h

openDataUri :: ByteString -> CInt -> CInt -> IO (OpenedImage, StablePtr ChatImage)
openDataUri uri w h = B.useAsCString uri $ \cUri -> openImage $ cChatImageOpenDataUri cUri w h

openedImage :: IO (OpenedImage, StablePtr ChatImage) -> IO OpenedImage
openedImage open = do
  (info, image) <- open
  info <$ cChatImageClose image

readFrame :: StablePtr ChatImage -> Int -> Int -> CInt -> IO (CInt, ByteString)
readFrame image w h format = allocaBytes (w * h * 4) $ \pixels -> do
  duration <- cChatImageNextFrame image pixels (fromIntegral $ w * 4) format
  (,) duration <$> B.packCStringLen (castPtr pixels, w * h * 4)

webpWithSides :: Int -> Int -> ByteString -> ByteString
webpWithSides w h webp = B.take 21 webp <> littleEndianInt 4 (w - 1 + (h - 1) * 16384 + 2 ^ (28 :: Int)) <> B.drop 25 webp

cBuffer :: ByteString -> IO (Ptr Word8, CInt)
cBuffer s = do
  ptr <- mallocBytes $ B.length s
  putByteString ptr s
  pure (ptr, fromIntegral $ B.length s)

-- Decode an FFI `BadgeResult` envelope, returning the result or failing on error.
ffiResult :: FromJSON r => String -> IO r
ffiResult s = case J.eitherDecode (LB.pack s) of
  Right (BadgeResult r) -> pure r
  Right (BadgeError e) -> error $ "badge FFI error: " <> show e
  Left e -> error $ "badge FFI decode failed: " <> e <> " in " <> s

jDecode :: FromJSON a => String -> IO (Maybe a)
jDecode = pure . J.decode . LB.pack

encodedCString :: StrEncoding a => a -> IO CString
encodedCString = newCAString . BS.unpack . strEncode
