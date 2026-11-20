{-# LANGUAGE OverloadedStrings #-}

-- | File IO, with no editing logic. Every boundary -- a missing file, a
-- binary file, a full disk, a file someone else changed underneath the
-- editor -- is a status message on a usable buffer, never an exception
-- and never a truncated file.
module Basilisk.File
  ( openFile
  , writeDocument
  , stampOf
  ) where

import Control.Exception (IOException, bracket, bracketOnError, try)
import qualified Data.ByteString as ByteString
import Data.Foldable (traverse_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory
  ( doesFileExist
  , getFileSize
  , getModificationTime
  , copyPermissions
  , canonicalizePath
  , getPermissions
  , removeFile
  , renameFile
  , writable
  )
import System.FilePath (takeDirectory, takeFileName)
import System.Info (os)
import System.IO (Handle, IOMode (WriteMode), hClose, hFlush, openBinaryFile)
import System.Posix.Files (getFileStatus, linkCount)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, handleToFd, openFd)
import System.Posix.Unistd (fileSynchronise)
import System.IO.Temp (openBinaryTempFile)

import Basilisk.Types

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
    mark <- stampOf fp
    canWrite <- if present then writable' fp else canCreate fp
    contents <- if present then Just <$> ByteString.readFile fp else pure Nothing
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

-- | Modification time and size together. Either alone is too coarse:
-- filesystems round timestamps, and a same-size rewrite is common.
-- 'Nothing' means the file does not exist.
stampOf :: FilePath -> IO (Maybe Stamp)
stampOf p = do
  present <- doesFileExist p
  if not present
    then pure Nothing
    else do
      t <- getModificationTime p
      n <- getFileSize p
      pure (Just (truncate (toRational (utcTimeToPOSIXSeconds t) * 1000000000), n))

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
-- Returns the stamp the buffer should now carry, so the caller does not
-- have to re-stat and race with itself.
writeDocument :: FilePath -> Text -> Bool -> Maybe Stamp -> IO (Either Text (Maybe Stamp))
writeDocument given t force expected = either describe id <$> attempt
  where
    attempt :: IO (Either IOException (Either Text (Maybe Stamp)))
    attempt = try $ do
      -- Write through a symlink, not over it. 'renameFile' replaces
      -- whatever name it is given, so writing to a symlinked path
      -- would silently turn the link into a regular file and leave the
      -- real file untouched -- the edit lost, with a "written"
      -- message. Resolving first is the whole fix.
      p     <- resolve given
      found <- stampOf p
      if not force && diverged expected found
        then pure (Left "file changed on disk (:w! to override)")
        else do
          shared <- isShared p
          if shared then inPlace p (encodeUtf8 t) else atomically p (encodeUtf8 t)
          Right <$> stampOf p
    describe e = Left (Text.pack ("write failed: " <> show (ioKind e)))
    ioKind = takeWhile (/= '\n') . show

-- | The real file behind a path, or the path itself if it cannot be
-- resolved (which is the normal case for a file that does not exist
-- yet, and must not be an error).
resolve :: FilePath -> IO FilePath
resolve p = either (const p) id <$> tryIO (canonicalizePath p)

-- | Whether other names refer to this same inode. 'renameFile' would
-- break them, leaving the other names holding the old contents, so a
-- hardlinked file is written in place instead -- trading atomicity for
-- the link, which is the trade vim makes too.
isShared :: FilePath -> IO Bool
isShared p = (> 1) . linkCount <$> getFileStatus p

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
atomically :: FilePath -> ByteString.ByteString -> IO ()
atomically p bytes = do
  present <- doesFileExist p
  bracketOnError
    (openBinaryTempFile (takeDirectory p) (takeFileName p <> ".basilisk"))
    cleanupTemp
    (\(tmp, h) -> do
        ByteString.hPut h bytes
        flushToDisk h
        traverse_ (const (copyPermissions p tmp)) (guard' present)
        syncFile tmp
        renameFile tmp p
        syncDir (takeDirectory p))
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
