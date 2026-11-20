{-# LANGUAGE OverloadedStrings #-}

-- | A small, pure lexical highlighter for Haskell source. It deliberately
-- operates on visible lines and has no parser or editor-state dependency.
module Basilisk.Syntax
  ( Highlight (..)
  , highlightHaskell
  , highlightMarkdown
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Char as Char

data Highlight = Plain | Keyword | Constructor | Literal | Comment | Pragma | Heading
  deriving (Eq, Show)

highlightHaskell :: Text -> [(Highlight, Text)]
highlightHaskell = lexLine

highlightMarkdown :: Text -> [(Highlight, Text)]
highlightMarkdown line
  | "#" `Text.isPrefixOf` Text.stripStart line = [(Heading, line)]
  | otherwise = [(Plain, line)]

lexLine :: Text -> [(Highlight, Text)]
lexLine input = case Text.uncons input of
  Nothing -> []
  Just (c, rest)
    | lineComment input -> [(Comment, input)]
    | "{-#" `Text.isPrefixOf` input -> takeThrough "#-}" Pragma input
    | "{-" `Text.isPrefixOf` input -> takeBlock input
    | c == '"' -> takeQuoted '"' input
    | c == '\'' && hasClosingQuote rest -> takeQuoted '\'' input
    | Char.isAlpha c || c == '_' -> tokeniseName input
    | Char.isDigit c -> let (digits, suffix) = Text.span (\x -> Char.isAlphaNum x || x == '.' || x == '_') input
                        in (Literal, digits) : lexLine suffix
    | otherwise -> (Plain, Text.singleton c) : lexLine rest

tokeniseName :: Text -> [(Highlight, Text)]
tokeniseName input = (kind, word) : lexLine rest
  where
    (word, rest) = Text.span (\c -> Char.isAlphaNum c || c == '_' || c == '\'') input
    kind
      | word `Set.member` keywords = Keyword
      | maybe False Char.isUpper (fst <$> Text.uncons word) = Constructor
      | otherwise = Plain

takeQuoted :: Char -> Text -> [(Highlight, Text)]
takeQuoted quote input = (Literal, consumed) : lexLine rest
  where
    (consumed, rest) = quoted False [] input
    quoted escaped acc text = case Text.uncons text of
      Nothing -> (Text.pack (reverse acc), Text.empty)
      Just (c, tailText)
        | escaped -> quoted False (c : acc) tailText
        | c == '\\' -> quoted True (c : acc) tailText
        | c == quote -> (Text.pack (reverse (c : acc)), tailText)
        | otherwise -> quoted False (c : acc) tailText

hasClosingQuote :: Text -> Bool
hasClosingQuote = maybe False (const True) . Text.find (== '\'')

takeBlock :: Text -> [(Highlight, Text)]
takeBlock input = (Comment, consumed) : lexLine rest
  where
    (parts, suffix) = block 0 [] input
    consumed = Text.concat (reverse parts)
    rest = suffix
    block :: Int -> [Text] -> Text -> ([Text], Text)
    block depth acc text
      | "{-" `Text.isPrefixOf` text =
          block (depth + 1) ("{-" : acc) (Text.drop 2 text)
      | "-}" `Text.isPrefixOf` text =
          let next = "-}" : acc
          in if depth <= 1 then (next, Text.drop 2 text)
             else block (depth - 1) next (Text.drop 2 text)
      | otherwise = case Text.uncons text of
          Nothing -> (acc, Text.empty)
          Just (c, after) -> block depth (Text.singleton c : acc) after

takeThrough :: Text -> Highlight -> Text -> [(Highlight, Text)]
takeThrough ending kind input = (kind, consumed) : lexLine rest
  where
    (before, suffix) = Text.breakOn ending input
    consumed
      | Text.null suffix = input
      | otherwise = before <> ending
    rest = if Text.null suffix then Text.empty else Text.drop (Text.length ending) suffix

keywords :: Set.Set Text
keywords = Set.fromList
  [ "as", "case", "class", "data", "default", "deriving", "do", "else"
  , "forall", "foreign", "if", "import", "in", "infix", "infixl"
  , "infixr", "instance", "let", "module", "newtype", "of", "then"
  , "type", "where", "qualified", "hiding", "mdo", "family", "role"
  , "pattern", "stock", "anyclass", "via"
  ]

lineComment :: Text -> Bool
lineComment input = case Text.uncons (Text.drop 2 input) of
  Nothing -> "--" `Text.isPrefixOf` input
  Just (next, _) -> "--" `Text.isPrefixOf` input && not (symbol next)

symbol :: Char -> Bool
symbol c = c `elem` (":!#$%&*+./<=>?@\\^|-~" :: String)
