{-# LANGUAGE OverloadedStrings #-}

-- | Small, conservative live indentation rules for Haskell source.
-- Whole-file formatting remains the save path's responsibility.
module Basilisk.Indent
  ( enterText
  , backspaceIndent
  ) where

import qualified Data.Text as Text
import Data.Text (Text)

import Basilisk.Cursor (displayColumn, unicode)
import qualified Basilisk.Document as Doc

-- | Text inserted for an Enter key. Literate Bird lines keep their marker;
-- all indentation is spaces so the policy is stable across environments.
enterText :: Bool -> Text -> Text -> Text
enterText literate line before =
  if emptyPair
    then "\n" <> marked (childIndent <> "\n") <> marked baseIndent
    else "\n" <> marked (baseIndent <> if opensLayout codeBefore then "  " else "")
  where
    bird = literate && ">" `Text.isPrefixOf` line
    marker = if bird then "> " else ""
    marked = (marker <>)
    codeLine = if bird then stripBird line else line
    codeBefore = if bird then stripBird before else before
    rawAfter = Text.drop (Text.length before) line
    codeAfter = if bird && ">" `Text.isPrefixOf` rawAfter then stripBird rawAfter else rawAfter
    originalIndent = Text.takeWhile isIndentChar codeLine
    baseIndent
      | closesLayout codeLine = dedent originalIndent
      | otherwise = originalIndent
    childIndent = originalIndent <> "  "
    emptyPair = maybe False (`Text.isPrefixOf` Text.stripStart codeAfter) (matchingClose (lastNonSpace codeBefore))

stripBird :: Text -> Text
stripBird text = case Text.stripPrefix ">" text of
  Nothing -> text
  Just rest -> maybe rest id (Text.stripPrefix " " rest)

isIndentChar :: Char -> Bool
isIndentChar c = c == ' ' || c == '\t'

dedent :: Text -> Text
dedent indent
  | Text.isSuffixOf "\t" indent = Text.dropEnd 1 indent
  | otherwise = Text.take (max 0 (Text.length indent - 2)) indent

lastNonSpace :: Text -> Maybe Char
lastNonSpace = fmap snd . Text.unsnoc . Text.stripEnd

matchingClose :: Maybe Char -> Maybe Text
matchingClose (Just '(') = Just ")"
matchingClose (Just '[') = Just "]"
matchingClose (Just '{') = Just "}"
matchingClose _ = Nothing

-- | Recognize only syntactic tails that open a Haskell layout context.
-- Comments and quoted literals cannot trigger continuation indentation.
opensLayout :: Text -> Bool
opensLayout raw = any (`Text.isSuffixOf` code) symbols || any (endsWord code) keywords
  where
    code = Text.stripEnd (codeOnly raw)
    symbols = ["\\case", "->", "<-", "=", "|", "(", "[", "{"]
    keywords = ["do", "where", "let", "of", "then", "else"]
    endsWord text token = token `Text.isSuffixOf` text && maybe True (not . isWordChar . snd) (Text.unsnoc (Text.dropEnd (Text.length token) text))

closesLayout :: Text -> Bool
closesLayout line = any starts ["in", "else", ")", "]", "}"]
  where
    body = Text.stripStart (codeOnly line)
    starts token = token `Text.isPrefixOf` body && boundary (Text.drop (Text.length token) body)
    boundary rest = maybe True (not . isWordChar . fst) (Text.uncons rest)

isWordChar :: Char -> Bool
isWordChar c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'

-- | Remove line comments, nested block comments, and quoted literals from
-- one line before checking its final syntactic cue. Quoted literals are
-- replaced by a marker so a preceding @=@ cannot be mistaken for a tail.
codeOnly :: Text -> Text
codeOnly = Text.pack . scan 0 Nothing . Text.unpack
  where
    scan :: Int -> Maybe Char -> String -> String
    scan _ _ [] = []
    scan depth quote input@(c : rest)
      | depth > 0 = case input of
          '{' : '-' : more -> scan (depth + 1) quote more
          '-' : '}' : more -> scan (depth - 1) quote more
          _ : more -> scan depth quote more
      | Just q <- quote = case input of
          '\\' : _ : more -> scan 0 (Just q) more
          x : more | x == q -> 'x' : scan 0 Nothing more
          _ : more -> scan 0 (Just q) more
      | "--" `prefixOf` input = []
      | "{-" `prefixOf` input = ' ' : scan 1 Nothing (drop 2 input)
      | c == '"' || c == '\'' = 'x' : scan 0 (Just c) rest
      | otherwise = c : scan 0 Nothing rest
    prefixOf :: String -> String -> Bool
    prefixOf prefix input = take (length prefix) input == prefix

-- | Remove a chunk of leading indentation to the previous two-column
-- boundary. At a non-indentation cursor, ordinary one-grapheme deletion
-- remains in effect.
backspaceIndent :: Doc.Document -> Maybe Doc.Document
backspaceIndent document
  | Text.null before || not (Text.all isIndentChar before) = Doc.backspace unicode document
  | otherwise = removeTo target document
  where
    before = Doc.beforeCursor document
    width = Doc.unColumn (displayColumn before)
    target = ((width - 1) `div` 2) * 2
    removeTo column current
      | Doc.unColumn (displayColumn (Doc.beforeCursor current)) <= column = Just current
      | otherwise = Doc.backspace unicode current >>= removeTo column
