{-# LANGUAGE OverloadedStrings #-}

-- | File IO, with no editing logic. Every boundary -- a missing file, a
-- binary file, a full disk, a file someone else changed underneath the
-- editor -- is a status message on a usable buffer, never an exception
-- and never a truncated file.
module Basilisk.File
  ( openFile
  , writeDocument
  , writeDocumentWith
  , stampOf
  , WriteResult (..)
  ) where

import Control.Exception (IOException, bracket, bracketOnError, try)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import Data.Foldable (traverse_)
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import qualified Crypto.Hash.SHA256 as SHA256
import System.Directory
  ( doesFileExist
  , createDirectoryIfMissing
  , copyPermissions
  , canonicalizePath
  , makeAbsolute
  , getAppUserDataDirectory
  , getPermissions
  , removeFile
  , renameFile
  , writable
  )
import System.FilePath (normalise, takeDirectory, takeFileName, (</>))
import System.Info (os)
import System.IO (Handle, IOMode (WriteMode), SeekMode (AbsoluteSeek), hClose, hFlush, openBinaryFile)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFileStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , setFileMode
  , statusChangeTimeHiRes
  )
import System.Posix.IO
  ( LockRequest (WriteLock)
  , OpenFileFlags (creat, nofollow)
  , OpenMode (ReadOnly, ReadWrite)
  , closeFd
  , defaultFileFlags
  , handleToFd
  , openFd
  , waitToSetLock
  )
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Posix.Types (FileOffset)
import System.IO.Temp (openBinaryTempFile)

import Basilisk.Types

-- | A completed replacement and any durability or stamp warning that
-- happened after the destination was already changed.
data WriteResult = WriteResult
  { writtenStamp :: !(Maybe Stamp)
  , writeWarning :: !(Maybe Text)
  }

-- | Reads bytes and decodes explicitly. @Data.Text.IO@ would translate
-- newlines per platform and throw on invalid UTF-8; the first silently
-- rewrites every line ending of a file merely opened and saved, and the
-- second turns a binary file into a crash before the terminal is even
-- set up.
--
-- A file that does not exist opens as an empty buffer with its path
-- already set, so @:w@ writes it rather than asking for the name again.
openFile :: FilePath -> IO Editor
openFile fp = do
  opened <- tryIO $ do
    present <- doesFileExist fp
    canWrite <- if present then writable' fp else canCreate fp
    contents <- if present then Just <$> ByteString.readFile fp else pure Nothing
    mark <- case contents of
      Nothing -> pure Nothing
      Just bytes -> Just <$> stampBytes fp bytes
    pure (mark, canWrite, contents)
  case opened of
    Left err -> pure ((fresh "" platformEol) { status = Just (Text.pack ("open failed: " <> show err)) })
    Right (mark, canWrite, contents) -> do
      let buffer = maybe (fresh "" platformEol) decoded contents
      pure (onBuffer (\b -> b { bStamp = mark, bReadOnly = not canWrite }) buffer)
             { status = if canWrite then status buffer else Just "read-only" }
  where
    decoded    = either invalid valid . decodeUtf8'
    invalid _ =
      onBuffer (\b -> b { bReadOnly = True }) (fresh "" platformEol)
        { status = Just "not valid UTF-8 (read-only)" }
    fresh t el = onBuffer (\b -> b { bEol = el }) (newEditor (Just fp) t)
    -- The terminator is stripped and recorded rather than kept as a
    -- final empty row, so no file grows a line the user cannot see.
    -- At most one is removed, so the round trip is exact.
    valid raw = onBuffer update (fresh text el)
      where
        (text, breaks, ended) = splitEols raw
        el = dominantEol breaks
        update b = b
          { bEol = el
          , bOriginalBreaks = breaks
          , bFinalEol = ended
          , bBornEmpty = Text.null raw
          }

