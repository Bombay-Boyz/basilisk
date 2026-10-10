{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Everything about the cursor that cannot be derived from a
-- 'Document' -- which is one field -- and the whole of the editor's
-- Unicode knowledge. This is the only module that imports ICU; every
-- other module receives what it needs as a 'Unicode' record.
module Basilisk.Cursor
  ( Cursor (..)
  , unicode
  , widthAt
  , clusterBounds
  , displayColumn
  , syncColumn
  , renderable
  ) where

import Control.DeepSeq (NFData)
import qualified Data.Char as Char
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.ICU as ICU
import Data.Text.ICU.Char
  ( EastAsianWidth (..)
  , EastAsianWidth_ (..)
  , GeneralCategory (..)
  , GeneralCategory_ (..)
  , property
  )
import GHC.Generics (Generic)

import qualified Basilisk.Document as Doc
import Basilisk.Document (Column (..), Document, Unicode (Unicode), beforeCursor, tabStop)

-- | The remembered column vertical motion returns to. Moving onto a
-- short line clamps what is visible but must not overwrite the column a
-- later, longer line should recover.
newtype Cursor = Cursor { desiredColumn :: Column }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The services "Basilisk.Document" asks for, bound to ICU.
unicode :: Unicode
unicode = Unicode { Doc.widthAt = widthAt, Doc.clusters = clusterBounds }

-- | Display width, measured from a known column because a tab is not a
-- fixed width.
--
-- The assignment is forced by what 'renderable' actually draws: a width
-- that disagreed with the glyph would put the terminal cursor in the
-- wrong place on every line containing one.
--
--   * a tab advances to the next 'tabStop';
--   * combining marks and format characters (including the zero-width
--     joiner, which emoji sequences need) are zero, and are drawn as
--     themselves;
--   * other control characters are one, and are drawn as a single
--     replacement glyph -- never emitted raw, so a file cannot drive
--     the terminal with its own escape sequences;
--   * East Asian wide and fullwidth forms are two;
--   * everything else, including ambiguous-width characters, is one,
--     matching how non-CJK-locale terminals render them.
widthAt :: Column -> Char -> Int
widthAt (Column col) '\t' = tabStop - (col `mod` tabStop)
widthAt _ c
  | invisible c      = 0
  | Char.isControl c = 1
  | wide c           = 2
  | otherwise        = 1

-- | Zero-width: a mark that composes onto the character before it, or a
-- format character. Deliberately not @Cc@, which 'renderable' replaces
-- with a visible glyph.
invisible :: Char -> Bool
invisible c = case property GeneralCategory c of
  NonSpacingMark -> True
  EnclosingMark  -> True
  FormatChar     -> True
  _              -> False

wide :: Char -> Bool
wide c = case property EastAsianWidth c of
  EAWide -> True
  EAFull -> True
  _      -> False

-- | Ascending grapheme-cluster boundary offsets of a line, including
-- @0@ and the length.
--
-- This is ICU's own UAX #29 break iterator, not a hand-written rule:
-- combining sequences, emoji zero-width-joiner sequences, regional
-- indicator pairs, Hangul jamo and prepended concatenation marks are
-- all its problem rather than this project's. @text-icu@ exposes
-- 'ICU.breakCharacter' as a pure function, so using the real segmenter
-- costs neither an @unsafePerformIO@ nor an effectful field on
-- 'Unicode' -- which is why an approximation is not worth keeping.
--
-- @scanl@ over the break lengths yields the boundaries: @0@ first by
-- construction, the line length last because the breaks partition the
-- line, and the empty line gives @[0]@.
clusterBounds :: Text -> [Int]
clusterBounds = scanl (+) 0 . map (Text.length . ICU.brkBreak) . ICU.breaks breaker

-- | Grapheme clustering is locale-independent, so the root locale is
-- the right one and the iterator can be a constant.
breaker :: ICU.Breaker ()
breaker = ICU.breakCharacter ICU.Root

-- | The column a piece of text ends at, tabs included. Strict fold: no
-- thunk survives to the end of the line.
displayColumn :: Text -> Column
displayColumn = Text.foldl' (\ !w c -> w + Column (widthAt w c)) (Column 0)

-- | Recompute the remembered column from where the cursor actually is.
syncColumn :: Document -> Cursor
syncColumn = Cursor . displayColumn . beforeCursor

-- | What actually reaches the terminal: tabs expanded to the next stop,
-- other control characters replaced by one visible glyph. Both are
-- required for correctness, not cosmetics. Drawing a raw tab would let
-- the terminal pick a width 'widthAt' did not predict, and drawing a
-- raw escape or carriage return would let the contents of a file move
-- the terminal's own cursor -- so a file full of escape sequences is
-- displayed, never obeyed.
--
-- @displayColumn (renderable t) == displayColumn t@ for every @t@: the
-- substitution is width-preserving by construction, which is what keeps
-- the cursor where the arithmetic says it is.
renderable :: Text -> Text
renderable = Text.concat . reverse . snd . Text.foldl' step (Column 0, [])
  where
    step (col, out) c = (col + Column w, glyph : out)
      where
        w = widthAt col c
        glyph
          | c == '\t'        = Text.replicate w (Text.singleton ' ')
          | Char.isControl c = Text.singleton '\xFFFD'
          | otherwise        = Text.singleton c
