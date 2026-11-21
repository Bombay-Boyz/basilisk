{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The only module that performs IO. It reads an event, asks
-- 'Basilisk.Decode' what it means, asks 'Basilisk.Step' what happens,
-- performs whatever effects come back, and repeats.
--
-- The frame is drawn at the /top/ of the iteration, before the blocking
-- read. That one ordering is what makes the first frame appear before
-- the first keystroke, and what makes a terminal resize repaint: the
-- size is re-read every iteration, so a resize needs no event handling,
-- no 'Resize' action and no special case anywhere.
module Basilisk.Loop (run, perform, performWith) where

import Control.Exception (AsyncException, SomeException, bracket, displayException, evaluate, fromException, tryJust)
import Control.Monad (foldM)
import Control.DeepSeq (force)
import Data.List (mapAccumL)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Yaml as Yaml
import qualified Graphics.Vty as Vty
import Graphics.Vty.Platform.Unix (mkVty)
import Ormolu
  ( CabalSearchResult (..)
  , Config (..)
  , RegionIndices
  , defaultConfig
  , detectSourceType
  , ormolu
  , getCabalInfoForSourceFile
  , refineConfig
  )
import Ormolu.Config
  ( FourmoluConfig (..)
  , findConfigFile
  , resolvePrinterOpts
  )
import System.FilePath (takeDirectory, takeExtension)

import Basilisk.Cursor (desiredColumn, unicode)
import Basilisk.Decode (KeyState, decode, initialKeyState)
import qualified Basilisk.Document as Doc
import qualified Basilisk.File as File
import Basilisk.Render (render, scroll)
import Basilisk.Step (step)
import Basilisk.Types

-- | 'bracket' guarantees the terminal returns to cooked mode whether the
-- loop returns, throws, or the process is asked to exit, so nothing
-- inside the loop needs exception handling of its own.
run :: Maybe FilePath -> IO ()
run mfp = do
  e0 <- maybe (pure (newEditor Nothing "")) File.openFile mfp
  bracket (mkVty Vty.defaultConfig) Vty.shutdown (\vty -> loop vty initialKeyState e0)

-- | Tail recursive and strict in both pieces of carried state; with
-- 'StrictData' on every field of 'Editor' this leaves no thunk chain
-- across keystrokes and the stack is @O(1)@ for the life of the session.
loop :: Vty.Vty -> KeyState -> Editor -> IO ()
loop vty !ks !e = do
  wh <- Vty.displayBounds (Vty.outputIface vty)
  let shown = scroll wh e
  Vty.update vty (render wh shown)
  ev <- Vty.nextEvent vty
  case decode (mode shown) ks ev of
    (ks', Nothing)  -> loop vty ks' shown
    (ks', Just act) -> do
      let (!next, effects) = step act shown
      (done, quitRequested) <- foldM perform (next, False) effects
      if quitRequested
        then Vty.update vty (render wh (scroll wh done))
        else loop vty ks' done

-- | The one place an 'Effect' becomes IO. Explicit quit effects are
-- honored by the loop; write effects request quit only after success.
-- A successful write is the only place the buffer becomes clean, and it
-- records the stamp the writer observed rather than re-stat'ing and
-- racing with itself. The quit bit is honored only after that success.
perform :: (Editor, Bool) -> Effect -> IO (Editor, Bool)
perform = performWith File.writeDocument

performWith :: (FilePath -> Text -> Bool -> Maybe Stamp -> IO (Either Text File.WriteResult)) -> (Editor, Bool) -> Effect -> IO (Editor, Bool)
performWith writer (e, quitRequested) (WriteFile p t forceWrite quitOnSuccess) = do
  formatted <- formatForSave p t e
  case formatted of
    Left why -> pure (e { status = Just ("format failed: " <> why) }, quitRequested)
    Right (prepared, output) -> do
      result <- writer p output forceWrite (stamp e)
      pure $ case result of
        Left why -> (e { status = Just why }, quitRequested)
        Right outcome ->
          ( (onBuffer (\b -> b { bSaved = bVersion b, bStamp = File.writtenStamp outcome }) prepared)
              { status = Just (maybe "written" ("written; " <>) (File.writeWarning outcome))
              }
          , quitRequested || quitOnSuccess
          )
performWith _ (e, _) RequestQuit = pure (e, True)

formatForSave :: FilePath -> Text -> Editor -> IO (Either Text (Editor, Text))
formatForSave p original e
  | takeExtension p `elem` [".hs", ".lhs"] = do
      result <- formatHaskell p (Doc.toText (document e))
      pure (formatResult result)
  | otherwise = pure (Right (e, original))
 where
  formatResult (Left why) = Left why
  formatResult (Right output) =
    let prepared = applyFormatted (Text.dropWhileEnd (== '\n') output) e
     in Right (prepared, serialise prepared)

applyFormatted :: Text -> Editor -> Editor
applyFormatted formatted e
  | formatted == Doc.toText (document e) = e
  | otherwise = onBuffer update e
 where
  old = document e
  new = Doc.fromText formatted
  row = Doc.cursorRow old
  repositioned = Doc.move unicode (desiredColumn (cursor e)) (Doc.Lines row) new
  update b =
    b
      { bDocument = repositioned
      , bHistory = History (take undoLimit (old : past (history e))) []
      , bVersion = version e + 1
      , bBornEmpty = False
      }

formatHaskell :: FilePath -> Text -> IO (Either Text Text)
formatHaskell sourcePath source = do
  result <-
    ( tryJust synchronous $ do
        config <- configFor sourcePath
        -- Fourmolu's in-process API passes plain module text to GHC's parser
        -- without the literate preprocessor, so .lhs prose is shielded with
        -- unique marker comments and restored after formatting the code.
        output <- case takeExtension sourcePath of
          ".lhs" -> case literateSource source of
            Left problem -> ioError (userError (Text.unpack problem))
            Right Nothing -> pure source
            Right (Just (plain, markers, bird)) ->
              rebuildLiterate markers bird <$> ormolu config "<literate>.hs" plain
          _ -> ormolu config sourcePath source
        evaluate (force output)
    ) ::
      IO (Either SomeException Text)
  pure (either (Left . friendlyError . Text.pack . displayException) Right result)
 where
  friendlyError = Text.replace "<literate>.hs" (Text.pack sourcePath)
  synchronous exception = case fromException exception :: Maybe AsyncException of
    Just _ -> Nothing
    Nothing -> Just exception

configFor :: FilePath -> IO (Config RegionIndices)
configFor sourcePath = do
  cabalResult <- getCabalInfoForSourceFile sourcePath
  fourmoluConfig <- loadFourmoluConfig sourcePath
  let cabalInfo = case cabalResult of
        CabalNotFound -> Nothing
        CabalDidNotMention info -> Just info
        CabalFound info -> Just info
      baseConfig = (defaultConfig :: Config RegionIndices) { cfgCheckIdempotence = True }
      fixities = cfgFileFixities <$> fourmoluConfig
      reexports = cfgFileReexports <$> fourmoluConfig
      printerOptions = maybe [] (pure . cfgFilePrinterOpts) fourmoluConfig
      refined = refineConfig (detectSourceType sourcePath) cabalInfo fixities reexports baseConfig
  pure refined { cfgPrinterOpts = resolvePrinterOpts printerOptions }

-- Fourmolu owns both the search order (nearest project ancestor, then XDG)
-- and the YAML schema. Keep its parse errors on the existing safe-save path:
-- formatting fails before the file writer can replace anything.
loadFourmoluConfig :: FilePath -> IO (Maybe FourmoluConfig)
loadFourmoluConfig sourcePath =
  findConfigFile (takeDirectory sourcePath) >>= \case
    Left _ -> pure Nothing
    Right configPath -> Yaml.decodeFileEither configPath >>= \case
      Left problem -> ioError (userError
        ("failed to load " <> configPath <> ":\n" <> Yaml.prettyPrintParseException problem))
      Right config -> pure (Just config)

literateSource :: Text -> Either Text (Maybe (Text, Map.Map Text Text, Bool))
literateSource source
  | latex = do
      validateLatex rows
      pure (Just (Text.intercalate "\n" plainRows, replacements, False))
  | bird = Right (Just (Text.intercalate "\n" plainRows, replacements, True))
  | otherwise = Right Nothing
 where
  rows = Text.lines source
  latex = any isLatexMarker rows
  bird = any (">" `Text.isPrefixOf`) rows
  prefix = markerPrefix source (0 :: Int)
  (plainRows, replacements) =
    let (_, tagged) = mapAccumL classify (False, 0 :: Int) rows
     in (map fst tagged, Map.fromList (concatMap snd tagged))
  classify (inside, index) line
    | latex && isBeginCode line =
        ((True, index + 1), marked index line)
    | latex && isEndCode line =
        ((False, index + 1), marked index line)
    | latex && inside = ((inside, index), (line, []))
    | latex = ((inside, index + 1), marked index line)
    | ">" `Text.isPrefixOf` line = ((inside, index), (stripBird line, []))
    | otherwise = ((inside, index + 1), marked index line)
  marked index line =
    let token = prefix <> Text.justifyRight 8 '0' (Text.pack (show index))
     in (token, [(token, line)])
  stripBird line = case Text.stripPrefix ">" line of
    Nothing -> line
    Just rest -> maybe rest id (Text.stripPrefix " " rest)
  markerPrefix input index =
    let candidate = "-- BASILISK_INTERNAL_LITERATE_" <> Text.pack (show index) <> "_"
     in if candidate `Text.isInfixOf` input then markerPrefix input (index + 1) else candidate
  isBeginCode line = Text.stripStart line == line && Text.strip line == "\\begin{code}"
  isEndCode line = Text.stripStart line == line && Text.strip line == "\\end{code}"
  isLatexMarker line =
    "\\begin{code}" `Text.isPrefixOf` Text.stripStart line
      || "\\end{code}" `Text.isPrefixOf` Text.stripStart line

validateLatex :: [Text] -> Either Text ()
validateLatex = go (1 :: Int) False
 where
  go line inside rows = case rows of
    []
      | inside -> Left "unterminated \\begin{code} block at end of literate Haskell file"
      | otherwise -> Right ()
    current : rest
      | isMarkerLike current && not (isMarker current) ->
          Left ("LaTeX code marker must occupy its own unindented line (line " <> tshow line <> ")")
      | isBeginCode current && inside ->
          Left ("nested \\begin{code} block at line " <> tshow line)
      | isBeginCode current -> go (line + 1) True rest
      | isEndCode current && not inside ->
          Left ("\\end{code} without matching \\begin{code} at line " <> tshow line)
      | isEndCode current -> go (line + 1) False rest
      | otherwise -> go (line + 1) inside rest
  isBeginCode line = Text.stripStart line == line && Text.strip line == "\\begin{code}"
  isEndCode line = Text.stripStart line == line && Text.strip line == "\\end{code}"
  isMarkerLike line =
    "\\begin{code}" `Text.isPrefixOf` Text.stripStart line
      || "\\end{code}" `Text.isPrefixOf` Text.stripStart line
  isMarker line = isBeginCode line || isEndCode line
  tshow = Text.pack . show

rebuildLiterate :: Map.Map Text Text -> Bool -> Text -> Text
rebuildLiterate markers bird = Text.intercalate "\n" . snd . mapAccumL restore False . Text.lines
 where
  restore inside line = case Map.lookup (Text.strip line) markers of
    Just original
      | "\\begin{code}" `Text.isPrefixOf` original -> (True, original)
      | "\\end{code}" `Text.isPrefixOf` original -> (False, original)
      | otherwise -> (inside, original)
    Nothing -> (inside, if bird then (if Text.null line then ">" else "> " <> line) else line)
