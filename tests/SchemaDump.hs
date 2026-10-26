{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module SchemaDump where

import ChatTests.DBUtils
import Control.Concurrent (forkIO, forkOn, getNumCapabilities, threadDelay, threadWaitRead, yield)
import Control.Concurrent.Async (mapConcurrently_, withAsync)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM
import Control.DeepSeq
import qualified Control.Exception as E
import Control.Monad (forM, forM_, forever, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LB
import Network.HTTP.Client (HttpException, Response, defaultManagerSettings, httpLbs, newManager, parseRequest)
import Network.HTTP.Types (status200)
import Network.Wai (responseLBS)
import qualified Network.Wai.Handler.Warp as Warp
import Data.Char (isDigit)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (dropWhileEnd, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromJust, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Word (Word8)
import Database.SQLite.Simple (Only (..), Query (..))
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr)
import qualified GHC.IO.Device as IODevice
import qualified GHC.IO.FD as FD
import GHC.IO.Handle.FD (handleToFd)
import qualified Network.Socket as N
import Network.Socket.ByteString (recv)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.IO (IOMode (..), hClose, hDuplicate, hDuplicateTo, hFlush, hGetBuffering, hGetContents, hPutStrLn, hSetBuffering, stderr, stdout, withFile)
import System.Posix.Types (CSsize (..), Fd (..))
import System.Timeout (timeout)
import Simplex.Chat.Options.SQLite (chatDBFunctions)
import Simplex.Chat.Store (createChatStore)
import qualified Simplex.Chat.Store as Store
import Simplex.Messaging.Agent.Env.SQLite (createAgentStore)
import Simplex.Messaging.Agent.Store.Common (withConnection)
import Simplex.Messaging.Agent.Store.DB (TrackQueries (..))
import qualified Simplex.Messaging.Agent.Store.DB as DB
import Simplex.Messaging.Agent.Store.Interface
import qualified Simplex.Messaging.Agent.Store.SQLite.Migrations as Migrations
import Simplex.Messaging.Agent.Store.Shared (Migration (..), MigrationConfig (..), MigrationConfirmation (..), MigrationsToRun (..), toDownMigration)
import Simplex.Messaging.Util (ifM, tshow, unlessM, whenM)
import System.Directory (doesFileExist, doesPathExist, getSymbolicLinkTarget, listDirectory, removeFile)
import System.Process (CreateProcess (..), StdStream (..), createProcess, getPid, getProcessExitCode, proc, readCreateProcess, shell, terminateProcess, waitForProcess)
import Test.Hspec

foreign import ccall unsafe "pipe" h1Pipe :: Ptr CInt -> IO CInt

foreign import ccall unsafe "write" h1Write :: CInt -> Ptr Word8 -> CSize -> IO CSsize

foreign import ccall unsafe "read" h1Read :: CInt -> Ptr Word8 -> CSize -> IO CSsize

foreign import ccall unsafe "open" h1Open :: CString -> CInt -> IO CInt

foreign import ccall unsafe "dup2" h1Dup2 :: CInt -> CInt -> IO CInt

foreign import ccall unsafe "close" h1Close :: CInt -> IO CInt

foreign import ccall unsafe "getpid" h1GetPid :: IO CInt

testDB :: FilePath
testDB = "tests/tmp/test_chat.db"

testAgentDB :: FilePath
testAgentDB = "tests/tmp/test_agent.db"

appSchema :: FilePath
appSchema = "src/Simplex/Chat/Store/SQLite/Migrations/chat_schema.sql"

appLint :: FilePath
appLint = "src/Simplex/Chat/Store/SQLite/Migrations/chat_lint.sql"

appChatQueryPlans :: FilePath
appChatQueryPlans = "src/Simplex/Chat/Store/SQLite/Migrations/chat_query_plans.txt"

appAgentQueryPlans :: FilePath
appAgentQueryPlans = "src/Simplex/Chat/Store/SQLite/Migrations/agent_query_plans.txt"

testSchema :: FilePath
testSchema = "tests/tmp/test_agent_schema.sql"

schemaDumpTest :: Spec
schemaDumpTest = do
  it "verify and overwrite schema dump" testVerifySchemaDump
  it "verify .lint fkey-indexes" testVerifyLintFKeyIndexes
  it "verify schema down migrations" testSchemaMigrations
  it "verify strict tables" testVerifyStrict
  it "diag scenario" h1Scenario
  it "diag scenarios" h1Scenarios

testVerifySchemaDump :: IO ()
testVerifySchemaDump = do
  savedSchema <- ifM (doesFileExist appSchema) (readFile appSchema) (pure "")
  savedSchema `deepseq` pure ()
  void $ createChatStore (DBOpts testDB chatDBFunctions "" False True TQOff) (MigrationConfig MCError Nothing)
  getSchema testDB appSchema `shouldReturn` savedSchema
  removeFile testDB

testVerifyLintFKeyIndexes :: IO ()
testVerifyLintFKeyIndexes = do
  savedLint <- ifM (doesFileExist appLint) (readFile appLint) (pure "")
  savedLint `deepseq` pure ()
  void $ createChatStore (DBOpts testDB chatDBFunctions "" False True TQOff) (MigrationConfig MCError Nothing)
  getLintFKeyIndexes testDB "tests/tmp/chat_lint.sql" `shouldReturn` savedLint
  removeFile testDB

testSchemaMigrations :: IO ()
testSchemaMigrations = do
  stepRef <- newIORef "start"
  iterRef <- newIORef (0 :: Int)
  finished <- newEmptyMVar
  _ <- forkIO $ whenM (h1Watch stepRef iterRef finished 120) $ h1Dump stepRef >> (h1ProbeStripes 16384 >>= h1Log . ("stripes: " <>))
  ( do
      let noDownMigrations = dropWhileEnd (\Migration {down} -> isJust down) Store.migrations
      Right st <- createDBStore (DBOpts testDB chatDBFunctions "" False True TQOff) noDownMigrations (MigrationConfig MCError Nothing)
      mapM_ (testDownMigration stepRef st) $ drop (length noDownMigrations) Store.migrations
      closeDBStore st
      removeFile testDB
      whenM (doesFileExist testSchema) $ removeFile testSchema
    )
    `E.finally` putMVar finished ()
  where
    testDownMigration stepRef st m = do
      let mark op = writeIORef stepRef $ name m <> " " <> op
      putStrLn $ "down migration " <> name m
      let downMigr = fromJust $ toDownMigration m
      mark "getSchema 1"
      schema <- getSchema testDB testSchema
      mark "run up 1"
      Migrations.run st Nothing True $ MTRUp [m]
      mark "getSchema 2"
      schema' <- getSchema testDB testSchema
      unless (name m `elem` skipComparisonForUpMigrations) $
        schema' `shouldNotBe` schema
      mark "run down"
      Migrations.run st Nothing True $ MTRDown [downMigr]
      unless (name m `elem` skipComparisonForDownMigrations) $ do
        mark "getSchema 3"
        schema'' <- getSchema testDB testSchema
        schema'' `shouldBe` schema
      mark "run up 2"
      Migrations.run st Nothing True $ MTRUp [m]
      mark "getSchema 4"
      schema''' <- getSchema testDB testSchema
      schema''' `shouldBe` schema'
      mark "done"

testVerifyStrict :: IO ()
testVerifyStrict = do
  Right st <- createDBStore (DBOpts testDB chatDBFunctions "" False True TQOff) Store.migrations (MigrationConfig MCError Nothing)
  withConnection st (`DB.query_` "SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'sqlite_sequence' AND sql NOT LIKE '% STRICT'")
    `shouldReturn` ([] :: [Only Text])

skipComparisonForUpMigrations :: [String]
skipComparisonForUpMigrations =
  [ -- schema doesn't change
    "20250129_delete_unused_contacts"
  ]

skipComparisonForDownMigrations :: [String]
skipComparisonForDownMigrations =
  [ -- on down migration msg_delivery_events table moves down to the end of the file
    "20230504_recreate_msg_delivery_events_cleanup_messages",
    -- on down migration idx_chat_items_timed_delete_at index moves down to the end of the file
    "20230529_indexes",
    -- table and index definitions move down the file, so fields are re-created as not unique
    "20230914_member_probes",
    -- on down migration idx_connections_via_contact_uri_hash index moves down to the end of the file
    "20231019_indexes",
    -- table and indexes move down to the end of the file
    "20231215_recreate_msg_deliveries",
    -- on down migration idx_msg_deliveries_agent_ack_cmd_id index moves down to the end of the file
    "20240313_drop_agent_ack_cmd_id",
    -- sequence table moves down to the end of the file
    "20241023_chat_item_autoincrement_id",
    -- indexes move down to the end of the file
    "20241125_indexes",
    -- indexes move down to the end of the file
    "20250130_indexes",
    -- index moves down to the end of the file
    "20250227_member_acceptance",
    -- index moves down to the end of the file
    "20250721_indexes",
    -- indexes move down to the end of the file
    "20250922_remove_unused_connections",
    -- group_member_intros table moves down to the end of the file
    "20251128_migrate_member_relations",
    -- on down migration single_sender_group_member_id column and its index
    -- are re-added at the end of the table / file (ALTER TABLE ADD COLUMN
    -- appends; CREATE INDEX appends).
    "20260529_delivery_job_senders",
    -- group_domain is removed
    "20260603_simplex_name",
    "20261018_autoincrement_ids"
  ]

getSchema :: FilePath -> FilePath -> IO String
getSchema dbPath schemaPath = do
  void $ readCreateProcess (shell $ "sqlite3 " <> dbPath <> " '.schema --indent' > " <> schemaPath) ""
  sch <- readFile schemaPath
  sch `deepseq` pure sch

getLintFKeyIndexes :: FilePath -> FilePath -> IO String
getLintFKeyIndexes dbPath lintPath = do
  void $ readCreateProcess (shell $ "sqlite3 " <> dbPath <> " '.lint fkey-indexes' > " <> lintPath) ""
  lint <- readFile lintPath
  lint `deepseq` pure lint

saveQueryPlans :: SpecWith TestParams
saveQueryPlans = it "verify and overwrite query plans" $ \TestParams {chatQueryStats, agentQueryStats} -> do
  (chatSavedPlans, chatSavedPlans') <-
    updatePlans
      appChatQueryPlans
      chatQueryStats
      (createChatStore (DBOpts testDB chatDBFunctions "" False True TQOff) (MigrationConfig MCError Nothing))
      (\db -> do
        DB.execute_ db "CREATE TABLE IF NOT EXISTS temp_conn_ids (conn_id BLOB)"
        DB.execute_ db "CREATE TABLE IF NOT EXISTS temp_delete_members (contact_profile_id INTEGER, member_profile_id INTEGER, local_display_name TEXT)"
      )
  (agentSavedPlans, agentSavedPlans') <-
    updatePlans
      appAgentQueryPlans
      agentQueryStats
      (createAgentStore (DBOpts testAgentDB [] "" False True TQOff) (MigrationConfig MCError Nothing))
      (const $ pure ())
  chatSavedPlans' == chatSavedPlans `shouldBe` True
  agentSavedPlans' == agentSavedPlans `shouldBe` True
  removeFile testDB
  removeFile testAgentDB
  where
    updatePlans plansFile statsSel createStore prepareStore = do
      savedPlans <- ifM (doesFileExist plansFile) (T.readFile plansFile) (pure "")
      savedPlans `deepseq` pure ()
      queries <- sort . M.keys <$> readTVarIO statsSel
      Right st <- createStore
      plans' <- withConnection st $ \db -> do
        void $ prepareStore db
        mapM (getQueryPlan db) queries
      let savedPlans' = T.unlines plans'
      T.writeFile plansFile savedPlans'
      pure (savedPlans, savedPlans')
    getQueryPlan :: DB.Connection -> Query -> IO Text
    getQueryPlan db q =
      (("Query: " <> fromQuery q) <>) . result <$> E.try (DB.query_ db $ "explain query plan " <> q)
    result = \case
      Right r -> "\nPlan:\n" <> T.unlines (map planDetail r)
      Left (e :: E.SomeException) -> "\nError: " <> tshow e <> "\n"
    planDetail :: (Int, Int, Int, Text) -> Text
    planDetail (_, _, _, detail) = detail

h1Log :: String -> IO ()
h1Log s = putStrLn ("H1 " <> s) >> hFlush stdout

h1Scenarios :: IO ()
h1Scenarios =
  lookupEnv "H1_SCENARIO" >>= \case
    Just _ -> pure ()
    Nothing -> do
      exe <- getExecutablePath
      env0 <- getEnvironment
      forM_ ["warp"] $ \scenario -> do
        h1Log $ "=== scenario " <> scenario
        (_, _, _, ph) <- createProcess (proc exe ["-m", "/Schema dump/diag scenario/"]) {env = Just (("H1_SCENARIO", scenario) : env0)}
        r <- waitChild ph (300 :: Int)
        h1Log $ "=== scenario " <> scenario <> " exit: " <> show r
  where
    waitChild ph n
      | n <= 0 = do
          terminateProcess ph
          threadDelay 5000000
          getProcessExitCode ph >>= h1Log . ("killed child, exit: " <>) . show
          pure Nothing
      | otherwise =
          getProcessExitCode ph >>= \case
            Just c -> pure $ Just c
            Nothing -> threadDelay 1000000 >> waitChild ph (n - 1)

h1Scenario :: IO ()
h1Scenario = lookupEnv "H1_SCENARIO" >>= mapM_ h1RunScenario

h1RunScenario :: String -> IO ()
h1RunScenario scenario = do
  let db :: FilePath
      db = "tests/tmp/h1_chat.db"
      schemaPath :: FilePath
      schemaPath = "tests/tmp/h1_schema.sql"
  void $ createChatStore (DBOpts db chatDBFunctions "" False True TQOff) (MigrationConfig MCError Nothing)
  h1ProbeStripes 4096 >>= h1Log . ("stripes before: " <>)
  stopRef <- newIORef False
  statsRef <- newIORef (M.empty :: M.Map String Int)
  let count k = atomicModifyIORef' statsRef $ \m -> (M.insertWith (+) k 1 m, ())
  forM_ (h1Stressor scenario) $ \stress -> forkIO $ stress count stopRef
  stepRef <- newIORef "start"
  iterRef <- newIORef (0 :: Int)
  resultRef <- newIORef "running"
  finished <- newEmptyMVar
  _ <- forkIO $ do
    r <- E.try $ forM_ [1 .. 3000 :: Int] $ \i -> writeIORef iterRef i >> h1GetSchemaTraced stepRef db schemaPath
    writeIORef resultRef $ either (\(e :: E.SomeException) -> "exception: " <> show e) (const "ok") r
    putMVar finished ()
  hung <- h1Watch stepRef iterRef finished 30
  writeIORef stopRef True
  iters <- readIORef iterRef
  result <- readIORef resultRef
  stats <- readIORef statsRef
  h1Log $ "scenario " <> scenario <> ": " <> (if hung then "HUNG" else "finished: " <> result) <> " at getSchema call " <> show iters <> "; stressor outcomes: " <> show (M.toList stats)
  when hung $ h1Dump stepRef
  h1ProbeStripes 8192 >>= h1Log . ("stripes after: " <>)

h1Stressor :: String -> Maybe ((String -> IO ()) -> IORef Bool -> IO ())
h1Stressor = \case
  "sockets" -> Just h1SocketsStress
  "hDuplicateTo" -> Just h1HDuplicateToStress
  "dup2" -> Just h1Dup2Stress
  "warp" -> Just h1WarpStress
  _ -> Nothing

h1WarpStress :: (String -> IO ()) -> IORef Bool -> IO ()
h1WarpStress count stopRef = loop
  where
    loop = unlessM (readIORef stopRef) $ do
      r <- E.try $ do
        mgr <- newManager defaultManagerSettings
        Warp.withApplicationSettings Warp.defaultSettings (pure app) $ \port -> do
          req <- parseRequest $ "http://127.0.0.1:" <> show port <> "/"
          let client :: IO ()
              client = forever (E.try (httpLbs req mgr) :: IO (Either HttpException (Response LB.ByteString)))
          withAsync (mapConcurrently_ (const client) [1 .. 4 :: Int]) $ \_ -> threadDelay 2000
      either (\(e :: E.SomeException) -> count $ "warp error: " <> take 100 (show e)) (\_ -> count "warp ok") r
      loop
    app _ respond = respond $ responseLBS status200 [] "ok"

h1SocketsStress :: (String -> IO ()) -> IORef Bool -> IO ()
h1SocketsStress count stopRef = loop (1 :: Int)
  where
    loop i = unlessM (readIORef stopRef) $ do
      (a, b) <- N.socketPair N.AF_UNIX N.Stream N.defaultProtocol
      done <- newEmptyMVar
      _ <- forkIO $ (E.try (recv a 1) :: IO (Either E.SomeException ByteString)) >>= putMVar done
      when (even i) yield
      E.try (N.close a) >>= \case
        Left (e :: E.SomeException) -> count $ "close error: " <> take 100 (show e)
        Right () -> pure ()
      timeout 2000000 (takeMVar done) >>= \case
        Nothing -> count "recv never woke"
        Just (Left e) -> count $ "recv error: " <> take 100 (show e)
        Just (Right _) -> count "recv returned"
      N.close b
      loop (i + 1)

h1HDuplicateToStress :: (String -> IO ()) -> IORef Bool -> IO ()
h1HDuplicateToStress count stopRef = loop
  where
    loop = unlessM (readIORef stopRef) $ do
      r <- E.try $ withFile "tests/tmp/h1_stderr.log" WriteMode $ \h -> do
        buffering <- hGetBuffering stderr
        saved <- hDuplicate stderr
        (hDuplicateTo h stderr >> hPutStrLn stderr "captured") `E.finally` (hDuplicateTo saved stderr >> hClose saved >> hSetBuffering stderr buffering)
      either (\(e :: E.SomeException) -> count $ "capture error: " <> take 100 (show e)) (\_ -> count "capture ok") r
      loop

h1Dup2Stress :: (String -> IO ()) -> IORef Bool -> IO ()
h1Dup2Stress count stopRef = loop
  where
    loop = unlessM (readIORef stopRef) $ do
      r <- E.try $ withFile "tests/tmp/h1_stderr.log" WriteMode $ \h -> do
        fd <- handleToFd h
        hFlush stderr
        saved <- IODevice.dup FD.stderr
        (IODevice.dup2 fd FD.stderr >> hPutStrLn stderr "captured") `E.finally` (hFlush stderr >> IODevice.dup2 saved FD.stderr >> IODevice.close saved)
      either (\(e :: E.SomeException) -> count $ "capture error: " <> take 100 (show e)) (\_ -> count "capture ok") r
      loop

h1GetSchemaTraced :: IORef String -> FilePath -> FilePath -> IO ()
h1GetSchemaTraced stepRef dbPath schemaPath = do
  let mark = writeIORef stepRef
  mark "createProcess"
  (Just inh, Just outh, _, ph) <- createProcess (shell $ "sqlite3 " <> dbPath <> " '.schema --indent' > " <> schemaPath) {std_in = CreatePipe, std_out = CreatePipe}
  inFd <- FD.fdFD <$> handleToFd inh
  outFd <- FD.fdFD <$> handleToFd outh
  pid <- getPid ph
  let fds = " (stdin fd " <> show inFd <> ", stdout fd " <> show outFd <> ", pid " <> show pid <> ")"
  mark $ "hClose stdin" <> fds
  hClose inh
  mark $ "read stdout" <> fds
  out <- hGetContents outh
  _ <- E.evaluate (length out)
  mark $ "hClose stdout" <> fds
  hClose outh
  mark $ "waitForProcess" <> fds
  _ <- waitForProcess ph
  mark "readFile schema"
  sch <- readFile schemaPath
  _ <- E.evaluate (force sch)
  mark "done"

h1Watch :: IORef String -> IORef Int -> MVar () -> Int -> IO Bool
h1Watch stepRef iterRef finished limit = go "" (-1) 0
  where
    go lastStep lastIter idle =
      timeout 1000000 (readMVar finished) >>= \case
        Just () -> pure False
        Nothing -> do
          s <- readIORef stepRef
          i <- readIORef iterRef
          let idle' = if s == lastStep && i == lastIter then idle + 1 else 0 :: Int
          if idle' >= limit then pure True else go s i idle'

h1Dump :: IORef String -> IO ()
h1Dump stepRef = do
  readIORef stepRef >>= h1Log . ("blocked at: " <>)
  self <- fromIntegral <$> h1GetPid
  h1Fds self >>= h1Log . ("fds of self: " <>)
  kids <- h1ChildrenOf self
  forM_ kids $ \(kid, desc) -> do
    h1Log $ "child " <> desc
    h1Fds kid >>= h1Log . (("fds of " <> show kid <> ": ") <>)
    grandKids <- h1ChildrenOf kid
    forM_ grandKids $ \(grandKid, grandDesc) -> do
      h1Log $ "grandchild " <> grandDesc
      h1Fds grandKid >>= h1Log . (("fds of " <> show grandKid <> ": ") <>)

h1Fds :: Int -> IO String
h1Fds pid = do
  let dir = "/proc/" <> show pid <> "/fd"
  fds <- either (\(_ :: E.SomeException) -> []) id <$> E.try (listDirectory dir)
  links <- forM (sort $ map (read :: String -> Int) fds) $ \fd ->
    either (\(_ :: E.SomeException) -> show fd <> "->?") ((show fd <> "->") <>) <$> E.try (getSymbolicLinkTarget (dir <> "/" <> show fd))
  pure $ unwords links

h1ChildrenOf :: Int -> IO [(Int, String)]
h1ChildrenOf parent = do
  ps <- filter (all isDigit) <$> listDirectory "/proc"
  fmap catMaybes . forM ps $ \p -> do
    stat <- h1ReadRaw $ "/proc/" <> p <> "/stat"
    let afterComm = reverse $ takeWhile (/= ')') $ reverse stat
        comm = takeWhile (/= ')') $ drop 1 $ dropWhile (/= '(') stat
    case words afterComm of
      procState : ppid : _ | ppid == show parent -> do
        wchan <- h1ReadRaw $ "/proc/" <> p <> "/wchan"
        pure $ Just (read p, p <> " " <> comm <> " state " <> procState <> " wchan " <> wchan)
      _ -> pure Nothing

h1ReadRaw :: FilePath -> IO String
h1ReadRaw path = withCString path $ \cpath -> do
  fd <- h1Open cpath 0
  if fd < 0
    then pure ""
    else allocaBytes 65536 $ \buf -> do
      n <- h1Read fd buf 65536
      _ <- h1Close fd
      map (toEnum . fromIntegral) <$> peekArray (max 0 (fromIntegral n)) buf

h1ProbeStripes :: Int -> IO String
h1ProbeStripes base = do
  caps <- getNumCapabilities
  rows <- forM [0 .. 31] $ \stripe -> do
    marks <- forM [0 .. caps - 1] $ \cap -> h1ProbeStripe (base + 32 * cap + stripe) cap
    pure $ show stripe <> ":" <> marks
  pure $ unwords rows

h1ProbeStripe :: Int -> Int -> IO Char
h1ProbeStripe target cap =
  ifM (doesPathExist $ "/proc/self/fd/" <> show target) (pure '?') $
    allocaArray 2 $ \pipeFds -> do
      _ <- h1Pipe pipeFds
      [r, w] <- peekArray 2 pipeFds
      _ <- with (1 :: Word8) $ \p -> h1Write w p 1
      d <- h1Dup2 r (fromIntegral target)
      _ <- h1Close r
      _ <- h1Close w
      if d < 0
        then pure '!'
        else do
          done <- newEmptyMVar
          _ <- forkOn cap $ threadWaitRead (Fd $ fromIntegral target) >> putMVar done ()
          timeout 3000000 (takeMVar done) >>= \case
            Just () -> h1Close (fromIntegral target) >> pure '.'
            Nothing -> pure 'X'
