{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A document is a zipper of lines whose focused line is itself a zipper
-- of 'Text'. The two split points ARE the cursor: nothing stores a row or
-- a column, here or anywhere else (2.5).
--
-- Every function below is total. A primitive that can decline to act
-- returns 'Maybe'; 'Nothing' means "no change", exactly, in O(1) -- the
-- primitive already knows, so no caller ever compares two documents to
-- find out (2.4d).
module Basilisk.Document
  ( -- * Coordinates (2.4c)
    Offset (..)
  , Column (..)
  , unOffset
  , unColumn
    -- * Unicode services
  , Unicode (..)
  , ascii
  , tabStop
    -- * Documents
  , Direction (..)
  , Document
  , fromText
  , toText
  , currentLine
  , beforeCursor
  , lineCount
  , cursorRow
  , cursorCol
  , window
    -- * The reach algebra (2.4a)
  , Motion (..)
  , Operator (..)
  , Reach (..)
  , reach
  , reachToFrom
  , forcedLinewise
  , toLines
  , move
  , extend
  , inclusive
  , operate
    -- * Edits
  , insert
  , backspace
  , insertAfter
  , pasteRows
  , openLine
  , replaceChars
  , overwriteChar
  , restoreChar
  , joinLines
    -- * Normal-mode retraction (2.5)
  , clampGap
  , alignCursor
  , onBoundary
  ) where

import Control.DeepSeq (NFData)
import Data.Bifunctor (first)
import qualified Data.Char as Char
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq, ViewL (..), ViewR (..), (><), (<|), (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)

-- | A CHARACTER offset into a line. Distinct from 'Column' because this
-- project shipped the bug that confusing them causes: a display column
-- handed to a function expecting a character offset misplaces the cursor
-- on every line holding a wide character. 'columnToOffset' is the only
-- function allowed to see both domains.
newtype Offset = Offset Int
  deriving stock (Show, Generic)
  deriving newtype (Eq, Ord, Num)
  deriving anyclass (NFData)

-- | An on-screen DISPLAY column, in the units 'Basilisk.Cursor.charWidth'
-- counts in. A wide character advances a 'Column' by two and an 'Offset'
-- by one; that gap is what 'columnToOffset' bridges.
newtype Column = Column Int
  deriving stock (Show, Generic)
  deriving newtype (Eq, Ord, Num)
  deriving anyclass (NFData)

unOffset :: Offset -> Int
unOffset (Offset n) = n

unColumn :: Column -> Int
unColumn (Column n) = n

-- | The Unicode services this module needs but refuses to implement.
-- Supplied by "Basilisk.Cursor", which is the only module that knows ICU
-- exists. Keeping them behind a record rather than importing ICU here is
-- what lets every function below be exercised against a trivial ASCII
-- instance and shipped against the real one.
--
-- 'widthAt' takes the column it measures from, because a tab is not a
-- fixed width: it advances to the next multiple of 'tabStop'. Nothing
-- else in the editor needs to know that.
--
-- 'clusters' gives the ascending grapheme-cluster boundary offsets of a
-- line, including both @0@ and the length. A cursor that can sit
-- between the two codepoints of a combining sequence is the most
-- reported class of bug in terminal editors; making every horizontal
-- motion hop between these offsets is what forbids it.
data Unicode = Unicode
  { widthAt  :: !(Column -> Char -> Int)
  , clusters :: !(Text -> [Int])
  }

-- | The degenerate instance: every character one column, every
-- codepoint its own cluster. Not used by the editor, which binds the
-- ICU one, but it is what lets this module's algebra be tested for
-- correctness separately from the question of whether ICU classifies
-- any particular codepoint the way one expects.
ascii :: Unicode
ascii = Unicode { widthAt = \_ _ -> 1, clusters = \t -> [0 .. Text.length t] }

-- | Columns a tab advances to. Eight, as every terminal and vim default
-- to; a configurable value would be a setting, and v1 has none.
tabStop :: Int
tabStop = 8

-- | Prefixed to avoid clashing with the unqualified 'Either'
-- constructors on import.
data Direction = DUp | DDown | DLeft | DRight
  deriving (Eq, Show, Generic, NFData)

-- | Invariant: @before <> after@ is the whole line, and neither half
-- contains a newline. Not exported, so no caller can break it.
data LineZ = LineZ { before :: !Text, after :: !Text }
  deriving (Eq, Show, Generic, NFData)

-- | Lines above the cursor, the cursor's own line, lines below. There is
-- always a focused line, so a document is never empty and no code
-- anywhere needs a zero-line case.
data Document = Document
  { above :: !(Seq Text)
  , here  :: !LineZ
  , below :: !(Seq Text)
  } deriving (Eq, Show, Generic, NFData)

-- observation ---------------------------------------------------------

currentLine :: Document -> Text
currentLine = (<>) <$> before . here <*> after . here

-- | The part of the focused line left of the cursor -- all 'Render'
-- needs in order to compute the cursor's display column.
beforeCursor :: Document -> Text
beforeCursor = before . here

cursorRow :: Document -> Int
cursorRow = Seq.length . above

cursorCol :: Document -> Offset
cursorCol = Offset . Text.length . beforeCursor

lineCount :: Document -> Int
lineCount = Seq.length . lines'

-- | The rows in @[i, i+n)@, clamped to the document. The only view of the
-- line sequence anything outside this module gets.
window :: Int -> Int -> Document -> [Text]
window i n = toList . Seq.take n . Seq.drop i . lines'

-- | The document flattened back to a plain line sequence. @O(log n)@.
lines' :: Document -> Seq Text
lines' = (><) <$> ((|>) <$> above <*> currentLine) <*> below

-- construction --------------------------------------------------------

-- | Refocus a line sequence at row @r@, placing the cursor on the landing
-- line at the offset @at@ chooses for it. Rows are clamped, so this is
-- total for every @r@, including negative and past-end ones, and it is
-- the single constructor of a 'Document': 'fromText', vertical motion,
-- line deletion and line opening are all instances of it.
focusAt :: (Text -> Offset) -> Int -> Seq Text -> Document
focusAt at r ls = pivot (Seq.splitAt (max 0 (min r (Seq.length ls - 1))) ls)
  where
    pivot (pre, rest) = case Seq.viewl rest of
      ln :< post -> Document pre (place (at ln) ln) post
      EmptyL     -> Document pre (LineZ Text.empty Text.empty) Seq.empty

-- | Split a line at an offset, clamped to the line. Total for every
-- 'Offset'. Takes an 'Offset', never a 'Column' -- handing it a display
-- column is a compile error, not a silent misplacement.
place :: Offset -> Text -> LineZ
place o t = uncurry LineZ (Text.splitAt (unOffset (max 0 (min o (Offset (Text.length t))))) t)

-- | @toText . fromText = id@ for every input: 'Text.splitOn' is a section
-- of 'Text.intercalate' for a non-empty separator, and 'focusAt' changes
-- no line's content.
fromText :: Text -> Document
fromText = focusAt (const 0) 0 . Seq.fromList . Text.splitOn "\n"

toText :: Document -> Text
toText = Text.intercalate "\n" . toList . lines'

-- | Walk a line summing character widths until the target display column
-- is met. The one function in the module that sees both coordinate
-- domains; parametric in the width function so this module stays
-- Unicode-agnostic ('Basilisk.Cursor' supplies the ICU-backed one).
-- | Round an offset down, or up, to the nearest of an already-computed,
-- ascending list of grapheme-cluster boundaries.
--
-- Takes the list directly rather than a 'Unicode' and a 'Text' to
-- compute it from, because the callers that round /repeatedly/ against
-- the same line -- 'forwardTarget' and 'backwardTarget', once per step
-- of a counted motion -- must compute that list once and reuse it.
-- 'floorBoundary'\/'ceilBoundary' below are the convenience wrappers for
-- the many callers that round only once.
floorAt :: [Int] -> Int -> Int
floorAt bs p = foldl (\acc b -> if b <= p then b else acc) 0 bs

ceilAt :: [Int] -> Int -> Int
ceilAt bs p = case dropWhile (< p) bs of
  b : _ -> b
  []    -> foldl (\_ b -> b) p bs   -- the last boundary, total, never 'last'

-- | Round an offset down, or up, to a grapheme-cluster boundary of a
-- line. Total for every input, including offsets outside the line.
--
-- These exist because two of the three ways an offset is computed know
-- nothing about clusters: a word motion works from character classes,
-- and a vertical motion works from display widths. A combining mark is
-- neither alphanumeric nor one column wide, so without snapping, @w@
-- could stop between a letter and its accent and @j@ could land there
-- too -- the precise failure that grapheme-cluster bugs in terminal
-- editors are made of.
--
-- One-shot wrappers around 'floorAt'\/'ceilAt': fine for a caller that
-- rounds once, wrong for one that rounds in a loop -- see
-- 'forwardTarget'.
floorBoundary :: Unicode -> Text -> Int -> Int
floorBoundary u t = floorAt (clusters u t)

ceilBoundary :: Unicode -> Text -> Int -> Int
ceilBoundary u t = ceilAt (clusters u t)

-- | 'ceilAt', but also returning the suffix of the boundary list from
-- the chosen element onward.
--
-- 'forwardTarget's target offset only ever increases across the steps
-- of one motion, so the boundary it needs only ever moves forward
-- through the same list too. Calling 'ceilAt' fresh each step -- which
-- the first attempt at this fix did -- rescans from the front of
-- @bounds@ every time; over @k@ steps that is @O(line)@ per step and
-- @O(line × k)@ overall, the same shape of mistake as recomputing
-- @bounds@ itself would be, just with a smaller constant. Threading
-- the already-advanced-past suffix here is what 'forwardTarget'
-- already does for the line's /text/ via @rest@; doing the same for
-- its /boundaries/ is the rest of that same idea, applied consistently.
ceilAdvance :: [Int] -> Int -> ([Int], Int)
ceilAdvance bs p = case dropWhile (< p) bs of
  found@(b : _) -> (found, b)
  []            -> ([], foldl (\_ b -> b) p bs)

-- | The mirror of 'ceilAdvance' for a boundary list stored highest
-- first, matching 'backwardTarget's monotonically decreasing target.
floorRetreat :: [Int] -> Int -> ([Int], Int)
floorRetreat bs p = case dropWhile (> p) bs of
  found@(b : _) -> (found, b)
  []            -> ([], 0)

-- | The signed displacement from the cursor to an absolute offset,
-- snapped outward to a cluster boundary so that a span never ends
-- inside one. Every 'Chars' reach that is not already boundary-counted
-- by 'hop' is built here.
-- | Like 'toward', but for a target that does not depend on the
-- cursor's current position at all -- @^@'s first non-blank column,
-- @|@'s absolute column -- rather than one computed relative to it, as
-- a word motion's or a find-char's is.
--
-- The difference matters for idempotence, not merely which boundary is
-- chosen. 'toward' picks its snap direction by comparing the target to
-- the /current/ cursor, which is correct when the target itself moves
-- with the cursor (pressing @w@ again searches forward from wherever
-- you now are). For an absolute target it is wrong: landing on one
-- side of the raw column and then re-invoking the same motion can
-- compare the same raw target against a now-different cursor position
-- and snap the /other/ way, oscillating between two boundaries on
-- repeated presses instead of staying put -- which real vim's @^@ and
-- @|@ never do. Found by the counted-displacement property on a line
-- with a combining mark straddling the blank\/non-blank boundary;
-- narrow to trigger, but a correctness gap in ordinary idempotence
-- nonetheless, not merely in a count's interpretation. Always snapping
-- forward, regardless of where the cursor currently is, makes the
-- result a pure function of the raw target and the line -- so a second
-- application with the same target is `Chars 0`, from either side.
towardAbsolute :: Unicode -> Document -> Int -> Reach
towardAbsolute u d p = Chars (ceilBoundary u (currentLine d) p - unOffset (cursorCol d))

toward :: Unicode -> Document -> Int -> Reach
toward u d p = Chars (snap - o)
  where
    o    = unOffset (cursorCol d)
    line = currentLine d
    snap | p >= o    = ceilBoundary u line p
         | otherwise = floorBoundary u line p

columnToOffset :: Unicode -> Column -> Text -> Offset
columnToOffset u want t = Offset (floorBoundary u t (go 0 0 t))
  where
    go !o !c s = case Text.uncons s of
      Nothing        -> o
      Just (ch, rest)
        | c >= want -> o
        | otherwise -> go (o + 1) (c + Column (widthAt u c ch)) rest

-- the reach algebra ---------------------------------------------------

-- | What a motion reaches from the cursor, as a signed displacement in
-- one of the two coordinates the document has. Signs remove every
-- mirror-image case: one 'Chars' handles @h@ and @l@, @d0@ and @d$@; one
-- 'Lines' handles @k@ and @j@, @dk@ and @dj@.
-- | What a motion reaches from the cursor.
--
-- Three shapes, not two, and the third is not a convenience: a search
-- or a selection names a position on another row, and no signed
-- displacement within one row or across whole rows can express the
-- partial first and last rows that a charwise span across lines has.
--
-- 'Chars' is 'Upto' restricted to the current row, and the restriction
-- earns its place: every line-local motion is then total by
-- construction and costs @O(line)@ rather than @O(document)@.
data Reach
  = Chars !Int      -- ^ signed, within the current row
  | Lines !Int      -- ^ signed, whole rows
  | Upto !Int !Int  -- ^ an absolute @(row, offset)@, charwise, possibly on another row
  deriving (Eq, Show, Generic, NFData)

-- | A named span relative to the cursor. Pure data: no motion knows what
-- an operator will do with the span, and no operator knows how a motion
-- computed it.
data Motion
  = MChar !Direction   -- ^ @h@ @j@ @k@ @l@
  | MWord              -- ^ @w@: to the start of the next word
  | MWordBack          -- ^ @b@: to the start of the previous word
  | MWordEnd           -- ^ @e@: past the end of the current or next word
  | MLine              -- ^ the current row, linewise and inclusive
  | MLineStart         -- ^ @0@
  | MFirstNonBlank     -- ^ @^@
  | MLineEnd           -- ^ @$@
  | MGotoLine          -- ^ @G@ with a count, @gg@ without
  | MFind !Bool !Text  -- ^ the @n@th literal match, backwards when 'True'
  | MTo !Bool !Bool !Char -- ^ @f t F T@: backwards?, stop short?, target
  | MBigWord !Bool     -- ^ @W@ and @B@: whitespace-delimited
  | MParagraph !Bool   -- ^ @}@ and @{@: to the next or previous blank row
  | MMatch             -- ^ @%@: the bracket matching the one at or after the cursor
  | MColumn            -- ^ @|@: the column a count names
  deriving (Eq, Show, Generic, NFData)

-- | What to do with the span: keep the cut document ('Delete') or discard
-- it and keep only the text ('Yank').
-- | 'Change' is 'Delete' followed by entering Insert mode. It cuts the
-- same span through the same 'excise', which is the whole point of
-- keeping operators as projections: a third one costs one equation
-- here and one clause in "Basilisk.Step", and inherits every motion
-- that exists or ever will.
-- | 'ToLower'\/'ToUpper'\/'ToggleCase' are @gu@\/@gU@\/@g~@ (and bare
-- @~@, which is the same operator over a fixed one-character motion --
-- see 'Basilisk.Decode'). 'Indent'\/'Dedent' are @>@\/@<@, which vim
-- forces to linewise regardless of the motion given them; 'reach'
-- computing a charwise span for one of these is handled by converting
-- it to the rows it touches before 'operate' ever sees it (2.10f).
data Operator = Delete | Yank | Change | ToLower | ToUpper | ToggleCase | Indent | Dedent
  deriving (Eq, Show, Generic, NFData)

-- | Whether an operator always acts on whole rows regardless of what
-- motion it was given -- vim's own rule for @>@\/@<@ (and, in real vim,
-- several others this project does not yet implement). Checked
-- exhaustively, so a new operator must declare which side of this line
-- it is on before it compiles.
forcedLinewise :: Operator -> Bool
forcedLinewise Delete     = False
forcedLinewise Yank       = False
forcedLinewise Change     = False
forcedLinewise ToLower    = False
forcedLinewise ToUpper    = False
forcedLinewise ToggleCase = False
forcedLinewise Indent     = True
forcedLinewise Dedent     = True

