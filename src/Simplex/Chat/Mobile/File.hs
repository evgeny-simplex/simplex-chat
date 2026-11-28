{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Simplex.Chat.Mobile.File
  ( cChatWriteFile,
    cChatReadFile,
    cChatEncryptFile,
    cChatDecryptFile,
    cChatResizeImageUri,
    cChatResizeImage,
    cChatResizeImageFileUri,
    cChatResizeImageFile,
    cChatResizeImageFdUri,
    cChatResizeImageFd,
    cChatImageOpenFile,
    cChatImageOpenPickedFile,
    cChatImageOpenDataUri,
    cChatImageNextFrame,
    cChatImageRewind,
    cChatImageClose,
    ChatImage,
    ImageInfo (..),
    OpenedImage (..),
    WriteFileResult (..),
    ReadFileResult (..),
    chatWriteFile,
    chatReadFile,
  )
where

import Codec.Picture (DynamicImage, Image (..), PixelRGBA8 (..), pixelMap)
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import qualified Data.Aeson as J
import qualified Data.Aeson.TH as JQ
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64.Lazy as LB64
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Lazy.Char8 as LB'
import Data.Char (chr)
import Data.Either (fromLeft)
import Data.IORef (IORef, atomicModifyIORef', newIORef, writeIORef)
import Data.Int (Int32)
import qualified Data.Vector.Storable as VS
import Data.Word (Word32, Word8)
import Foreign.C
import Foreign.Marshal.Alloc (mallocBytes)
import Foreign.Marshal.Utils (copyBytes, maybePeek)
import Foreign.Ptr
import Foreign.StablePtr
import Foreign.Storable (Storable (..))
import GHC.IO.Handle.FD (fdToHandle)
import Simplex.Chat.Controller (ChatController (..))
import Simplex.Chat.Image (ColourProfile, DisplayImage (..), ImageFormat (..), ImageLimits (..), decodeDisplayImage, decodeResizable, imageFormat, maxDecodeMemoryMB, pickedImageLimits, receivedImageLimits, resizeImage, resizeImageDataUri)
import Simplex.Chat.Mobile.Shared
import Simplex.Chat.Util (chunkSize, encryptFile)
import Simplex.Messaging.Crypto.File (CryptoFile (..), CryptoFileArgs (..), CryptoFileHandle, FTCryptoError (..))
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (base64P, dropPrefix, parseAll, sumTypeJSON)
import Simplex.Messaging.Util (catchAll)
import System.Posix.Internals (c_close)
import UnliftIO (Handle, IOMode (..), atomically, bracket, hClose, hFileSize, onException, tryIO, withBinaryFile, withFile)

data WriteFileResult
  = WFResult {cryptoArgs :: CryptoFileArgs}
  | WFError {writeError :: String}

$(JQ.deriveToJSON (sumTypeJSON $ dropPrefix "WF") ''WriteFileResult)

cChatWriteFile :: StablePtr ChatController -> CString -> Ptr Word8 -> CInt -> IO CJSONString
cChatWriteFile cc cPath ptr len = do
  c <- deRefStablePtr cc
  path <- peekCString cPath
  s <- getByteString ptr len
  r <- chatWriteFile c path s
  newCStringFromLazyBS $ J.encode r

chatWriteFile :: ChatController -> FilePath -> ByteString -> IO WriteFileResult
chatWriteFile ChatController {random} path s = do
  cfArgs <- atomically $ CF.randomArgs random
  let file = CryptoFile path $ Just cfArgs
  either WFError (\_ -> WFResult cfArgs)
    <$> runCatchExceptT (withExceptT show $ CF.writeFile file $ LB.fromStrict s)

data ReadFileResult
  = RFResult {fileSize :: Int}
  | RFError {readError :: String}

cChatReadFile :: CString -> CString -> CString -> IO (Ptr Word8)
cChatReadFile cPath cKey cNonce = do
  path <- peekCString cPath
  key <- B.packCString cKey
  nonce <- B.packCString cNonce
  chatReadFile path key nonce >>= \case
    Left e -> castPtr <$> newCString (chr 1 : e)
    Right s -> do
      let len = fromIntegral $ LB.length s
      ptr <- mallocBytes $ len + 5
      poke ptr (0 :: Word8)
      pokeByteOff ptr 1 (fromIntegral len :: Word32)
      putLazyByteString (ptr `plusPtr` 5) s
      pure ptr

chatReadFile :: FilePath -> ByteString -> ByteString -> IO (Either String LB.ByteString)
chatReadFile path keyStr nonceStr = runCatchExceptT $ do
  key <- liftEither $ strDecode keyStr
  nonce <- liftEither $ strDecode nonceStr
  let file = CryptoFile path $ Just $ CFArgs key nonce
  withExceptT show $ CF.readFile file

cChatEncryptFile :: StablePtr ChatController -> CString -> CString -> IO CJSONString
cChatEncryptFile cc cFromPath cToPath = do
  c <- deRefStablePtr cc
  fromPath <- peekCString cFromPath
  toPath <- peekCString cToPath
  r <- chatEncryptFile c fromPath toPath
  newCAString . LB'.unpack $ J.encode r

chatEncryptFile :: ChatController -> FilePath -> FilePath -> IO WriteFileResult
chatEncryptFile ChatController {random} fromPath toPath =
  either WFError WFResult <$> runCatchExceptT encrypt
  where
    encrypt = do
      cfArgs <- atomically $ CF.randomArgs random
      encryptFile fromPath toPath cfArgs
      pure cfArgs

cChatDecryptFile :: CString -> CString -> CString -> CString -> IO CString
cChatDecryptFile cFromPath cKey cNonce cToPath = do
  fromPath <- peekCString cFromPath
  key <- B.packCString cKey
  nonce <- B.packCString cNonce
  toPath <- peekCString cToPath
  r <- chatDecryptFile fromPath key nonce toPath
  newCAString r

chatDecryptFile :: FilePath -> ByteString -> ByteString -> FilePath -> IO String
chatDecryptFile fromPath keyStr nonceStr toPath = fromLeft "" <$> runCatchExceptT decrypt
  where
    decrypt = do
      key <- liftEither $ strDecode keyStr
      nonce <- liftEither $ strDecode nonceStr
      let fromFile = CryptoFile fromPath $ Just $ CFArgs key nonce
      size <- liftIO $ CF.getFileContentsSize fromFile
      withExceptT show $
        CF.withFile fromFile ReadMode $ \r -> withFile toPath WriteMode $ \w -> do
          decryptChunks r w size
          CF.hGetTag r
    decryptChunks :: CryptoFileHandle -> Handle -> Integer -> ExceptT FTCryptoError IO ()
    decryptChunks r w !size = do
      let chSize = min size chunkSize
          chSize' = fromIntegral chSize
          size' = size - chSize
      ch <- liftIO $ CF.hGet r chSize'
      when (B.length ch /= chSize') $ throwError $ FTCEFileIOError "encrypting file: unexpected EOF"
      liftIO $ B.hPut w ch
      when (size' > 0) $ decryptChunks r w size'

cChatResizeImageUri :: Ptr Word8 -> CInt -> CInt -> IO CString
cChatResizeImageUri ptr len = cResizeImageUri $ getByteString ptr len

cChatResizeImage :: Ptr Word8 -> CInt -> CInt -> CInt -> IO CString
cChatResizeImage ptr len = cResizeImageData $ getByteString ptr len

cChatResizeImageFileUri :: CString -> CInt -> IO CString
cChatResizeImageFileUri = cResizeImageUri . readFilePath

cChatResizeImageFile :: CString -> CInt -> CInt -> IO CString
cChatResizeImageFile = cResizeImageData . readFilePath

cChatResizeImageFdUri :: CInt -> CInt -> IO CString
cChatResizeImageFdUri = cResizeImageUri . readFd

cChatResizeImageFd :: CInt -> CInt -> CInt -> IO CString
cChatResizeImageFd = cResizeImageData . readFd

readFilePath :: CString -> IO ByteString
readFilePath cPath = do
  path <- peekCString cPath
  withBinaryFile path ReadMode hGetImage

readFd :: CInt -> IO ByteString
readFd fd = bracket (fdToHandle fd `onException` c_close fd) hClose hGetImage

hGetImage :: Handle -> IO ByteString
hGetImage h =
  tryIO (hFileSize h) >>= \case
    Right size
      | size > fromIntegral maxSize -> tooLarge
      | otherwise -> B.hGet h $ fromIntegral size
    Left _ -> do
      s <- LB.hGet h $ maxSize + 1
      if LB.length s > fromIntegral maxSize then tooLarge else pure $ LB.toStrict s
  where
    maxSize = maxDecodeMemoryMB * 1048576
    tooLarge = fail "image file is too large"

cResizeImageUri :: IO ByteString -> CInt -> IO CString
cResizeImageUri input maxSize = cResizeImage id (resizeImageDataUri $ fromIntegral maxSize) input

cResizeImageData :: IO ByteString -> CInt -> CInt -> IO CString
cResizeImageData input maxSize png = cResizeImage LB64.encode resize input
  where
    resize img = resizeImage (format img) (fromIntegral maxSize) img
    format img = case compare png 0 of
      LT -> imageFormat img
      EQ -> IFJpeg
      GT -> IFPng

cResizeImage :: (LB.ByteString -> LB.ByteString) -> (DynamicImage -> ColourProfile -> IO (Either String LB.ByteString)) -> IO ByteString -> IO CString
cResizeImage encode resize input = do
  r <- runCatchExceptT $ ExceptT . uncurry resize =<< ExceptT (decodeResizable =<< input)
  newCStringFromLazyBS $ either (const "") encode r

data ChatImage = ChatImage
  { displayImage :: DisplayImage,
    frameWritten :: IORef Bool
  }

data ImageInfo = ImageInfo
  { frameWidth :: Int,
    frameHeight :: Int,
    frameCount :: Int,
    loopCount :: Int,
    hasAlpha :: Bool
  }
  deriving (Eq, Show)

data OpenedImage = OIOpened ImageInfo | OIUnsupported | OIRefused
  deriving (Eq, Show)

instance Storable OpenedImage where
  sizeOf _ = 24
  alignment _ = 4
  peek p =
    field 20 >>= \case
      0 -> fmap OIOpened $ ImageInfo <$> field 0 <*> field 4 <*> field 8 <*> field 12 <*> ((/= 0) <$> field 16)
      1 -> pure OIUnsupported
      _ -> pure OIRefused
    where
      field :: Int -> IO Int
      field offset = fromIntegral <$> (peekByteOff p offset :: IO Int32)
  poke p image = zipWithM_ (\offset v -> pokeByteOff p offset (fromIntegral v :: Int32)) [0, 4 ..] $ case image of
    OIOpened ImageInfo {frameWidth, frameHeight, frameCount, loopCount, hasAlpha} -> [frameWidth, frameHeight, frameCount, loopCount, fromEnum hasAlpha, 0]
    OIUnsupported -> [0, 0, 0, 0, 0, 1]
    OIRefused -> [0, 0, 0, 0, 0, 2]

cChatImageOpenFile :: CString -> CString -> CString -> CInt -> CInt -> Ptr OpenedImage -> IO (StablePtr ChatImage)
cChatImageOpenFile cPath cKey cNonce = cOpenImage receivedImageLimits $ do
  path <- liftIO $ peekCString cPath
  keys <- liftIO $ (,) <$> maybePeek B.packCString cKey <*> maybePeek B.packCString cNonce
  fileArgs <- liftEither $ case keys of
    (Nothing, Nothing) -> Right Nothing
    (Just key, Just nonce) -> Just <$> (CFArgs <$> strDecode key <*> strDecode nonce)
    _ -> Left "file key or nonce missing"
  readImageFile receivedImageLimits $ CryptoFile path fileArgs

cChatImageOpenPickedFile :: CString -> CInt -> CInt -> Ptr OpenedImage -> IO (StablePtr ChatImage)
cChatImageOpenPickedFile cPath = cOpenImage pickedImageLimits $ readImageFile pickedImageLimits . CF.plain =<< liftIO (peekCString cPath)

cChatImageOpenDataUri :: CString -> CInt -> CInt -> Ptr OpenedImage -> IO (StablePtr ChatImage)
cChatImageOpenDataUri cUri = cOpenImage receivedImageLimits $ liftEither . parseAll dataUriP =<< liftIO (B.packCString cUri)
  where
    dataUriP = "data:image/" *> A.takeTill (== ';') *> ";base64," *> base64P

readImageFile :: ImageLimits -> CryptoFile -> ExceptT String IO ByteString
readImageFile ImageLimits {memoryLimitMB} file = do
  size <- liftIO $ CF.getFileContentsSize file
  when (size > fromIntegral memoryLimitMB * 1048576) $ throwError "image file is too large"
  LB.toStrict <$> withExceptT show (CF.readFile file)

cOpenImage :: ImageLimits -> ExceptT String IO ByteString -> CInt -> CInt -> Ptr OpenedImage -> IO (StablePtr ChatImage)
cOpenImage limits input maxWidth maxHeight info =
  runCatchExceptT decode >>= \case
    Right image@DisplayImage {premultipliedFrame = Image {imageWidth, imageHeight}, hasTransparency} -> do
      poke info $ OIOpened ImageInfo {frameWidth = imageWidth, frameHeight = imageHeight, frameCount = 1, loopCount = 0, hasAlpha = hasTransparency}
      newStablePtr . ChatImage image =<< newIORef False
    Left e -> do
      poke info $ if e == "unsupported image format" then OIUnsupported else OIRefused
      pure $ castPtrToStablePtr nullPtr
  where
    decode = do
      when (maxWidth < 1 || maxHeight < 1) $ throwError "invalid image size"
      ExceptT . decodeDisplayImage limits (fromIntegral maxWidth, fromIntegral maxHeight) =<< input

cChatImageNextFrame :: StablePtr ChatImage -> Ptr Word8 -> CInt -> CInt -> IO CInt
cChatImageNextFrame image pixels rowBytes format
  | noImage image || pixels == nullPtr = pure (-1)
  | otherwise = do
      ChatImage {displayImage = DisplayImage {premultipliedFrame}, frameWritten} <- deRefStablePtr image
      case pixelFormat format of
        Just inFormat
          | fromIntegral rowBytes >= 4 * imageWidth premultipliedFrame ->
              atomicModifyIORef' frameWritten (True,) >>= \case
                True -> pure (-1)
                False -> 0 <$ pokeFrame pixels (fromIntegral rowBytes) (inFormat premultipliedFrame)
        _ -> pure (-1)

pixelFormat :: CInt -> Maybe (Image PixelRGBA8 -> Image PixelRGBA8)
pixelFormat = \case
  0 -> Just id
  1 -> Just $ pixelMap $ \(PixelRGBA8 r g b a) -> PixelRGBA8 b g r a
  _ -> Nothing

pokeFrame :: Ptr Word8 -> Int -> Image PixelRGBA8 -> IO ()
pokeFrame pixels rowBytes Image {imageWidth, imageHeight, imageData} =
  VS.unsafeWith imageData $ \frame -> forM_ [0 .. imageHeight - 1] $ \y ->
    copyBytes (pixels `plusPtr` (y * rowBytes)) (frame `plusPtr` (y * imageWidth * 4)) (imageWidth * 4)

cChatImageRewind :: StablePtr ChatImage -> IO ()
cChatImageRewind image = unless (noImage image) $ do
  ChatImage {frameWritten} <- deRefStablePtr image
  writeIORef frameWritten False

cChatImageClose :: StablePtr ChatImage -> IO ()
cChatImageClose image = unless (noImage image) $ freeStablePtr image

noImage :: StablePtr ChatImage -> Bool
noImage = (== nullPtr) . castStablePtrToPtr

runCatchExceptT :: ExceptT String IO a -> IO (Either String a)
runCatchExceptT action = runExceptT action `catchAll` (pure . Left . show)

$(JQ.deriveToJSON (sumTypeJSON $ dropPrefix "RF") ''ReadFileResult)
