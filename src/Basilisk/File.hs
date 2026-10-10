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

import Control.Exception (IOException, bracketOnError, try)
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
import System.IO (Handle, IOMode (WriteMode), hClose, hFlush, withBinaryFile)
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
  present  <- doesFileExist fp
  mark     <- stampOf fp
  writable <- if present then writable' fp else canCreate fp
  buffer   <- if present then decoded <$> ByteString.readFile fp else pure (fresh "" platformEol)
  pure (onBuffer (\b -> b { bStamp = mark, bReadOnly = not writable }) buffer)
         { status = if writable then status buffer else Just "read-only" }
  where
    decoded    = either invalid valid . decodeUtf8'
    invalid _  = (fresh "" platformEol) { status = Just "not valid UTF-8" }
    fresh t el = onBuffer (\b -> b { bEol = el }) (newEditor (Just fp) t)
    -- The terminator is stripped and recorded rather than kept as a
    -- final empty row, so no file grows a line the user cannot see.
    -- At most one is removed, so the round trip is exact.
    valid raw = onBuffer (\b -> b { bFinalEol = ended, bBornEmpty = Text.null text })
                          (fresh (strip text) el)
      where
        el    = detectEol raw
        text  = decodeEol el raw
        ended = Text.singleton '\n' `Text.isSuffixOf` text
        strip = if ended then Text.dropEnd 1 else id

-- | A file's own convention wins; a file with no line endings at all
-- takes the platform's, which is what every other editor does for a
-- from-scratch file.
-- | A file's own convention wins. A lone carriage return with no line
-- feed anywhere is the old-Mac convention, which is otherwise read as
-- one enormous line full of replacement glyphs.
detectEol :: Text -> Eol
detectEol raw
  | "\r\n" `Text.isInfixOf` raw                              = CRLF
  | "\r" `Text.isInfixOf` raw && not ("\n" `Text.isInfixOf` raw) = CR
  | otherwise                                                = platformEol

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
isShared p = either (const False) ((> 1) . linkCount) <$> tryIO (getFileStatus p)

-- | The non-atomic path, used only where atomicity would destroy
-- something else. Truncating an existing inode keeps every name that
-- points at it.
inPlace :: FilePath -> ByteString.ByteString -> IO ()
inPlace p bytes = withBinaryFile p WriteMode (\h -> ByteString.hPut h bytes >> flushToDisk h)

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
    (\(tmp, h) -> hClose h >> removeFile tmp)
    (\(tmp, h) -> do
        ByteString.hPut h bytes
        flushToDisk h
        hClose h
        traverse_ (const (copyPermissions p tmp)) (guard' present)
        renameFile tmp p
        syncDir (takeDirectory p))
  where guard' b = if b then Just () else Nothing

-- | Force the bytes out of the kernel's cache before the rename.
-- Without this the rename is atomic against a crash of this process
-- but not against a loss of power, which can leave the new name
-- pointing at an empty file.
flushToDisk :: Handle -> IO ()
flushToDisk h = hFlush h >> (tryIO (handleToFd h >>= sync) >>= either (const (pure ())) pure)
  where sync fd = fileSynchronise fd

-- | And the rename itself, which lives in the directory's own data.
syncDir :: FilePath -> IO ()
syncDir d = either (const ()) id <$> tryIO (go) >>= pure
  where
    go = bracketOnError (openFd d ReadOnly defaultFileFlags) closeFd
           (\fd -> fileSynchronise fd >> closeFd fd)