-- | Convert any reach to the 'Lines' reach spanning the same rows, for
-- an operator 'forcedLinewise' names. A same-row 'Chars' span touches
-- only the current row; an 'Upto' spans from the cursor's row to
-- wherever it names.
toLines :: Document -> Reach -> Reach
toLines _ r@(Lines _)  = r
toLines _ (Chars _)    = Lines 0
toLines d (Upto r _)   = Lines (r - cursorRow d)

-- | Compile a counted motion to the 'Reach' it names. The count enters
-- here, in closed form -- @5j@ is one 'Lines' 5, not five moves, so a
-- count costs @O(distance)@ and never @O(count)@, and a counted operator
-- is one edit and therefore one undo entry (2.4d).
--
-- @MLine@ reaches @Lines (n-1)@ because a linewise operator spans the
-- rows between the cursor and the reach inclusive: @dd@ is one line,
-- @3dd@ is three, @dj@ is two. Every 'Chars' count is clamped to the
-- line, so no 'Reach' ever names text the document does not have.
reach :: Unicode -> Int -> Motion -> Document -> Reach
reach u n (MChar DLeft)  = Chars . hop u (negate n)
reach u n (MChar DRight) = Chars . hop u n
reach _ n (MChar DUp)    = const (Lines (negate n))
reach _ n (MChar DDown)  = const (Lines n)
reach u n MWord          = toward u <*> forwardTarget u wordStep n
reach u n MWordBack      = toward u <*> backwardTarget u wordBackStep n
reach u n MWordEnd       = toward u <*> forwardTarget u wordEndStep n
reach u _ MFirstNonBlank = towardAbsolute u <*> indentOf
reach _ _ MLineStart     = Chars . negate . unOffset . cursorCol
reach _ _ MLineEnd       = Chars . Text.length . after . here
reach _ n MLine          = const (Lines (n - 1))
reach _ n MGotoLine      = Lines . subtract' n
reach _ n (MFind b pat)  = maybe (Chars 0) (uncurry Upto) . findNth b n pat
reach u n (MTo b t c)    = \d -> toward u d (toTarget b t c n (unOffset (cursorCol d)) d)
reach u n (MBigWord b)   = \d -> toward u d (bigWordTarget u b n d)
reach _ n (MParagraph b) = \d -> Lines (paragraphStep b n d)
reach u _ MMatch         = \d -> maybe (Chars 0) (uncurry Upto) (matchBracket d) `orStay` u
reach u n MColumn        = \d -> towardAbsolute u d (max 0 (n - 1))

