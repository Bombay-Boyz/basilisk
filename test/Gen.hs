{-# LANGUAGE OverloadedStrings #-}

-- | Generators. The character generator is deliberately hostile: every
-- class that has ever broken a terminal editor is over-represented
-- relative to its frequency in real text, because the whole point of
-- generating input is to reach the cases hand-written examples do not.
module Gen
  ( genChar
  , genLine
  , genBody
  , genDocument
  , genEditor
  , genMotion
  , genOperator
  , genAction
  , genActionFor
  , genMatched
  , genCount
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

import qualified Basilisk.Cursor as Cursor
import qualified Basilisk.Document as Doc
import Basilisk.Types

genChar :: Gen Char
genChar = Gen.frequency
  [ (30, Gen.element ("abcdefgXYZ_-.,;()[]{} " :: String))   -- ordinary source text
  , (8,  pure '\t')                                          -- tab: width depends on column
  , (5,  Gen.element ['\r', '\ESC', '\NUL', '\SOH', '\DEL'])  -- control: must never reach the terminal
  , (8,  Gen.element ("\x6F22\x5B57\x65E5\x672C\x8A9E" :: String)) -- wide: two columns, one offset
  , (8,  Gen.element ['\x0301', '\x0302', '\x0308'])          -- combining marks
  , (4,  pure '\x200D')                                       -- zero-width joiner
  , (4,  Gen.element ['\x1F1E6', '\x1F1E7', '\x1F1FF'])       -- regional indicators
  , (4,  Gen.element ("\xE9\xF1\xFC\x3B1\x3B2" :: String))    -- non-ASCII letters
  , (3,  Gen.element ['\x1F600', '\x1F680'])                  -- astral plane
  ]

genLine :: Gen Text
genLine = Gen.text (Range.linear 0 24) genChar

genBody :: Gen Text
genBody = Text.intercalate "\n" <$> Gen.list (Range.linear 1 6) genLine

-- | A document with the cursor placed somewhere reachable, rather than
-- always at the origin: most boundary bugs need a cursor that is not at
-- the start of a line.
--
-- Ends with 'Doc.alignCursor', and that call is load-bearing, not
-- decorative. @move@'s own 'Doc.Chars' case is a raw positional
-- 'Basilisk.Document.shift' -- it trusts that whatever produced the
-- displacement already snapped it to a cluster boundary, which every
-- real motion in the editor does and this generator does not: it hands
-- @move@ an arbitrary codepoint offset @c@ directly. On a line
-- containing a combining mark (which 'genChar' deliberately generates),
-- that offset can land strictly inside a cluster, producing a document
-- that violates "the cursor sits on a cluster boundary" before any
-- 'step' has even run. 'alignCursor' is the same repair
-- @Basilisk.Step.retract@ applies after every real transition;
-- applying it once more here is what makes that invariant a
-- /precondition/ every property can rely on, not only a postcondition
-- 'step' happens to restore. Found by 'prop_repeat_to_never_gets_stuck'
-- failing intermittently on exactly this shape of document -- a single
-- combining mark as its own one-character line -- while every property
-- that only reads a /stepped/ result had no way to notice, since
-- 'step' was quietly fixing the generator's mistake on their behalf.
genDocument :: Gen Doc.Document
genDocument = do
  d <- Doc.fromText <$> genBody
  r <- Gen.int (Range.linear 0 5)
  c <- Gen.int (Range.linear 0 20)
  pure (Doc.alignCursor Cursor.unicode
          (Doc.move Cursor.unicode 0 (Doc.Chars c) (Doc.move Cursor.unicode 0 (Doc.Lines r) d)))

genCount :: Gen Int
genCount = Gen.frequency
  [ (8, Gen.int (Range.linear 0 5))
  , (1, Gen.int (Range.linear 0 maxBound))   -- the CVE-2023-4823x class
  , (1, Gen.int (Range.linear minBound 0))   -- and a negative one, however it arrived
  ]

genMotion :: Gen Motion
genMotion = Gen.choice
  [ Gen.element
      [ MChar DUp, MChar DDown, MChar DLeft, MChar DRight
      , MWord, MWordBack, MWordEnd, MLine, MLineStart, MFirstNonBlank, MLineEnd, MGotoLine ]
  -- Short patterns, and drawn from the same alphabet the documents
  -- are, so that a search usually finds something.
  , MFind <$> Gen.bool <*> Gen.text (Range.linear 0 3) genChar
  , MTo <$> Gen.bool <*> Gen.bool <*> genChar
  , MBigWord <$> Gen.bool
  , MParagraph <$> Gen.bool
  , Gen.element [MMatch, MColumn]
  ]

genOperator :: Gen Operator
genOperator = Gen.element [Delete, Yank, Change, ToLower, ToUpper, ToggleCase, Indent, Dedent]

genNormal :: Gen NormalCmd
genNormal = Gen.choice
  [ NMove <$> genCount <*> genMotion
  , NOperate <$> genCount <*> genOperator <*> genMotion
  , NEnterInsert <$> genCount <*> Gen.element [Before, After, LineBelow, LineAbove]
  , NEnterPrompt <$> Gen.element [ExCommand, Search]
  , NPaste <$> Gen.int (Range.linear 0 4) <*> Gen.bool
  , NJoin <$> genCount
  , NRepeatFind <$> genCount <*> Gen.bool
  , NRepeatTo <$> genCount <*> Gen.bool
  , NRepeat <$> genCount
  , NPasteText <$> genLine
  , NUndo <$> genCount
  , NRedo <$> genCount
  , NReplace <$> genCount <*> genChar
  , pure NEnterReplace
  , pure NSave
  , pure NWriteQuit
  , pure NQuitDiscard
  ]

genInsert :: Gen InsertCmd
genInsert = Gen.choice
  [ IInput <$> Gen.text (Range.linear 0 4) (Gen.frequency [(6, genChar), (1, pure '\n')])
  , pure IBackspace
  , IMove <$> Gen.element [DUp, DDown, DLeft, DRight]
  , pure IEscape
  ]

genPrompt :: Gen PromptCmd
genPrompt = Gen.choice
  [ PInput <$> Gen.text (Range.linear 0 3) genChar
  , pure PBackspace
  , pure PSubmit
  , pure PEscape
  ]

genAction :: Gen Action
genAction = Gen.choice [InNormal <$> genNormal, InInsert <$> genInsert, InPrompt <$> genPrompt]

genMode :: Gen Mode
genMode = Gen.choice
  [ pure Normal
  , Insert <$> Gen.element [Fresh, Dirty]
  , Replace <$> Gen.list (Range.linear 0 4) (Gen.maybe (Gen.text (Range.linear 1 2) genChar))
  , Prompt <$> Gen.element [ExCommand, Search]
           <*> Gen.frequency [(3, Gen.text (Range.linear 0 4) genChar), (1, Gen.element ["w", "q", "write", "quit"])]
  ]

-- | Nothing is pinned to a default: a generator that always produced
-- @path = Nothing@ would make every property about saving vacuous.
genEditor :: Gen Editor
genEditor = do
  base <- newEditor <$> Gen.maybe (pure "out.txt") <*> genBody
  m    <- genMode
  d    <- genDocument
  reg  <- Gen.maybe (Clip <$> Gen.bool <*> genLine)
  el   <- Gen.element [LF, CRLF, CR]
  t    <- Gen.int (Range.linear 0 8)
  st   <- Gen.maybe genLine
  fe   <- Gen.bool
  lf   <- Gen.maybe ((,) <$> Gen.bool <*> Gen.text (Range.linear 0 3) genChar)
  be   <- Gen.bool
  pure (onBuffer (\b -> b { bEol = el, bFinalEol = fe, bBornEmpty = be })
               (withDocument d base { mode = m, register = reg, top = t, status = st, lastFind = lf }))

-- | An action whose tag matches the editor's mode -- the pairing
-- 'Basilisk.Decode' is responsible for producing, and the only one the
-- editor can actually be in.
genActionFor :: Mode -> Gen Action
genActionFor Normal      = InNormal <$> genNormal
genActionFor (Insert _)  = InInsert <$> genInsert
genActionFor (Replace _) = InInsert <$> genInsert
genActionFor (Prompt _ _) = InPrompt <$> genPrompt

genMatched :: Gen (Action, Editor)
genMatched = do
  e <- genEditor
  a <- genActionFor (mode e)
  pure (a, e)