-- | A file's own convention wins; a file with no line endings at all
-- takes the platform's, which is what every other editor does for a
-- from-scratch file.
-- | A file's own convention wins. A lone carriage return with no line
-- feed anywhere is the old-Mac convention, which is otherwise read as
-- one enormous line full of replacement glyphs.
splitEols :: Text -> (Text, [(Text, Eol)], Bool)
splitEols = finish . scan [] []
  where
    scan rows breaks input =
      let (line, separator) = Text.break (`elem` ['\r', '\n']) input
          row = line : rows
      in case Text.uncons separator of
        Nothing -> (row, breaks, False)
        Just ('\r', rest) -> case Text.uncons rest of
          Just ('\n', after) -> separated row (line, CRLF) breaks after
          _ -> separated row (line, CR) breaks rest
        Just ('\n', rest) -> separated row (line, LF) breaks rest
        Just (_, rest) -> separated row (line, LF) breaks rest
    separated rows' ending breaks input
      | Text.null input = (rows', ending : breaks, True)
      | otherwise = scan rows' (ending : breaks) input
    finish (rows, breaks, ended) =
      (Text.intercalate "\n" (reverse rows), reverse breaks, ended)

dominantEol :: [(Text, Eol)] -> Eol
dominantEol [] = platformEol
dominantEol breaks = fst (foldl' choose (firstEnding, firstCount) counts)
  where
    firstEnding = snd (headBreak breaks)
    firstCount = count firstEnding
    counts = [(ending, count ending) | ending <- [LF, CRLF, CR]]
    count ending = length (filter ((== ending) . snd) breaks)
    choose best@(_, n) candidate@(_, m) = if m > n then candidate else best
    headBreak ((line, ending) : _) = (line, ending)
    headBreak [] = (Text.empty, platformEol)

-- | Whether the file can be written, checked at open rather than at
-- the first @:w@ -- an hour of editing followed by "permission denied"
-- is the same data loss as no warning at all, arriving later.
writable' :: FilePath -> IO Bool
writable' p = either (const False) writable <$> tryIO (getPermissions p)

-- | For a file that does not exist yet, what matters is the directory.
canCreate :: FilePath -> IO Bool
canCreate p = either (const False) writable <$> tryIO (getPermissions (takeDirectory p))

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

-- | A file with no line endings at all takes the platform's, which is
-- what every other editor does for a from-scratch file.
platformEol :: Eol
platformEol = if os == "mingw32" then CRLF else LF

-- | A fingerprint of both file contents and identity. The metadata
-- detects replacement and cheaply describes a change; SHA-256 ensures a
-- same-size rewrite is detected even when timestamps collide. 'Nothing'
-- means the file does not exist.
stampOf :: FilePath -> IO (Maybe Stamp)
stampOf p = inspect (3 :: Int)
  where
    inspect attempts = do
      present <- doesFileExist p
      if not present
        then pure Nothing
        else do
          before <- getFileStatus p
          bytes <- ByteString.readFile p
          after <- getFileStatus p
          if stableMetadata before after && toInteger (fileSize after) == toInteger (ByteString.length bytes)
            then pure (Just (stampStatus after bytes))
            else if attempts > 1
              then inspect (attempts - 1)
              else ioError (userError "file kept changing while its save fingerprint was read")

stampBytes :: FilePath -> ByteString.ByteString -> IO Stamp
stampBytes p bytes = stampStatus <$> getFileStatus p <*> pure bytes

stampStatus :: FileStatus -> ByteString.ByteString -> Stamp
stampStatus status bytes = Stamp
  { stampDevice = toInteger (deviceID status)
  , stampFileId = toInteger (fileID status)
  , stampModified = nanos (modificationTimeHiRes status)
  , stampChanged = nanos (statusChangeTimeHiRes status)
  , stampSize = toInteger (fileSize status)
  , stampDigest = SHA256.hash bytes
  }
  where nanos = truncate . (* 1000000000) . toRational

stableMetadata :: FileStatus -> FileStatus -> Bool
stableMetadata a b =
  deviceID a == deviceID b
    && fileID a == fileID b
    && modificationTimeHiRes a == modificationTimeHiRes b
    && statusChangeTimeHiRes a == statusChangeTimeHiRes b
    && fileSize a == fileSize b

-- | The interpreter for the 'WriteFile' effect. The bytes arrive
-- already line-ending encoded from "Basilisk.Step", so nothing here
-- re-derives them; this function's job is to get them onto the disk
-- without ever being able to lose what was there before.
--
-- Two guards, in order:
--
--   * /Staleness./ If the file changed since it was read -- a rebase, a
--     formatter, another editor -- writing would silently discard
--     someone else's work. Refuse, and say so, unless forced.
--   * /Atomicity./ Write to a temporary file in the same directory,
--     then rename. @rename@ within a filesystem is atomic, so a crash,
--     a full disk or a kill leaves either the old file or the new one
--     and never a half-written one. The naive @writeFile@ truncates in
--     place, where the same interruption destroys the original.
--
-- Returns the observed stamp and any warning raised after replacement.
-- Once rename succeeds, a later directory-sync or stat failure cannot
-- truthfully be reported as though the file were left untouched.
writeDocument :: FilePath -> Text -> Bool -> Maybe Stamp -> IO (Either Text WriteResult)
writeDocument = writeDocumentWith syncDir (const (pure ()))

-- | Both hooks are injected for deterministic durability and race tests.
-- Production callers use 'writeDocument'.
writeDocumentWith :: (FilePath -> IO ()) -> (FilePath -> IO ()) -> FilePath -> Text -> Bool -> Maybe Stamp -> IO (Either Text WriteResult)
writeDocumentWith syncDirectory beforeCommit given t force expected = either describe id <$> attempt
  where
    attempt :: IO (Either IOException (Either Text WriteResult))
    attempt = try $ do
      -- Write through a symlink, not over it. 'renameFile' replaces
      -- whatever name it is given, so writing to a symlinked path
      -- would silently turn the link into a regular file and leave the
      -- real file untouched -- the edit lost, with a "written"
      -- message. Resolving first is the whole fix.
      p <- resolve given
      withSaveLock p [expected] $ do
        found <- stampOf p
        if not force && diverged expected found
          then pure (Left "file changed on disk (:w! to override)")
          else do
            shared <- isShared p
            committed <-
              if shared
                then do
                  beforeCommit p
                  stillCurrent <- current p
                  if not stillCurrent
                    then pure (Left "file changed on disk (:w! to override)")
                    else inPlace p (encodeUtf8 t) >> pure (Right Nothing)
                else atomically syncDirectory beforeCommit p (encodeUtf8 t) force expected
            case committed of
              Left why -> pure (Left why)
              Right durabilityWarning -> do
                observed <- tryIO (stampOf p)
                let (mark, stampWarning) = case observed of
                      Right value -> (value, Nothing)
                      Left err -> (Nothing, Just ("file was written but its new stamp could not be read: " <> Text.pack (show err)))
                pure . Right $ WriteResult mark (combineWarnings durabilityWarning stampWarning)
    describe e = Left (Text.pack ("write failed: " <> show (ioKind e)))
    ioKind = takeWhile (/= '\n') . show
    combineWarnings (Just first) (Just second) = Just (first <> "; " <> second)
    combineWarnings warning Nothing = warning
    combineWarnings Nothing warning = warning
    current p = do
      found <- stampOf p
      pure (force || not (diverged expected found))

-- | The real file behind a path, or the path itself if it cannot be
-- resolved (which is the normal case for a file that does not exist
-- yet, and must not be an error).
resolve :: FilePath -> IO FilePath
resolve p = do
  absolute <- normalise <$> makeAbsolute p
  resolved <- tryIO (canonicalizePath absolute)
  case resolved of
    Right target -> pure target
    Left _ -> do
      parent <- tryIO (canonicalizePath (takeDirectory absolute))
      pure $ case parent of
        Right directory -> normalise (directory </> takeFileName absolute)
        Left _ -> absolute

-- | Persistent advisory locks serialize Basilisk writers by path and
-- inode, so aliases to a hardlinked file share a lock too. The lock lives
-- in a private per-user directory rather than beside edited files, and
-- the OS releases it automatically if a process exits unexpectedly.
withSaveLock :: FilePath -> [Maybe Stamp] -> IO a -> IO a
withSaveLock target fingerprints action = do
  appData <- getAppUserDataDirectory "basilisk"
  let lockDir = appData </> "locks"
      lockPath = lockDir </> "writes.lock"
      ranges = sort . nub $ map lockOffset lockKeys
  createDirectoryIfMissing True lockDir
  owner <- getEffectiveUserID
  dirStatus <- getSymbolicLinkStatus lockDir
  if not (isDirectory dirStatus) || fileOwner dirStatus /= owner
    then ioError (userError "Basilisk save-lock directory is not a private directory owned by this user")
    else do
      setFileMode lockDir 0o700
      bracket
        (openFd lockPath ReadWrite (defaultFileFlags { creat = Just 0o600, nofollow = True }))
        closeFd
        (\fd -> do
          lockStatus <- getFileStatus lockPath
          if not (isRegularFile lockStatus) || fileOwner lockStatus /= owner || fileMode lockStatus .&. 0o077 /= 0
            then ioError (userError "Basilisk save-lock file has unsafe ownership or permissions")
            else do
              traverse_ (\offset -> waitToSetLock fd (WriteLock, AbsoluteSeek, offset, 1)) ranges
              action)
  where
    lockKeys = "path:" <> target : map identityKey (catMaybes fingerprints)
    identityKey stamp' = "inode:" <> show (stampDevice stamp') <> ":" <> show (stampFileId stamp')
    lockOffset :: String -> FileOffset
    lockOffset key = fromIntegral (foldl step 0 (take 7 (ByteString.unpack (SHA256.hash (encodeUtf8 (Text.pack key))))) :: Integer)
      where step value byte = value * 256 + toInteger byte

-- | Whether other names refer to this same inode. 'renameFile' would
-- break them, leaving the other names holding the old contents, so a
-- hardlinked file is written in place instead -- trading atomicity for
-- the link, which is the trade vim makes too.
isShared :: FilePath -> IO Bool
isShared p = do
  present <- doesFileExist p
  if present then (> 1) . linkCount <$> getFileStatus p else pure False

-- | The non-atomic path, used only where atomicity would destroy
-- something else. Truncating an existing inode keeps every name that
-- points at it.
inPlace :: FilePath -> ByteString.ByteString -> IO ()
inPlace p bytes = bracketOnError (openBinaryFile p WriteMode) closeQuietly $ \h -> do
  ByteString.hPut h bytes
  flushToDisk h
  where
    closeQuietly h = do
      _ <- tryIO (hClose h)
      pure ()

-- | Changed underneath us. A file that has since been deleted is not a
-- conflict -- writing recreates it, which is what the user asked for.
diverged :: Maybe Stamp -> Maybe Stamp -> Bool
diverged _        Nothing  = False
diverged Nothing  (Just _) = True
diverged (Just a) (Just b) = a /= b

-- | 'bracketOnError' releases only on failure, so a temporary file is
-- never left behind and the destination is never touched until the
-- bytes are safely on disk. The temporary file is created in the
-- destination's own directory, because @rename@ is only atomic within
-- a filesystem and @\/tmp@ is routinely a different one.
--
-- The mode is copied with 'copyPermissions' rather than
-- @getPermissions@\/@setPermissions@: that pair models only the
-- owner's bits, so a group-readable or group-writable file would come
-- back owner-only -- which a round trip through the editor must not
-- do, and which this project did until it was measured.
atomically :: (FilePath -> IO ()) -> (FilePath -> IO ()) -> FilePath -> ByteString.ByteString -> Bool -> Maybe Stamp -> IO (Either Text (Maybe Text))
atomically syncDirectory beforeCommit p bytes force expected = do
  present <- doesFileExist p
  bracket
    (openBinaryTempFile (takeDirectory p) (takeFileName p <> ".basilisk"))
    cleanupTemp
    (\(tmp, h) -> do
        ByteString.hPut h bytes
        flushToDisk h
        traverse_ (const (copyPermissions p tmp)) (guard' present)
        syncFile tmp
        beforeCommit p
        latest <- stampOf p
        if not force && diverged expected latest
          then pure (Left "file changed on disk (:w! to override)")
          else do
            renameFile tmp p
            synced <- tryIO (syncDirectory (takeDirectory p))
            let warning = case synced of
                  Right () -> Nothing
                  Left err -> Just ("file was written but directory sync failed: " <> Text.pack (show err))
            pure (Right warning))
  where guard' b = if b then Just () else Nothing

cleanupTemp :: (FilePath, Handle) -> IO ()
cleanupTemp (tmp, h) = do
  _ <- tryIO (hClose h)
  _ <- tryIO (removeFile tmp)
  pure ()

-- | Force the bytes out of the kernel's cache before the rename.
-- Without this the rename is atomic against a crash of this process
-- but not against a loss of power, which can leave the new name
-- pointing at an empty file.
flushToDisk :: Handle -> IO ()
flushToDisk h = do
  hFlush h
  bracket (handleToFd h) closeFd fileSynchronise

-- | Permission copying changes inode metadata after the write handle
-- has been synced, so sync the temporary inode once more before rename.
syncFile :: FilePath -> IO ()
syncFile p = bracket (openFd p ReadOnly defaultFileFlags) closeFd fileSynchronise

-- | And the rename itself, which lives in the directory's own data.
syncDir :: FilePath -> IO ()
syncDir d = go
  where
    go = bracket (openFd d ReadOnly defaultFileFlags) closeFd fileSynchronise