-- | The signed character distance to the boundary @n@ grapheme clusters
-- away, clamped to the line. This is the only definition of "one
-- character" the editor has, and it is deliberately not one codepoint:
-- @l@, @h@, @x@ and backspace all step over a combining sequence or an
-- emoji as the single thing the user sees.
hop :: Unicode -> Int -> Document -> Int
hop u n d = subtract here' (walk n (clusters u (currentLine d)))
  where
    here'   = unOffset (cursorCol d)
    walk k bs
      | k > 0     = nth (k - 1) here' (dropWhile (<= here') bs)
      | k < 0     = nth (negate k - 1) here' (reverse (takeWhile (< here') bs))
      | otherwise = here'
    -- The k-th boundary if there is one, otherwise the furthest there
    -- is, otherwise stay put. Total, and never 'last' or '(!!)'.
    nth k stay bs = case drop k bs of
      x : _ -> x
      []    -> foldl (\_ x -> x) stay bs

-- | Where @n@ repetitions of a stepping function land, as an absolute
-- offset, snapping to a grapheme-cluster boundary between every step.
--
-- Snapping only at the end is not equivalent, and the difference is a
-- real bug rather than a nicety: an intermediate landing inside a
-- cluster leaves the next step looking at a bare combining mark, whose
-- character class is punctuation, so it counts as a word of its own and
-- the count comes out short. The law @counted displacement equals
-- iteration@ checks exactly this.
--
-- Genuinely linear in the line, not merely in @n@: both the text and
-- the cluster boundaries are threaded through the loop as monotonically
-- shrinking suffixes -- @rest@ and @bs@ -- rather than re-sliced or
-- re-scanned from the start on every step. Skipping either one still
-- terminates (a step that cannot advance is a fixed point, so a count
-- of a million costs no more iterations than one that reaches the line
-- end) but costs @O(line)@ /per step/, and this project has now made
-- that mistake twice: once as a whole re-segmentation with 'clusters'
-- (fixed by computing @bounds@ once), and once more subtly as a
-- from-the-front rescan of that same precomputed list with 'ceilAt'
-- (fixed by 'ceilAdvance'). Measured before the second fix: 9ms for a
-- 100-word line, 438ms for 800 -- a clean quadratic in the number of
-- word boundaries that the first fix alone did not remove.
forwardTarget :: Unicode -> (Text -> Int) -> Int -> Document -> Int
forwardTarget u f n d = go (max 0 n) (unOffset (cursorCol d)) (after (here d)) bounds
  where
    line   = currentLine d
    bounds = clusters u line
    go k !o rest bs
      | k <= 0    = o
      | o' == o   = o
      | otherwise = go (k - 1) o' (Text.drop (o' - o) rest) bs'
      where (bs', o') = ceilAdvance bs (o + f rest)

