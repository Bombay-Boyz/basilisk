{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The laws the architecture claims, as Hedgehog properties.
--
-- Discovery is by Template Haskell: every top-level @prop_@ binding in
-- this module is collected automatically, so a property cannot be
-- written and then forgotten out of the suite.
module Main (main) where

import Control.Monad (foldM, unless)
import qualified Data.Char as Char
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Hedgehog hiding (Action, Command, Var)
import qualified Hedgehog.Gen as HG
import qualified Hedgehog.Range as Range
import System.Exit (exitFailure)

import Basilisk.Cursor (clusterBounds, displayColumn, renderable, unicode, widthAt)
import Basilisk.Decode (decode, initialKeyState)
import qualified Basilisk.Document as Doc
import Basilisk.Render (clampTop, render, scroll)
import Basilisk.Step (step)
import Basilisk.Types
import qualified Graphics.Vty as Vty

import Gen

main :: IO ()
main = do
  ok <- checkParallel $$(discover)
  unless ok exitFailure

tests :: TestLimit
tests = 400

-- invariants ------------------------------------------------------------

-- | Everything that must be true of an editor between keystrokes,
-- checked as one predicate so that every property and the sequential
-- test below assert exactly the same thing.
wellFormed :: Editor -> PropertyT IO ()
wellFormed e = do
  let d    = document e
      line = Doc.currentLine d
      col  = Doc.unOffset (Doc.cursorCol d)
  annotateShow (Doc.cursorRow d, col, line)
  assert (Doc.cursorRow d >= 0)
  assert (Doc.cursorRow d < Doc.lineCount d)
  assert (col >= 0 && col <= Text.length line)
  -- the cursor never sits inside a grapheme cluster
  assert (Doc.onBoundary unicode d)
  -- no line ever acquires a newline inside it
  assert (not (Text.any (== '\n') line))
  assert (top e >= 0)
  case mode e of
    Normal    -> assert (Text.null line || col < Text.length line)
    Insert _  -> pure ()
    Replace _ -> pure ()
    Prompt {} -> pure ()

-- the pure core -----------------------------------------------------------

prop_step_preserves_wellformedness :: Property
prop_step_preserves_wellformedness = withTests tests . property $ do
  (a, e) <- forAll genMatched
  wellFormed (fst (step a e))

-- | The strongest statement the suite makes: a whole session, not one
-- keystroke. Every invariant holds after every action in a random
-- sequence, which is where interactions between actions show up --
-- entering insert mode, editing, undoing across the mode change, and
-- so on. Hedgehog shrinks the sequence, so a failure arrives as the
-- shortest run that still breaks.
prop_sessions_preserve_wellformedness :: Property
prop_sessions_preserve_wellformedness = withTests tests . property $ do
  e0 <- forAll genEditor
  n  <- forAll (HG.int (Range.linear 1 25))
  let stepOnce e _ = do
        a <- forAll (genActionFor (mode e))
        let e' = fst (step a e)
        wellFormed e'
        pure e'
  _ <- foldM stepOnce e0 [1 .. n]
  pure ()

-- | A prompt command with no prompt open does nothing. "Nothing" is
-- semantic rather than structural: 'step' still normalises the cursor
-- on the way out, as it does for every transition, so the law is that
-- no content, mode, history or effect changes.
prop_no_wildcard_is_needed_for_mismatched_prompt :: Property
prop_no_wildcard_is_needed_for_mismatched_prompt = withTests tests . property $ do
  c <- forAll (HG.element [PBackspace, PSubmit, PEscape])
  e <- forAll genEditor
  let e0       = e { mode = Normal }
      (e1, fx) = step (InPrompt c) e0
  fx === []
  mode e1 === mode e0
  version e1 === version e0
  history e1 === history e0
  Doc.toText (document e1) === Doc.toText (document e0)

-- | The single property that, across every command and mode
-- 'genMatched' can produce, encodes the entire "did this actually
-- change anything" rule this project has had to re-learn three
-- separate times in three separate functions (case-toggling a
-- non-letter, replacing a character with itself, overwriting one in
-- Replace mode) -- each in a /different/ primitive that happened not
-- to check, found only when this property's own random search reached
-- it. Given 10x the test count every other property gets: it is pure
-- and cheap to run, and it is the one law most worth distrusting a
-- single green run of.
prop_version_tracks_content_exactly :: Property
prop_version_tracks_content_exactly = withTests (tests * 10) . property $ do
  (a, e0) <- forAll genMatched
  let e1      = fst (step a e0)
      changed = Doc.toText (document e1) /= Doc.toText (document e0)
  if changed then version e1 === version e0 + 1 else version e1 === version e0

prop_declined_edit_leaves_history :: Property
prop_declined_edit_leaves_history = withTests tests . property $ do
  (a, e0) <- forAll genMatched
  let e1 = fst (step a e0)
  unless (version e1 /= version e0) (history e1 === history e0)

prop_counted_displacement_equals_iteration :: Property
prop_counted_displacement_equals_iteration = withTests tests . property $ do
  -- MLine's count is inclusive rather than repeated, MGotoLine's names
  -- an absolute row, and neither MFind nor MTo is a displacement in the
  -- iterate-equals-count sense: a failed search leaves the cursor
  -- exactly where it already is, which is the position a /successful/
  -- earlier step left it at, not the position the whole motion started
  -- from. Iterating "move, then fail" and jumping straight to "fail"
  -- from the start can therefore land in genuinely different places --
  -- found directly by this property, on @f_@ against a document with
  -- only one @_@: one `f_` succeeds, landing on it; a second `f_` then
  -- fails and stays there; but `2f_` in one step fails immediately,
  -- from the original position, because there was never a second
  -- occurrence to find.
  m <- forAll (HG.filter (\x -> x `notElem` [MLine, MGotoLine, MMatch, MColumn, MParagraph False, MParagraph True]
                              && not (isFind x) && not (isTo x)) genMotion)
  k <- forAll (HG.int (Range.linear 1 6))
  d <- forAll genDocument
  let e0     = withDocument d (newEditor Nothing "")
      jump n = fst . step (InNormal (NMove n m))
  document (iterate (jump 1) e0 !! k) === document (jump k e0)

prop_counted_linewise_delete_removes_that_many_rows :: Property
prop_counted_linewise_delete_removes_that_many_rows = withTests tests . property $ do
  k <- forAll (HG.int (Range.linear 1 8))
  d <- forAll genDocument
  let e1  = fst (step (InNormal (NOperate k Delete MLine)) (withDocument d (newEditor Nothing "")))
      len = Doc.lineCount d
      r   = Doc.cursorRow d
  Doc.lineCount (document e1) === max 1 (len - min k (len - r))

prop_undo_then_redo_restores_content :: Property
prop_undo_then_redo_restores_content = withTests tests . property $ do
  d  <- forAll genDocument
  cs <- forAll (HG.list (Range.linear 1 6) genChar)
  k  <- forAll (HG.int (Range.linear 1 4))
  let start = withDocument d ((newEditor Nothing "") { mode = Insert Fresh })
      typedIn = foldl (\e c -> fst (step (InInsert (IInput (Text.singleton c))) e)) start cs
      back    = fst (step (InNormal (NUndo k)) typedIn { mode = Normal })
      forth   = fst (step (InNormal (NRedo k)) back)
  Doc.toText (document forth) === Doc.toText (document typedIn)

prop_yank_never_changes_the_document :: Property
prop_yank_never_changes_the_document = withTests tests . property $ do
  m <- forAll genMotion
  k <- forAll (HG.int (Range.linear 0 4))
  d <- forAll genDocument
  let e0 = withDocument d (newEditor Nothing "")
      e1 = fst (step (InNormal (NOperate k Yank m)) e0)
  Doc.toText (document e1) === Doc.toText (document e0)

-- | The span an operator acts on is @extend . reach@ -- the motion's
-- own reach, plus the cluster an inclusive motion stops on -- forced to
-- linewise first when the operator requires it. That last step matters:
-- without it this oracle disagrees with what 'Basilisk.Step.normal's
-- own 'NOperate' clause actually computes for @>@\/@<@ given a charwise
-- motion, since that clause applies the same conversion before calling
-- 'Doc.operate'.
operatorSpan :: Operator -> Int -> Motion -> Doc.Document -> Doc.Reach
operatorSpan o n m d = force (Doc.extend unicode m (Doc.reach unicode n m d) d)
  where force r = if Doc.forcedLinewise o then Doc.toLines d r else r

-- | Restricted to the three operators that actually touch the
-- register: case and indent operators transform in place and leave it
-- alone, matching vim's own rule, which 'Basilisk.Step.apply' encodes
-- directly rather than as something every operator must satisfy.
prop_reached_span_becomes_the_register :: Property
prop_reached_span_becomes_the_register = withTests tests . property $ do
  o <- forAll (HG.element [Delete, Yank, Change])
  m <- forAll genMotion
  n <- forAll (HG.int (Range.linear 1 4))
  d <- forAll genDocument
  let e1 = fst (step (InNormal (NOperate n o m)) (withDocument d (newEditor Nothing "")))
  case Doc.operate o (operatorSpan o n m d) d of
    Nothing     -> success
    Just (_, t) -> fmap clipText (register e1) === Just t

-- | An inclusive operator span covers strictly more than the bare
-- motion, and the difference is whole clusters -- never a codepoint,
-- which would split a combining sequence off its base.
prop_inclusive_operators_cover_the_landing_cluster :: Property
prop_inclusive_operators_cover_the_landing_cluster = withTests tests . property $ do
  m <- forAll (HG.filter Doc.inclusive genMotion)
  n <- forAll (HG.int (Range.linear 1 4))
  d <- forAll genDocument
  case (Doc.reach unicode n m d, operatorSpan Delete n m d) of
    (Doc.Chars a, Doc.Chars b) -> do
      assert (b >= a)
      let o = Doc.unOffset (Doc.cursorCol d)
      assert ((o + b) `elem` clusterBounds (Doc.currentLine d))
    _ -> success

-- | Quitting goes through one channel, and that channel refuses to
-- discard unsaved work unless it was told to. This is the law that
-- makes the editor safe to leave a file in.
prop_quit_never_silently_discards_work :: Property
prop_quit_never_silently_discards_work = withTests tests . property $ do
  e0 <- forAll genEditor
  let e = e0 { mode = Prompt ExCommand "q" }
      quitted c = snd (step (InPrompt PSubmit) e { mode = Prompt ExCommand c }) == [RequestQuit]
  quitted "q" === not (modified e)
  quitted "q!" === True

-- | A write is the only thing that makes a buffer clean, and it does so
-- only once the shell reports the bytes are on disk -- 'step' alone
-- never clears the flag, because 'step' cannot know whether the write
-- succeeded.
prop_only_a_completed_write_cleans_the_buffer :: Property
prop_only_a_completed_write_cleans_the_buffer = withTests tests . property $ do
  (a, e0) <- forAll genMatched
  let e1 = fst (step a e0)
  assert (saved e1 == saved e0)

-- | A write effect carries exactly the bytes 'serialise' produces --
-- line endings and the trailing terminator included -- so nothing
-- downstream re-derives them and the two can never disagree.
prop_write_effect_carries_exactly_the_file_bytes :: Property
prop_write_effect_carries_exactly_the_file_bytes = withTests tests . property $ do
  e0 <- forAll genEditor
  let e = e0 { mode = Normal }
  snd (step (InNormal NSave) e)
    === maybe [] (\p -> [WriteFile p (serialise e) False]) (path e)

-- counts --------------------------------------------------------------------

-- | Vim accumulated counts into a machine integer without a bound until
-- 2023; CVE-2023-48233 to -48236 are four separate overflows in four
-- separate count parsers. Whatever digits arrive, the count that leaves
-- the decoder is in range.
prop_counts_saturate_rather_than_overflow :: Property
prop_counts_saturate_rather_than_overflow = withTests tests . property $ do
  digits <- forAll (HG.list (Range.linear 1 40) (HG.element ("123456789" :: String)))
  tailk  <- forAll (HG.element ("jlwdx" :: String))
  let keys = map (\c -> Vty.EvKey (Vty.KChar c) []) (digits ++ [tailk])
      run _  [] = []
      run st (ev : evs) = case decode Normal st ev of
        (st', Nothing) -> run st' evs
        (st', Just a)  -> a : run st' evs
  for_' (run initialKeyState keys) $ \a -> do
    annotateShow a
    assert (all inRange (countsOf a))
  where
    inRange n = n >= 0 && n <= maxCount
    for_' xs f = mapM_ f xs

countsOf :: Action -> [Int]
countsOf (InNormal c) = case c of
  NMove n _      -> [n]
  NOperate n _ _ -> [n]
  NPaste n _     -> [n]
  NJoin n        -> [n]
  NUndo n        -> [n]
  NRedo n        -> [n]
  _              -> []
countsOf _ = []

-- | A count arriving from anywhere -- including a hand-built 'Action'
-- that never went through the decoder -- must not be able to allocate
-- without bound. The paste handler is the only place a count multiplies
-- data rather than clamping against the document.
prop_absurd_paste_count_is_bounded :: Property
prop_absurd_paste_count_is_bounded = withTests 20 . property $ do
  d <- forAll genDocument
  let e0 = withDocument d ((newEditor Nothing "") { register = Just (Clip False "x") })
      e1 = fst (step (InNormal (NPaste maxBound True)) e0)
  assert (Text.length (Doc.toText (document e1)) <= Text.length (Doc.toText (document e0)) + maxCount)

-- | Unbounded undo history is a slow leak. Whatever is typed, the
-- stack stays within its limit.
prop_undo_history_is_bounded :: Property
prop_undo_history_is_bounded = withTests 40 . property $ do
  cs <- forAll (HG.list (Range.linear 0 40) genChar)
  let typed = foldl (\e c -> fst (step (InInsert (IInput (Text.singleton c))) e))
                    ((newEditor Nothing "") { mode = Insert Fresh })
                    cs
      moved = foldl (\e c -> fst (step (InInsert (IMove DLeft)) (fst (step (InInsert (IInput (Text.singleton c))) e))))
                    typed cs
  assert (length (past (history moved)) <= undoLimit)

-- | A read-only buffer refuses to produce a write at all, so the
-- refusal happens before any IO rather than as a failure afterwards.
prop_readonly_refuses_to_write :: Property
prop_readonly_refuses_to_write = withTests tests . property $ do
  e0 <- forAll genEditor
  let e = onBuffer (\b -> b { bReadOnly = True, bPath = Just "x" }) e0 { mode = Normal }
  snd (step (InNormal NSave) e) === []
  snd (step (InPrompt PSubmit) e { mode = Prompt ExCommand "w!" }) === [WriteFile "x" (serialise e) True]

-- | A buffer born empty and still empty writes no bytes -- not a lone
-- terminator. A zero-byte file and a one-byte @"\n"@ file both load as
-- one empty row, and this is what keeps them distinguishable.
prop_empty_new_buffer_writes_nothing :: Property
prop_empty_new_buffer_writes_nothing = withTests tests . property $ do
  el <- forAll (HG.element [LF, CRLF, CR])
  fe <- forAll HG.bool
  serialise (onBuffer (\b -> b { bEol = el, bFinalEol = fe, bBornEmpty = True }) (newEditor Nothing "")) === ""
  serialise (onBuffer (\b -> b { bEol = el, bFinalEol = True, bBornEmpty = False }) (newEditor Nothing ""))
    === encodeEol el "\n"

-- | A charwise span across rows cuts exactly the text between the two
-- positions: the tail of the first row, the rows between, and the head
-- of the last. This is the shape 'Chars' cannot express, and the one a
-- selection will reuse.
prop_upto_cuts_exactly_the_span :: Property
prop_upto_cuts_exactly_the_span = withTests tests . property $ do
  d <- forAll genDocument
  r <- forAll (HG.int (Range.linear 0 8))
  o <- forAll (HG.int (Range.linear 0 30))
  case Doc.operate Delete (Doc.Upto r o) d of
    Nothing         -> success
    Just (d', gone) -> do
      -- Nothing is invented and nothing is lost: what remains plus what
      -- was cut is the original, once the seam is accounted for.
      annotateShow (Doc.toText d, Doc.toText d', gone)
      assert (Text.length (Doc.toText d') + Text.length gone == Text.length (Doc.toText d))
      assert (Doc.lineCount d' <= Doc.lineCount d)

-- | A search lands on the row of some occurrence, and an absent
-- pattern does not move the cursor at all.
--
-- Deliberately stated on the row rather than the exact offset. A match
-- can begin inside a grapheme cluster -- searching for a zero-width
-- joiner that is part of a larger cluster, say -- and the cursor
-- invariant forbids sitting there, so the offset is snapped to the
-- enclosing boundary. Claiming the cursor is exactly at the match
-- would be claiming the invariant does not hold.
prop_search_lands_on_the_row_of_a_match :: Property
prop_search_lands_on_the_row_of_a_match = withTests tests . property $ do
  d   <- forAll genDocument
  pat <- forAll (HG.text (Range.linear 0 3) genChar)
  let e0    = withDocument d (newEditor Nothing "")
      e1    = fst (step (InPrompt PSubmit) e0 { mode = Prompt Search pat })
      d1    = document e1
      rowsWith = [ r | (r, ln) <- zip [0 :: Int ..] (Doc.window 0 maxBound d), pat `Text.isInfixOf` ln ]
  if Text.null pat || null rowsWith
    then do
      Doc.toText (document e1) === Doc.toText d
      Doc.cursorRow d1 === Doc.cursorRow d
    else assert (Doc.cursorRow d1 `elem` rowsWith)

-- | What genuinely holds for @f@\/@t@\/@F@\/@T@, in place of the
-- iterate-equals-count law that does not: a search that succeeds lands
-- the cursor on a grapheme-cluster boundary, and a search that fails
-- -- because the count asks for more occurrences than the line has --
-- leaves the document completely unchanged, never a partial move.
-- | @^@ and @|@ compute an absolute target independent of the cursor's
-- current position, so pressing either twice in a row must land in
-- exactly the same place the second time as the first -- real vim's
-- own behaviour, and the property an earlier, position-relative snap
-- direction violated on a line with a combining mark straddling the
-- blank\/non-blank boundary: landing on one side of the raw target and
-- then re-invoking the same motion compared that target against a
-- now-different cursor and snapped the other way, oscillating between
-- two boundaries rather than staying put.
-- | @r@ replacing a span with a character that already matches every
-- character in it is a true no-op: the document is byte-identical and
-- the version does not move. The same bug class as case-toggling a
-- non-letter (2.10f), recurring here because this function was written
-- afterward, by analogy, without re-asking whether the analogy
-- actually covered this case. It did not, until this check existed.
--
-- @d@ is clamped with 'Doc.clampGap' before use, matching what any
-- real Normal-mode editor state already satisfies by the time a
-- command runs: 'genDocument' has no notion of mode and can place the
-- cursor in the gap past the last character, which is invalid only in
-- Normal mode and which 'step's own 'retract' always repairs on the
-- way out regardless of what the dispatched action did. Comparing an
-- un-clamped @e0@ against a necessarily-retracted @e1@ would make this
-- property fail on exactly that gap repair, not on anything 'NReplace'
-- did.
-- | A counted insert's final document is exactly what typing the
-- whole repeated text in a single, uncounted session would produce:
-- @3ifoo\<Esc\>@ ends up identical to typing @foofoofoo@ directly.
-- This is the comparison that cannot encode the same mistake the
-- implementation might: typing the already-concatenated text is a
-- second, independent code path ('typed's ordinary accumulation), not
-- a re-derivation of 'insertRepeat's own expansion.
-- | A character with no special clustering behaviour of any kind --
-- neither zero-width attachment to a neighbour nor pairing into a
-- cluster with another instance of itself, as regional indicators do.
-- Narrower restrictions tried first -- excluding only zero-width
-- characters immediately beside the cursor, then anywhere on the line
-- -- each closed one specific shape of the same underlying class and
-- Hedgehog's shrinker kept finding the next one (a dangling combining
-- mark adjacent to the cursor; one several characters away on a line
-- with a tab; a pair of regional indicators, individually full-width,
-- that cluster only when they meet). Rather than continue enumerating
-- categories, this property generates from a deliberately plain
-- alphabet instead: Unicode clustering interactions are already
-- exhaustively exercised by the properties in 2.10a, and are not what
-- this property is about.
genPlainChar :: Gen Char
genPlainChar = HG.element ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;()[]{}-_" :: String)

prop_counted_insert_matches_typing_the_repetition_directly :: Property
prop_counted_insert_matches_typing_the_repetition_directly = withTests tests . property $ do
  n <- forAll (HG.int (Range.linear 1 5))
  a <- forAll (HG.element [Before, After, LineBelow, LineAbove])
  t <- forAll (HG.text (Range.linear 0 6) genPlainChar)
  body' <- forAll (Text.intercalate "\n" <$> HG.list (Range.linear 1 4) (HG.text (Range.linear 0 12) genPlainChar))
  r <- forAll (HG.int (Range.linear 0 3))
  c <- forAll (HG.int (Range.linear 0 10))
  let d = Doc.clampGap unicode (Doc.move unicode 0 (Doc.Chars c) (Doc.move unicode 0 (Doc.Lines r) (Doc.fromText body')))
  let e0 = withDocument d (newEditor Nothing "")
      typeAndEscape k tt x = fst (step (InInsert IEscape) typed)
        where
          entered = fst (step (InNormal (NEnterInsert k a)) x)
          typed   = if Text.null tt then entered else fst (step (InInsert (IInput tt)) entered)
      counted = typeAndEscape n t e0
      direct  = typeAndEscape 1 (Text.replicate n t) e0
  Doc.toText (document counted) === Doc.toText (document direct)

prop_replace_with_the_same_character_is_a_no_op :: Property
prop_replace_with_the_same_character_is_a_no_op = withTests tests . property $ do
  c  <- forAll genChar
  n  <- forAll (HG.int (Range.linear 1 6))
  d0 <- forAll genDocument
  let d       = Doc.clampGap unicode d0
      e0      = withDocument d (newEditor Nothing "")
      spanned = Text.take n (Text.drop (Doc.unOffset (Doc.cursorCol d)) (Doc.currentLine d))
      already = Text.all (== c) spanned
      e1      = fst (step (InNormal (NReplace n c)) e0)
  if already then document e1 === document e0 else success

prop_absolute_motions_are_idempotent :: Property
prop_absolute_motions_are_idempotent = withTests tests . property $ do
  m <- forAll (HG.element [MFirstNonBlank, MColumn])
  n <- forAll (HG.int (Range.linear 1 10))
  d <- forAll genDocument
  let e0 = fst (step (InNormal (NMove n m)) (withDocument d (newEditor Nothing "")))
      e1 = fst (step (InNormal (NMove n m)) e0)
  document e1 === document e0

prop_to_either_lands_on_a_boundary_or_does_not_move :: Property
prop_to_either_lands_on_a_boundary_or_does_not_move = withTests tests . property $ do
  back  <- forAll HG.bool
  short <- forAll HG.bool
  c     <- forAll genChar
  k     <- forAll (HG.int (Range.linear 1 6))
  d     <- forAll genDocument
  let e0 = withDocument d (newEditor Nothing "")
      e1 = fst (step (InNormal (NMove k (MTo back short c))) e0)
  if document e1 == d
    then success
    else assert (Doc.onBoundary unicode (document e1))

-- | ';' and ',' never get stuck. Whatever the last @f@\/@t@\/@F@\/@T@
-- was, repeating it with ';' either advances to a genuinely new
-- position or leaves the document entirely unchanged (there was
-- nowhere left to go) -- it can never silently repeat to the exact
-- position it started from while a further occurrence still exists.
-- This is the property the stuck-on-repeated-@t@ bug would have
-- violated: a wrong nudge sign made every repeated @t@ a no-op forever,
-- which this law catches without having to name the bug specifically.
-- | Restricted to characters that are visibly their own position --
-- 'widthAt' zero means a combining mark, a zero-width joiner, or a
-- format character, none of which a real keystroke delivers as a bare
-- @f@\/@t@ target in the first place: a terminal composes a combining
-- mark onto the character before it before Basilisk ever sees a key
-- event for it. Searching for one anyway is where 'matchesAfter'\/
-- 'matchesBefore' -- which scan codepoint by codepoint -- can find a
-- position that 'toward' then snaps elsewhere, which is a genuine
-- divergence from what a naive "is there another occurrence" oracle
-- would predict, not a defect in the search itself. Found twice by
-- Hedgehog shrinking to exactly this: once to a document whose
-- generated cursor sat inside such a mark's cluster (fixed in
-- 'genDocument' itself, since that violated an invariant every other
-- property also depends on), and once to a bare zero-width joiner as
-- the search target, which 'genDocument' alone cannot fix because the
-- problem is the /target character/, not the document.
-- | A character with no special clustering behaviour: not zero-width
-- (a combining mark, a format character, a joiner), and not a regional
-- indicator either. The second exclusion was missing the first time
-- this predicate was written -- 'widthAt' correctly reports a regional
-- indicator as full-width, since on its own it is, but two of them
-- adjacent to each other cluster into one flag regardless, which is a
-- *pairing* mechanism distinct from zero-width attachment and invisible
-- to a width check. Found by a second, unrelated property
-- (@prop_repeat_to_never_gets_stuck@, which predates this session's own
-- changes) failing on exactly this shape once the combined suite's test
-- volume grew enough to reach it -- not a new regression, a latent gap
-- in a predicate this session had already extended once without
-- covering every mechanism.
isAddressable :: Char -> Bool
isAddressable c = widthAt 0 c /= 0 && not isRegionalIndicator
  where isRegionalIndicator = c >= '\x1F1E6' && c <= '\x1F1FF'

prop_repeat_to_never_gets_stuck :: Property
prop_repeat_to_never_gets_stuck = withTests tests . property $ do
  back  <- forAll HG.bool
  short <- forAll HG.bool
  c     <- forAll (HG.filter isAddressable genChar)
  d     <- forAll genDocument
  let fresh  = withDocument d (newEditor Nothing "")
      e0     = fst (step (InNormal (NMove 1 (MTo back short c))) fresh)
      e1     = fst (step (InNormal (NRepeatTo 1 False)) e0)
      further = not (null (occurrencesBeyond (Doc.cursorCol (document e0)) back short c (document e0)))
  if document e0 == document fresh
    then success   -- the first f/t/F/T already found nothing; nothing to repeat
    else if further
      then assert (document e1 /= document e0)
      else document e1 === document e0
  where
    -- Whether at least one more occurrence of @c@ exists beyond where
    -- the first motion stopped, in the same direction -- probed from
    -- exactly the offset the real repeat path searches from, which is
    -- only nudged for a /short/ ('t'\/'T') motion: 'f'\/'F' land
    -- exactly on their target, so a repeat already searches beyond it
    -- unnudged. Applying the nudge unconditionally here (an earlier
    -- version of this oracle did) made the oracle disagree with the
    -- code it was checking, on exactly the 'short == False' cases --
    -- a test bug masquerading as a product one.
    occurrencesBeyond col back short c d = case Doc.reachToFrom unicode back short c 1 probeFrom d of
      Doc.Chars 0 -> [] :: [()]
      _           -> [()]
      where
        probeFrom = Doc.unOffset col + (if short then (if back then -1 else 1) else 0)

-- unicode -------------------------------------------------------------------

prop_cluster_bounds_are_a_partition :: Property
prop_cluster_bounds_are_a_partition = withTests tests . property $ do
  t <- forAll genLine
  let bs = clusterBounds t
  annotateShow bs
  head' bs === Just 0
  last' bs === Just (Text.length t)
  assert (and (zipWith (<) bs (drop 1 bs)))
  assert (all (\b -> b >= 0 && b <= Text.length t) bs)

-- | A width function that disagreed with what is drawn would put the
-- terminal cursor in the wrong column on every line containing the
-- character they disagree about.
prop_rendering_preserves_width :: Property
prop_rendering_preserves_width = withTests tests . property $ do
  t <- forAll genLine
  displayColumn (renderable t) === displayColumn t

-- | A file must not be able to drive the terminal. Nothing that reaches
-- the screen is a control character.
prop_rendering_emits_no_control_characters :: Property
prop_rendering_emits_no_control_characters = withTests tests . property $ do
  t <- forAll genLine
  assert (not (Text.any Char.isControl (renderable t)))

prop_tabs_advance_to_a_tab_stop :: Property
prop_tabs_advance_to_a_tab_stop = withTests tests . property $ do
  c <- forAll (HG.int (Range.linear 0 200))
  let w = widthAt (Doc.Column c) '\t'
  assert (w >= 1 && w <= Doc.tabStop)
  (c + w) `mod` Doc.tabStop === 0

-- | Typing a base character and pressing backspace is the identity --
-- provided the character forms its own cluster where it lands. It can
-- fail to, in both directions: a combining mark after the cursor
-- composes onto what was typed, and a zero-width joiner before the
-- cursor binds it to what precedes. Neither is a round trip; both are
-- compositions, and both are exactly what 'alignCursor' and the
-- cluster-aware backspace exist to handle. The precondition names them
-- rather than hiding behind a weaker law.
prop_type_then_backspace_is_identity :: Property
prop_type_then_backspace_is_identity = withTests tests . property $ do
  d <- forAll (HG.filter isolated genDocument)
  c <- forAll (HG.element ("abcXY1 " :: String))
  let e0 = withDocument d ((newEditor Nothing "") { mode = Insert Fresh })
      e1 = fst (step (InInsert (IInput (Text.singleton c))) e0)
      e2 = fst (step (InInsert IBackspace) e1)
  Doc.toText (document e2) === Doc.toText (document e0)
  where
    isolated d = not (joinsForward d) && not (joinsBackward d)
    joinsForward d = case Text.uncons (Text.drop (col d) (Doc.currentLine d)) of
      Just (x, _) -> widthAt 0 x == 0
      Nothing     -> False
    joinsBackward d = case Text.unsnoc (Text.take (col d) (Doc.currentLine d)) of
      Just (_, x) -> widthAt 0 x == 0
      Nothing     -> False
    col = Doc.unOffset . Doc.cursorCol

-- | Backspace removes exactly one grapheme cluster -- never one
-- codepoint, which would leave a combining mark orphaned onto whatever
-- preceded it, and never part of an emoji sequence.
prop_backspace_removes_one_cluster :: Property
prop_backspace_removes_one_cluster = withTests tests . property $ do
  d <- forAll (HG.filter (not . Text.null . Doc.beforeCursor) genDocument)
  let b        = Doc.beforeCursor d
      expected = Text.length b - lastBoundaryBefore (clusterBounds b) (Text.length b)
  case Doc.backspace unicode d of
    Nothing -> failure
    Just d' -> Text.length (Doc.toText d) - Text.length (Doc.toText d') === expected
  where
    lastBoundaryBefore bs n = foldl (\acc x -> if x < n then x else acc) 0 bs

-- files ---------------------------------------------------------------------

-- | Opening a file and saving it without editing rewrites it byte for
-- byte. Vim issues #488 and #3289 are both this property failing: the
-- trailing newline is the case everyone loses, and it is why this model
-- keeps the final empty line rather than tracking an @'endofline'@ flag.
-- | Opening a file and saving it without editing rewrites it byte for
-- byte -- including whether it ended with a terminator, which is now a
-- flag rather than a phantom final line. Vim issues #488 and #3289 are
-- both this property failing.
prop_open_then_save_is_byte_identical :: Property
prop_open_then_save_is_byte_identical = withTests tests . property $ do
  el    <- forAll (HG.element [LF, CRLF, CR])
  body  <- forAll genBody
  ended <- forAll HG.bool
  let plain  = Text.filter (/= '\r') body <> (if ended then "\n" else "")
      onDisk = encodeUtf8 (encodeEol el plain)
  case decodeUtf8' onDisk of
    Left _    -> failure
    Right raw -> do
      let text   = decodeEol el raw
          hasEol = "\n" `Text.isSuffixOf` text
          loaded = (newEditor Nothing (if hasEol then Text.dropEnd 1 text else text))
          adjust = onBuffer (\b -> b { bEol = el, bFinalEol = hasEol, bBornEmpty = Text.null text })
      encodeUtf8 (serialise (adjust loaded)) === onDisk

prop_document_round_trips :: Property
prop_document_round_trips = withTests tests . property $ do
  t <- forAll genBody
  Doc.toText (Doc.fromText t) === t

prop_eol_round_trips :: Property
prop_eol_round_trips = withTests tests . property $ do
  el <- forAll (HG.element [LF, CRLF, CR])
  t  <- forAll (Text.filter (/= '\r') <$> genBody)
  decodeEol el (encodeEol el t) === t

-- the viewport ---------------------------------------------------------------

prop_scroll_keeps_the_cursor_visible :: Property
prop_scroll_keeps_the_cursor_visible = withTests tests . property $ do
  e <- forAll genEditor
  w <- forAll (HG.int (Range.linear 1 200))
  h <- forAll (HG.int (Range.linear 1 60))
  let e' = scroll (w, h) e
      rows = max 1 (h - 1)
      r = Doc.cursorRow (document e')
  assert (top e' >= 0 && top e' <= r && r < top e' + rows)

prop_clamp_top_moves_only_when_it_must :: Property
prop_clamp_top_moves_only_when_it_must = withTests tests . property $ do
  h <- forAll (HG.int (Range.linear 1 40))
  r <- forAll (HG.int (Range.linear 0 200))
  t <- forAll (HG.int (Range.linear 0 200))
  unless (not (t <= r && r < t + h)) (clampTop h r t === t)

-- | Rendering is total for every editor and every terminal size,
-- including the degenerate ones a pty reports before a window size is
-- set. A cursor on a zero-cell display segfaults vty 6.6, so the frame
-- must not carry one.
prop_render_is_total_for_any_size :: Property
prop_render_is_total_for_any_size = withTests tests . property $ do
  e <- forAll genEditor
  w <- forAll (HG.int (Range.linear 0 120))
  h <- forAll (HG.int (Range.linear 0 40))
  let pic = render (w, h) (scroll (w, h) e)
  case Vty.picCursor pic of
    Vty.NoCursor -> assert (w * h <= 0)
    Vty.Cursor x y -> assert (x >= 0 && x < max 1 w && y >= 0 && y < max 1 h)
    _ -> success

-- the decoder ------------------------------------------------------------------

-- | The decoder is a function, so a key sequence decodes the same way
-- twice; more usefully, it never diverges and never leaves a pending
-- state that a later key cannot clear.
prop_escape_clears_any_pending_sequence :: Property
prop_escape_clears_any_pending_sequence = withTests tests . property $ do
  keys <- forAll (HG.list (Range.linear 0 8) (HG.element ("0123456789dyhjklw$x" :: String)))
  let evs = map (\c -> Vty.EvKey (Vty.KChar c) []) keys
      st  = foldl (\s ev -> fst (decode Normal s ev)) initialKeyState evs
      (_, a) = decode Normal st (Vty.EvKey (Vty.KChar 'l') [])
  case a of
    Just (InNormal (NMove n (MChar DRight))) -> assert (n >= 1 && n <= maxCount)
    Just (InNormal (NOperate n _ (MChar DRight))) -> assert (n >= 1 && n <= maxCount)
    other -> do annotateShow other; failure

head' :: [a] -> Maybe a
head' xs = case xs of { x : _ -> Just x; [] -> Nothing }

isFind :: Motion -> Bool
isFind (MFind _ _) = True
isFind _           = False

isTo :: Motion -> Bool
isTo (MTo _ _ _) = True
isTo _           = False

last' :: [a] -> Maybe a
last' = foldl (\_ x -> Just x) Nothing