-- | The mirror image, stepping backwards over the prefix and snapping
-- down instead of up. The boundary list is reversed once so that it,
-- too, can be consumed as a monotonically shrinking suffix by
-- 'floorRetreat', for the reason 'forwardTarget' documents.
backwardTarget :: Unicode -> (Text -> Int) -> Int -> Document -> Int
backwardTarget u f n d = go (max 0 n) (unOffset (cursorCol d)) (reverse bounds)
  where
    line   = currentLine d
    bounds = clusters u line
    go k !o bs
      | k <= 0    = o
      | o' == o   = o
      | otherwise = go (k - 1) o' bs'
      where (bs', o') = floorRetreat bs (o - f (Text.take o line))

-- | The offset of the first non-blank character, or the line's end if
-- it is entirely blank. Vim's @^@.
indentOf :: Document -> Int
indentOf = Text.length . Text.takeWhile ((== Blank) . classify) . currentLine

-- | The row @G@ jumps to, as a displacement: a count names an absolute
-- line, and no count means the last one. Clamped, so @9999G@ is the end
-- of the document rather than an error.
subtract' :: Int -> Document -> Int
subtract' n d = clampRow - cursorRow d
  where clampRow = if n <= 0 then lineCount d - 1 else max 0 (min (n - 1) (lineCount d - 1))

-- | The three classes a vim word motion distinguishes; a boundary is any
-- transition between them. Unicode-aware via 'Char.isAlphaNum', with no
-- ICU dependency.
data CharClass = Blank | WordChar | PunctChar
  deriving (Eq)

classify :: Char -> CharClass
classify c
  | Char.isSpace c                = Blank
  | Char.isAlphaNum c || c == '_' = WordChar
  | otherwise                     = PunctChar

-- | How far one forward word motion advances: past the rest of the
-- current class run, then past the blanks after it. Zero at end of line.
wordStep :: Text -> Int
wordStep t = case Text.uncons t of
  Nothing      -> 0
  Just (c0, _) ->
    let (run, rest) = Text.span ((==) (classify c0) . classify) t
        (gap, _)    = Text.span ((==) Blank . classify) rest
    in Text.length run + Text.length gap

-- eliminators ---------------------------------------------------------

-- | Relocate the cursor to the far end of a reach. 'Chars' is one
-- 'place' on the focused line; 'Lines' refocuses, restoring the caller's
-- target display column on the landing line.
move :: Unicode -> Column -> Reach -> Document -> Document
move _ _ (Upto r o) d = focusAt (const (Offset o)) r (lines' d)
move _ _ (Chars n) d = shift n d
move u c (Lines k) d = focusAt (columnToOffset u c) (cursorRow d + k) (lines' d)

-- | Slide the split point @n@ characters along the focused line, clamped.
shift :: Int -> Document -> Document
shift n d = d { here = place (cursorCol d + Offset n) (currentLine d) }

-- | Motions vim calls /inclusive/: the character the motion lands on
-- belongs to an operator's span, but a bare move stops /on/ it rather
-- than past it. @e@ puts the cursor on the last letter of the word,
-- while @de@ still deletes that letter.
--
-- The distinction cannot live in 'Reach', which is deliberately shared
-- by both eliminators and knows nothing about which one will consume
-- it. So it lives here, as a predicate on the motion, applied by the
-- single caller that moves.
inclusive :: Motion -> Bool
inclusive MWordEnd      = True
inclusive (MChar _)     = False
inclusive MWord         = False
inclusive MWordBack     = False
inclusive MLine         = False
inclusive MLineStart    = False
inclusive MFirstNonBlank = False
inclusive MLineEnd      = False
inclusive MGotoLine     = False
inclusive (MFind _ _)     = False
inclusive (MTo _ _ _)     = True    -- @dfx@ deletes through the x
inclusive (MBigWord _)    = False
inclusive (MParagraph _)  = False
inclusive MMatch          = True    -- @d%@ deletes both brackets
inclusive MColumn         = False

-- | Extend an inclusive motion's span by the cluster it stopped on,
-- which is what makes @de@ delete the letter @e@ stops on.
--
-- The adjustment is on the operator side rather than the move side,
-- and that is forced rather than chosen: retreating after the move
-- would make @2e@ differ from @e e@, because the retreat changes where
-- the second step starts. 'reach' therefore means exactly where the
-- cursor goes, and an operator asks for one cluster more.
extend :: Unicode -> Motion -> Reach -> Document -> Reach
extend u m r d = case r of
  Chars n | inclusive m -> Chars (ceilBoundary u line (o + n + 1) - o)
  _                     -> r
  where
    o    = unOffset (cursorCol d)
    line = currentLine d

-- | Where @f@, @t@, @F@ or @T@ land: the @n@th occurrence of a
-- character on this row, stopping one short of it for @t@ and @T@.
-- Absent means stay put -- a failed search must not move the cursor.
--
-- The hit positions are found with one left-to-right 'Text.uncons'
-- walk, as every other scan in this module is, and deliberately not
-- with 'Text.index' at each candidate offset. Under @text-2.0@'s UTF-8
-- representation 'Text.index' is @O(i)@ rather than @O(1)@, so calling
-- it once per character of the line -- which a list comprehension over
-- @[0 .. length line]@ does -- is @O(n^2)@ overall. Measured directly:
-- 2.8 seconds to scan a single 50,000-character line. This was the one
-- function in the file still reaching for random access on a 'Text';
-- everywhere else already walks.
-- | Takes the offset to search from separately from the cursor's own
-- position, which 'reach's @MTo@ clause always passes as the same
-- thing. The two differ only for ';' and ',' repeating a @t@\/@T@: see
-- 'reachToFrom'.
toTarget :: Bool -> Bool -> Char -> Int -> Int -> Document -> Int
toTarget back short c n fromOffset d = maybe here' adjust (nth (max 1 n - 1) hits)
  where
    here'  = unOffset (cursorCol d)
    line   = currentLine d
    hits | back      = matchesBefore fromOffset line
         | otherwise = matchesAfter fromOffset line
    adjust i = if short then (if back then i + 1 else i - 1) else i
    nth k xs = case drop k xs of { x : _ -> Just x; [] -> Nothing }
    -- Positions of @c@ strictly after @from@, nearest first.
    matchesAfter from = go 0
      where
        go !i s = case Text.uncons s of
          Nothing               -> []
          Just (x, rest)
            | i > from && x == c -> i : go (i + 1) rest
            | otherwise           -> go (i + 1) rest
    -- Positions of @c@ strictly before @upto@, nearest first -- which
    -- is the /end/ of a left-to-right walk, so the accumulator is built
    -- forwards and only the final list is reversed, once.
    matchesBefore upto = reverse . go 0
      where
        go !i s
          | i >= upto = []
          | otherwise = case Text.uncons s of
              Nothing            -> []
              Just (x, rest)
                | x == c    -> i : go (i + 1) rest
                | otherwise -> go (i + 1) rest

-- | Where a /repeated/ @f@\/@t@\/@F@\/@T@ lands, searching from an
-- explicit offset rather than the cursor's own position, with the
-- resulting displacement still measured from the real cursor (via
-- 'toward', which reads it from @d@ independently of @fromOffset@).
--
-- This exists for ';' and ',', and specifically for the half of it that
-- is not simply "do the same motion again": repeating a @t@\/@T@ that
-- already stopped one character short of its target must search from
-- one step /further/ in the direction of travel, or it immediately
-- re-finds the target it is already sitting beside and never moves --
-- vim's well-known stuck-on-repeated-@t@ behaviour. @f@\/@F@ need no
-- such nudge, since they land exactly on their target and a fresh
-- search from there already starts beyond it.
reachToFrom :: Unicode -> Bool -> Bool -> Char -> Int -> Int -> Document -> Reach
reachToFrom u back short c n fromOffset d = toward u d (toTarget back short c n fromOffset d)

-- | @W@ and @B@: words delimited by whitespace alone, so punctuation
-- does not break them. One rule, read forwards or backwards.
--
-- Threads the boundary list the same way 'forwardTarget'\/'backwardTarget'
-- do, for the same reason: the earlier fix here (computing @bounds@
-- once) removed the ICU re-segmentation from the loop but left
-- 'ceilAt'\/'floorAt' rescanning that list from the front every step,
-- which is still quadratic in the number of word transitions, just
-- with a smaller constant.
bigWordTarget :: Unicode -> Bool -> Int -> Document -> Int
bigWordTarget u back n d = go (max 1 n) (unOffset (cursorCol d)) initial
  where
    line    = currentLine d
    bounds  = clusters u line
    initial = if back then reverse bounds else bounds
    go k !o bs
      | k <= 0    = o
      | o' == o   = o
      | otherwise = go (k - 1) o' bs'
      where (bs', o') = if back then floorRetreat bs (backOne o) else ceilAdvance bs (fwdOne o)
    fwdOne o = let rest    = Text.drop o line
                   word    = Text.takeWhile (not . blank) rest
                   gap     = Text.takeWhile blank (Text.drop (Text.length word) rest)
               in o + Text.length word + Text.length gap
    backOne o = let before' = Text.take o line
                    gap     = Text.takeWhileEnd blank before'
                    word    = Text.takeWhileEnd (not . blank) (Text.dropEnd (Text.length gap) before')
                in o - Text.length gap - Text.length word
    blank = (== Blank) . classify

-- | @{@ and @}@: to the nearest blank row in that direction, or to the
-- edge of the document if there is none. Returns a signed row
-- displacement, so it composes with every linewise operator unchanged.
--
-- Guarded by the same fixed-point rule 'forwardTarget' and
-- 'backwardTarget' use, and for the reason stated there: a step that
-- cannot advance must stop the count early, or a huge count -- however
-- it arrived, typed or generated -- recurses that many times before
-- noticing there was nowhere left to go. This function shipped without
-- the guard and a Hedgehog session test hung outright on a generated
-- count in the quintillions; every other counted motion in this module
-- already had the protection this one was missing.
--
-- 'rowOf' reads a single row with 'Seq.lookup' rather than materialising
-- the document with 'window', which was doing that conversion inside
-- the loop -- an @O(document)@ allocation on every iteration, compounding
-- the missing fixed point into something far worse than either defect
-- alone.
paragraphStep :: Bool -> Int -> Document -> Int
paragraphStep back n d = go (max 1 n) 0
  where
    total = lineCount d
    row   = cursorRow d
    ls    = lines' d
    go k acc
      | k <= 0     = acc
      | delta == 0 = acc
      | otherwise  = go (k - 1) (acc + delta)
      where delta = hop' (row + acc)
    hop' from = case filter interesting candidates of
      t : _ -> t - from
      []    -> (if back then 0 else total - 1) - from
      where candidates = if back then [from - 1, from - 2 .. 0] else [from + 1 .. total - 1]
    interesting r = maybe False (Text.all ((== Blank) . classify)) (rowOf r)
    rowOf r = Seq.lookup r ls

-- | @%@: the partner of the first bracket at or after the cursor on
-- this row, searched with a depth counter over the whole document so
-- that nesting across lines is handled.
matchBracket :: Document -> Maybe (Int, Int)
matchBracket d = do
  (o, c) <- opener
  partner <- lookup c pairs
  scan (forwards c) (o, c) partner
  where
    line   = currentLine d
    here'  = unOffset (cursorCol d)
    pairs  = [('(', ')'), ('[', ']'), ('{', '}'), (')', '('), (']', '['), ('}', '{')]
    opener = case [ (i, Text.index line i) | i <- [here' .. Text.length line - 1]
                  , Text.index line i `elem` map fst pairs ] of
      x : _ -> Just x
      []    -> Nothing
    forwards :: Char -> Bool
    forwards c = c `elem` ['(', '[', '{']
    scan fwd (o, c) partner = seek (0 :: Int) (positions fwd (cursorRow d, o))
      where
        seek _ [] = Nothing
        seek depth ((r, i) : rest) = case charAt r i of
          Just x | x == c && (r, i) /= (cursorRow d, o) -> seek (depth + 1) rest
                 | x == c                               -> seek depth rest
                 | x == partner                         -> if depth == 0 then Just (r, i) else seek (depth - 1) rest
          _ -> seek depth rest
    positions fwd (r0, o0) =
      let rows' = if fwd then [r0 .. lineCount d - 1] else [r0, r0 - 1 .. 0]
      in concatMap (\r -> let w = rowText r
                              is = if fwd then [if r == r0 then o0 else 0 .. Text.length w - 1]
                                          else [(if r == r0 then o0 else Text.length w - 1), (if r == r0 then o0 else Text.length w - 1) - 1 .. 0]
                          in map ((,) r) is) rows'
    rowText r = case drop r (window 0 (lineCount d) d) of { x : _ -> x; [] -> Text.empty }
    charAt r i = let w = rowText r in if i >= 0 && i < Text.length w then Just (Text.index w i) else Nothing

-- | A bracket with no partner leaves the cursor where it is.
orStay :: Reach -> Unicode -> Reach
orStay r _ = r

-- | Every position in the document where @pat@ occurs, in order.
-- Overlapping matches count, as they do in vim.
occurrences :: Text -> Seq Text -> [(Int, Int)]
occurrences pat ls
  | Text.null pat = []
  | otherwise     = concat (zipWith inRow [0 ..] (toList ls))
  where
    inRow r = map ((,) r) . scan 0
    scan !base t = case Text.breakOn pat t of
      (before', rest)
        | Text.null rest -> []
        | otherwise      -> let i = base + Text.length before'
                            in i : scan (i + 1) (Text.drop (Text.length before' + 1) t)

-- | The @n@th match from the cursor, wrapping at the end of the
-- document as vim does. 'Nothing' when the pattern is empty or absent,
-- which 'reach' turns into a motion that goes nowhere -- a failed
-- search must not move the cursor.
findNth :: Bool -> Int -> Text -> Document -> Maybe (Int, Int)
findNth back n pat d = at (max 1 n - 1) ordered
  where
    here'   = (cursorRow d, unOffset (cursorCol d))
    found   = occurrences pat (lines' d)
    ahead   = filter (> here') found
    behind  = filter (< here') found
    -- Wrapping is why the two halves are concatenated rather than one
    -- being searched and the other reported as a failure.
    ordered = if back then reverse behind <> reverse ahead else ahead <> behind
    at k xs
      | null xs   = Nothing
      | otherwise = case drop (k `mod` length xs) xs of
          x : _ -> Just x
          []    -> Nothing

-- | Cut the reach out of the document, returning what is left and exactly
-- the text removed. 'Nothing' iff nothing would change -- the single
-- source of truth for "was this a no-op", relied on by
-- 'Basilisk.Step.commit' instead of an @O(document)@ equality test.
excise :: Reach -> Document -> Maybe (Document, Text)
excise (Chars n) d = fmap (first (\ln -> d { here = ln })) (cut n (here d))
excise (Upto r o) d
  | lo == hi  = Nothing
  | otherwise = Just (focusAt (const (Offset (snd lo))) (fst lo) (pre >< (kept <| post)), joinRows cut')
  where
    ls        = lines' d
    rowAt i   = fromMaybe Text.empty (Seq.lookup i ls)
    clampTo i = max 0 . min (Text.length (rowAt i))
    row       = max 0 (min r (Seq.length ls - 1))
    here'     = (cursorRow d, unOffset (cursorCol d))
    there     = (row, clampTo row o)
    (lo, hi)  = if here' <= there then (here', there) else (there, here')
    (pre, rest) = Seq.splitAt (fst lo) ls
    (grp, post) = Seq.splitAt (fst hi - fst lo + 1) rest
    firstRow  = fromMaybe Text.empty (Seq.lookup 0 grp)
    lastRow   = fromMaybe Text.empty (Seq.lookup (Seq.length grp - 1) grp)
    -- The partial first row and partial last row become one row; the
    -- rows between them disappear entirely. This is the whole of what
    -- 'Chars' could not express.
    kept      = Text.take (snd lo) firstRow <> Text.drop (snd hi) lastRow
    cut'
      | fst lo == fst hi = Seq.singleton (Text.take (snd hi - snd lo) (Text.drop (snd lo) firstRow))
      | otherwise        = (Text.drop (snd lo) firstRow <| Seq.drop 1 (Seq.take (Seq.length grp - 1) grp))
                             |> Text.take (snd hi) lastRow

excise (Lines k) d
  | lineCount d == 1 && Text.null (currentLine d) = Nothing
  | otherwise = Just (focusAt (const 0) lo (pre >< post), joinRows gone)
  where (lo, pre, gone, post) = rows k d

-- | Replace the rows a linewise reach names with one empty row: vim's
-- @cc@, where the row survives and its contents do not.
--
-- Deliberately not @excise@ followed by opening a line. That
-- composition is wrong on an already-empty row -- it removes the row
-- and puts an identical one back, which changes nothing but still
-- bumps the version, marks the buffer modified, and makes @:q@ refuse
-- to quit a buffer nobody edited. 'Nothing' here says exactly when
-- there was nothing to clear.
clearRows :: Int -> Document -> Maybe (Document, Text)
clearRows k d
  | Seq.length gone == 1 && all Text.null gone = Nothing
  | otherwise = Just (focusAt (const 0) lo (pre >< (Text.empty <| post)), joinRows gone)
  where (lo, pre, gone, post) = rows k d

-- | The rows a linewise reach of @k@ names, clamped to the document:
-- the first of them, what precedes, what they are, and what follows.
-- Shared by every linewise operator, so none of them re-derives the
-- clamping.
rows :: Int -> Document -> (Int, Seq Text, Seq Text, Seq Text)
rows k d = (lo, pre, gone, post)
  where
    ls           = lines' d
    r            = cursorRow d
    lo           = max 0 (min r (r + k))
    hi           = min (Seq.length ls - 1) (max r (r + k))
    (pre, rest)  = Seq.splitAt lo ls
    (gone, post) = Seq.splitAt (hi - lo + 1) rest

joinRows :: Seq Text -> Text
joinRows = Text.intercalate (Text.singleton '\n') . toList

-- | Cut a signed character span out of a line. Both halves clamp, so the
-- result is defined for every @n@; an empty cut is 'Nothing'.
cut :: Int -> LineZ -> Maybe (LineZ, Text)
cut n (LineZ b a) = nonEmpty $ case compare n 0 of
  GT -> first (LineZ b)           (swap (Text.splitAt n a))
  LT -> first (flip LineZ a)      (Text.splitAt (Text.length b + n) b)
  EQ -> (LineZ b a, Text.empty)
  where
    swap (x, y)        = (y, x)
    nonEmpty r@(_, t)  = if Text.null t then Nothing else Just r

-- | Rewrite the characters a signed charwise span covers with @f@,
-- leaving the cursor just past the span -- vim's convention for
-- @~@\/@gu@\/@gU@\/@g~@, and deliberately not 'cut's convention of
-- leaving the split point at whichever side already borders it. For a
-- forward span the transformed text joins @before@, so the cursor
-- sits past it; for a backward span it joins @after@, so the cursor
-- sits at the span's near (leftward) edge -- the far end in the
-- direction the motion travelled, which is the same rule stated once.
-- | 'Nothing' iff @f@ makes no visible difference to the span --
-- toggling the case of a digit, or of any span with no letters in it
-- -- not merely iff the span is empty. The empty-span and the
-- unchanged-span cases look similar (both "nothing to report") but are
-- not the same check, and conflating them once let @~@ on a digit
-- silently bump the version and create an undo entry for an edit that
-- changed no byte of the document.
transformLineZ :: (Text -> Text) -> Int -> LineZ -> Maybe (LineZ, Text)
transformLineZ f n (LineZ b a) = case compare n 0 of
  GT -> let (spanned, rest) = Text.splitAt n a                   in build spanned (\fx -> LineZ (b <> fx) rest)
  LT -> let (rest, spanned) = Text.splitAt (Text.length b + n) b in build spanned (\fx -> LineZ rest (fx <> a))
  EQ -> Nothing
  where
    build spanned mk
      | Text.null spanned || fx == spanned = Nothing
      | otherwise                          = Just (mk fx, spanned)
      where fx = f spanned

-- | Rewrite every row a linewise reach spans with @f@, applied to each
-- row's full text. Shared by the linewise case operators (@guu@\/
-- @gUU@\/@g~~@) and by indent\/dedent, which pass a row-prepending or
-- row-trimming @f@ instead of a case-changing one. 'Nothing' iff @f@
-- changes none of the affected rows -- toggling the case of a line with
-- no letters, or dedenting a line with no leading whitespace to remove.
transformRows :: (Text -> Text) -> Int -> Document -> Maybe (Document, Text)
transformRows f k d
  | new == old = Nothing
  | otherwise   = Just (focusAt (const (Offset col)) lo (pre >< Seq.fromList new >< post), joinRows gone)
  where
    (lo, pre, gone, post) = rows k d
    old = toList gone
    new = map f old
    col = case new of { r : _ -> Text.length (Text.takeWhile (== ' ') r); [] -> 0 }

-- | One level of indentation, and vim's convention for how much a
-- dedent removes: up to that many columns of leading space, never
-- more than is actually there. Four spaces, matching the Haskell
-- convention this project is for -- distinct from 'tabStop', which is
-- about how wide an existing tab character displays, not how much
-- @>>@ adds.
indentWidth :: Int
indentWidth = 4

indentRow, dedentRow :: Text -> Text
indentRow = (Text.replicate indentWidth " " <>)
dedentRow t = Text.drop (min indentWidth (Text.length (Text.takeWhile (== ' ') t))) t

-- | @Operator ∘ Motion → Transformation@, made literal. Both operators
-- are projections of the single primitive 'excise': 'Delete' keeps the
-- cut document, 'Yank' discards it and keeps the text. A third operator
-- is one more equation here and nothing else, anywhere.
operate :: Operator -> Reach -> Document -> Maybe (Document, Text)
operate Delete r d = excise r d
operate Yank   r d = fmap (first (const d)) (excise r d)
operate Change (Lines k) d = clearRows k d
operate Change r         d = excise r d
operate ToLower    r d = caseOp Text.toLower    r d
operate ToUpper    r d = caseOp Text.toUpper    r d
operate ToggleCase r d = caseOp (Text.map swapCase) r d
operate Indent r d = case toLines d r of Lines k -> transformRows indentRow k d; _ -> Nothing
operate Dedent r d = case toLines d r of Lines k -> transformRows dedentRow k d; _ -> Nothing

-- | The three case operators are one primitive, parametrised by what
-- "change the case" means: a row transform for a linewise span, a
-- charwise transform (cursor past the span) otherwise. A multi-row
-- charwise span ('Upto') is not yet handled charwise -- it is forced
-- linewise via 'toLines' instead, which changes more than the exact
-- span named but is total and correct on whole rows; exact multi-row
-- charwise case-transform is deferred, not silently wrong.
caseOp :: (Text -> Text) -> Reach -> Document -> Maybe (Document, Text)
caseOp f (Lines k)  d = transformRows f k d
caseOp f (Chars n)  d = first (\ln -> d { here = ln }) <$> transformLineZ f n (here d)
caseOp f r@(Upto {}) d = case toLines d r of Lines k -> transformRows f k d; _ -> Nothing

swapCase :: Char -> Char
swapCase c
  | Char.isUpper c = Char.toLower c
  | Char.isLower c = Char.toUpper c
  | otherwise      = c

-- edits ---------------------------------------------------------------

-- | Insert text at the cursor, splicing whole lines rather than
-- appending one character at a time.
--
-- The obvious definition -- fold the single-character primitive over
-- the text -- is quadratic, because each step copies the prefix it
-- appends to. That is invisible for a typed character and fatal for a
-- paste: a megabyte of text costs on the order of @n^2@ character
-- copies. Splitting on newlines and splicing the pieces is linear, and
-- it keeps the no-newline invariant of a 'LineZ' by construction,
-- because no piece can contain one.
--
-- 'Nothing' for empty text, so an empty insert never grows history.
insert :: Text -> Document -> Maybe Document
insert t d
  | Text.null t = Nothing
  | otherwise   = Just (splice (reverse (Text.splitOn "\n" t)))
  where
    b = before (here d)
    a = after (here d)
    -- 'Text.splitOn' never returns an empty list, but the empty case is
    -- matched rather than assumed, as everywhere else in this module.
    splice [c]        = d { here = LineZ (b <> c) a }
    splice (end : mid) = d { above = above d >< Seq.fromList (opened (reverse mid))
                           , here  = LineZ end a }
    splice []         = d
    opened (c : cs) = (b <> c) : cs
    opened []       = []

-- | How far back one @b@ motion reaches: over any blanks, then over
-- the run of whatever class precedes them.
wordBackStep :: Text -> Int
wordBackStep b = (Text.length b - Text.length trimmed) + run
  where
    trimmed = Text.dropWhileEnd ((== Blank) . classify) b
    run = case Text.unsnoc trimmed of
      Nothing     -> 0
      Just (_, c) -> Text.length (Text.takeWhileEnd ((== classify c) . classify) trimmed)

-- | How far forward one @e@ motion moves: over at least one character,
-- then over blanks, then to the /last/ character of the run that
-- follows -- not past it, because @e@ leaves the cursor on the last
-- letter of the word. Zero when there is no further word end, which
-- makes the iteration in 'forwardTarget' stop.
wordEndStep :: Text -> Int
wordEndStep a = case Text.uncons a of
  Nothing        -> 0
  Just (_, rest) -> max 0 (Text.length blanks + Text.length run)
    where
      blanks = Text.takeWhile ((== Blank) . classify) rest
      body'  = Text.drop (Text.length blanks) rest
      run    = case Text.uncons body' of
        Nothing     -> Text.empty
        Just (c, _) -> Text.takeWhile ((== classify c) . classify) body'

-- | Insert after the cursor rather than at it -- vim's @p@ against its
-- @P@. At the end of a line there is nothing to step over, so the two
-- coincide, which is also what vim does.
insertAfter :: Unicode -> Text -> Document -> Maybe Document
insertAfter u t d = insert t (shift (hop u 1 d) d)

-- | Insert whole rows above or below the cursor's row, @n@ times: the
-- linewise paste @dd@ and @yy@ call for. The cursor lands at the start
-- of the first pasted row, where vim leaves it.
--
-- Charwise paste cannot express this -- inserting a row's text at the
-- cursor joins it to whatever is already there, which is why the
-- register has to record how its contents were taken rather than just
-- what they were.
pasteRows :: Bool -> Int -> Text -> Document -> Maybe Document
pasteRows below n t d
  | n <= 0    = Nothing
  | otherwise = Just (focusAt (const 0) r (pre >< (Seq.fromList added >< post)))
  where
    r           = cursorRow d + (if below then 1 else 0)
    (pre, post) = Seq.splitAt r (lines' d)
    added       = concat (replicate n (Text.splitOn (Text.singleton '\n') t))

-- | Join @n@ rows into one (vim's @J@), separated by a single space,
-- with the indentation of every pulled-up line discarded. The cursor
-- lands at the seam, where vim leaves it. 'Nothing' on the last row,
-- since there is nothing to join to.
joinLines :: Int -> Document -> Maybe Document
joinLines n d
  | Seq.null below' = Nothing
  | otherwise       = Just (focusAt (const (Offset (Text.length lead))) r (pre >< (merged <| rest)))
  where
    below' = below d
    ls     = lines' d
    r      = cursorRow d
    pulled = max 1 (min (n - 1) (Seq.length below'))
    (pre, from)   = Seq.splitAt r ls
    (grp, rest)   = Seq.splitAt (pulled + 1) from
    pieces = toList grp
    lead   = case pieces of { x : _ -> x; [] -> Text.empty }
    merged = Text.intercalate (Text.singleton ' ')
               (lead : map Text.stripStart (drop 1 pieces))

-- | Delete the character before the cursor, merging into the line above
-- at column zero. 'Nothing' at the very start of the document.
backspace :: Unicode -> Document -> Maybe Document
backspace u d
  | not (Text.null (beforeCursor d)) =
      Just d { here = LineZ (Text.dropEnd (negate (hop u (-1) d)) (beforeCursor d)) (after (here d)) }
  | otherwise = case Seq.viewr (above d) of
      EmptyR    -> Nothing
      rest :> l -> Just d { above = rest, here = LineZ l (currentLine d) }

-- | Open a blank line at the cursor's row plus @k@ and move onto it:
-- @openLine 1@ is vim's @o@, @openLine 0@ its @O@. Total for every @k@,
-- since 'focusAt' and 'Seq.insertAt' both clamp.
-- | @R@: overwrite the grapheme cluster under the cursor with @c@,
-- advancing past it. At the end of a line there is nothing to
-- overwrite, so this extends the line instead, exactly as plain
-- insertion would. The 'Maybe Text' result is the overwritten cluster
-- when there was one -- what @R@'s own backspace restores -- and
-- 'Nothing' when this only extended the line, where backspace should
-- simply delete rather than restore something that was never there.
overwriteChar :: Unicode -> Char -> Document -> (Document, Maybe Text)
overwriteChar u c d
  | Text.null a = (d { here = LineZ (Text.snoc b c) a }, Nothing)
  | otherwise   = (d { here = LineZ (Text.snoc b c) (Text.drop n a) }, Just (Text.take n a))
  where
    b = before (here d)
    a = after (here d)
    n = case clusters u a of
          (_ : k : _) -> k
          _           -> Text.length a

-- | The mirror of 'overwriteChar': undoes exactly one typed character,
-- assuming the cursor sits immediately past it -- which is where
-- 'overwriteChar' always leaves it. Restores the original cluster if
-- there was one, or simply removes the extension if there was not.
restoreChar :: Maybe Text -> Document -> Document
restoreChar mOriginal d = d { here = LineZ (Text.dropEnd 1 b) (maybe a (<> a) mOriginal) }
  where
    b = before (here d)
    a = after (here d)

-- | @r@: replace the next @n@ characters with @c@, clamped to the
-- line, leaving the cursor on the /last/ replaced character -- vim's
-- own convention, and deliberately not @~@'s\/@gu@'s "cursor past the
-- span": @r@ is meant to chain into further edits at the point just
-- replaced, not step away from it.
--
-- 'Nothing' iff nothing would visibly change: @n <= 0@, the cursor
-- already sits at the end of the line, or the replacement happens to
-- equal every character already there (@rx@ on a span that is already
-- all @x@). That last case is not a hypothetical -- it is exactly the
-- shape of bug 'transformLineZ' had and was fixed for earlier in this
-- same pass, recurring here because this function was written only
-- after that one, by analogy, without re-asking whether the analogy
-- covered this too. It did not, until this check was added.
replaceChars :: Int -> Char -> Document -> Maybe Document
replaceChars n c d
  | n <= 0 || Text.null spanned || replaced == spanned = Nothing
  | otherwise = Just d { here = place (Offset (Text.length b + Text.length spanned - 1)) newLine }
  where
    b               = before (here d)
    (spanned, rest) = Text.splitAt n (after (here d))
    replaced        = Text.replicate (Text.length spanned) (Text.singleton c)
    newLine         = b <> replaced <> rest

openLine :: Int -> Document -> Document
openLine k d = focusAt (const 0) r (Seq.insertAt r Text.empty (lines' d))
  where r = max 0 (min (lineCount d) (cursorRow d + k))

-- | Normal mode's cursor sits ON a character, never in the gap past the
-- last one (2.5). This is the retraction onto that subspace: idempotent,
-- total, and its image is exactly the legal set. Composing it with every
-- Normal-mode transition establishes the invariant by induction, at one
-- call site rather than five.
clampGap :: Unicode -> Document -> Document
clampGap u d
  | Text.null (after (here d)) = shift (hop u (-1) d) d
  | otherwise                  = d

-- | Move the cursor forward to the nearest grapheme-cluster boundary.
--
-- Idempotent, and the identity on almost every document -- every
-- offset-producing function in this module already lands on a boundary.
-- The exception is reachable by typing: inserting a base character
-- immediately before a combining mark leaves the cursor between them,
-- because the mark now composes onto what was just typed. Snapping
-- forward puts the cursor after the cluster the user now sees.
--
-- Composed with every transition (see 'Basilisk.Step.retract') this
-- makes "the cursor is on a cluster boundary" an invariant of the whole
-- event stream, by the same induction 'clampGap' uses, rather than a
-- property each edit has to be careful not to break.
alignCursor :: Unicode -> Document -> Document
alignCursor u d = shift (ceilBoundary u (currentLine d) o - o) d
  where o = unOffset (cursorCol d)

-- | Whether the cursor sits on a grapheme-cluster boundary of its line.
-- Exported so the property suite can assert it after every transition;
-- it is the invariant 'hop' exists to maintain.
onBoundary :: Unicode -> Document -> Bool
onBoundary u d = unOffset (cursorCol d) `elem` clusters u (currentLine d)
