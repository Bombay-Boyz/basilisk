{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | The pure heart of the editor: one action and one state in, the
-- successor state and zero or more 'Effect's out. It performs no IO and
-- never decides to stop the program; it only describes both.
--
-- There is no catch-all clause anywhere in this module. Every dispatch
-- is exhaustive over a type whose constructors are all legal at that
-- point, so @-Werror=incomplete-patterns@ means what Invariant 2 claims:
-- adding a command is a compile error until it is handled. The one place
-- the mode and the command could still disagree is a prompt command with
-- no prompt open, and that is decided once, by 'openPrompt', which is
-- itself exhaustive over 'Mode'.
module Basilisk.Step
  ( step
  , openPrompt
  ) where

import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text

import Basilisk.Cursor (Cursor (..), syncColumn, unicode)
import qualified Basilisk.Document as Doc
import Basilisk.Types

type Step = (Editor, [Effect])

step :: Action -> Editor -> Step
step a = first (retract . remember a) . dispatch a
  where
    dispatch (InNormal c) = normal c
    dispatch (InInsert c) = insertMode c
    dispatch (InPrompt c) = promptMode c

-- | Record what @.@ should repeat.
--
-- Vim repeats the last /change/, and a change that entered Insert mode
-- includes the text that was typed: after @cwfoo\<Esc\>@, @.@ must
-- change the next word to @foo@, not merely delete it and sit in
-- Insert mode. So the session's text is accumulated as it is typed and
-- attached when Escape ends it.
--
-- Recording happens here, at one call site, for the same reason the
-- cursor normalisation does: a per-handler rule is one that eventually
-- gets forgotten. 'repeatable' names the set exhaustively, so a new
-- command must declare which side it is on before it compiles -- a
-- motion, an undo or a save becoming the thing @.@ does would make the
-- key useless.
remember :: Action -> Editor -> Editor
remember (InNormal c) e
  | repeatable c = e' { lastEdit = Just (c, Text.empty), typing = Text.empty }
  | otherwise    = e'
  where
    -- ';' and ',' also need to remember "what was the last f/t/F/T",
    -- which is a different question from "what was the last change".
    -- A fresh find-char motion sets it; ';'/',' only ever replay it,
    -- so 'NRepeatTo' is deliberately not one of the cases below.
    e' = case toMotion c of
      Just m@(MTo _ _ _) -> e { lastTo = Just m }
      _                  -> e
    toMotion (NMove _ m)      = Just m
    toMotion (NOperate _ _ m) = Just m
    toMotion _                = Nothing
remember (InInsert (IInput t)) e = e { typing = typing e <> t }
remember (InInsert IBackspace) e = e { typing = Text.dropEnd 1 (typing e) }
remember (InInsert IEscape)    e = e { lastEdit = fmap (fmap (const (typing e))) (lastEdit e) }
remember (InInsert (IMove _))  e = e
remember (InPrompt _) e = e

repeatable :: NormalCmd -> Bool
repeatable (NOperate _ _ _) = True
repeatable (NPaste _ _)     = True
repeatable (NPasteText _)   = True
repeatable (NJoin _)        = True
repeatable (NMove _ _)      = False
repeatable (NEnterInsert _ _) = True
repeatable NEnterReplace       = False  -- @R@ is not replayed by '.': no overwrite-based repeat mechanism exists yet
repeatable (NEnterPrompt _) = False
repeatable (NRepeat _)      = False   -- repeating a repeat would lose the original
repeatable (NRepeatFind _ _) = False
repeatable (NRepeatTo _ _)   = False
repeatable (NReplace _ _)    = True
repeatable NWriteQuit        = False
repeatable NQuitDiscard      = False
repeatable (NUndo _)        = False
repeatable (NRedo _)        = False
repeatable NSave            = False

-- Normal mode --------------------------------------------------------

normal :: NormalCmd -> Editor -> Step
normal (NMove k m)      e = pureT (moveBy (Doc.reach unicode k m (document e)) e)
-- | @>@\/@<@ are forced to linewise regardless of the motion they are
-- given -- vim's own rule, checked once here via 'Doc.forcedLinewise'
-- rather than duplicated at every call site that could otherwise forget
-- it.
normal (NOperate k o m) e = pureT (apply o (force (spanOf k m (document e)) (document e)) e)
  where
    spanOf n mo d = Doc.extend unicode mo (Doc.reach unicode n mo d) d
    force r d = if Doc.forcedLinewise o then Doc.toLines d r else r
normal (NEnterInsert n a) e = pureT (enter n a e)
normal NEnterReplace    e = pureT e { mode = Replace [] }
normal (NEnterPrompt k) e = pureT e { mode = Prompt k Text.empty }
-- | Paste's count is bounded on the product of count and register
-- length, not the count alone -- see 'boundedRepeatCount'. A plain
-- 'bounded' would let a modest count multiply a long register, or a
-- huge count (a directly typed @1000000p@, or one substituted in by
-- @.@) multiply even a short one, into an allocation that is finite
-- but not fast: exactly the gap 'boundedRepeatCount' closes.
normal (NPaste k a)     e = pureT (maybe e (flip edit e . put) (register e))
  where
    put (Clip True  t) = Doc.pasteRows a (boundedRepeatCount k t) t
    put (Clip False t) = charwise (Text.replicate (boundedRepeatCount k t) t)
    charwise = if a then Doc.insertAfter unicode else Doc.insert
normal (NJoin k)        e = pureT (edit (Doc.joinLines (bounded k)) e)
-- | @.@ replays the last change, with a fresh count if one is given --
-- @3.@ is vim's "do that three times", not "do the 3 from last time".
normal (NRepeat k)      e = maybe (pureT e { status = Just "nothing to repeat" }) replay (lastEdit e)
  where
    replay (c, text) = (retype text (clean (fst again)), snd again)
      where
        again = normal (recount k c) e
        -- 'again' carries @e@'s 'typing' field through unchanged --
        -- 'normal' is called directly here, bypassing the top-level
        -- 'remember' that would otherwise reset it. Left alone, the
        -- stale value is what 'retype' appends the replayed text onto,
        -- so 'typing' doubles on every press of @.@: 1, 2, 4, 8, ...,
        -- exhausting memory well before it exhausts anyone's patience.
        -- Found by a Hedgehog session test hanging outright, not by
        -- any property about length or content.
        clean x = x { typing = Text.empty }
    -- The text is replayed through 'step' so that it goes through the
    -- same insert path as typing it would, rather than a second
    -- implementation of what typing means.
    retype t e1
      | Text.null t = e1
      | otherwise   = fst (step (InInsert IEscape) (fst (step (InInsert (IInput t)) e1)))
normal (NRepeatFind k flip') e = pureT (maybe nothing again (lastFind e))
  where
    nothing = e { status = Just "no previous search" }
    again (back, pat) = seek (if flip' then not back else back) k pat e
-- | ';' and ',' repeat the last @f@\/@t@\/@F@\/@T@. The direction is
-- vim's: ';' repeats exactly as given, ',' reverses it. The short
-- ('t'\/'T') nudge -- searching from one character further in the
-- direction of travel, so the motion cannot immediately re-find the
-- target it already sits beside -- is computed here, next to the only
-- other place direction and reversal are combined, rather than folded
-- into 'Doc.reachToFrom' itself: that function has no way to know
-- whether it is being asked for a fresh search or a repeat.
normal (NRepeatTo k flip') e = pureT (maybe nothing again (lastTo e))
  where
    nothing = e { status = Just "no previous find" }
    again (MTo back short c) = moveBy r e
      where
        dir     = if flip' then not back else back
        here'   = Doc.unOffset (Doc.cursorCol (document e))
        -- 'dir' is 'MTo's own @back@ flag: 'True' searches backward, so
        -- the nudge that skips past an already-adjacent target goes
        -- the opposite way, forward when 'dir' is 'False'.
        nudge   = if dir then -1 else 1
        fromOff = if short then here' + nudge else here'
        r       = Doc.reachToFrom unicode dir short c (bounded k) fromOff (document e)
    again _ = e   -- unreachable: 'lastTo' is always 'Nothing' or an 'MTo'
normal (NReplace k c)   e = pureT (edit (Doc.replaceChars (bounded k) c) e)
-- | @ZZ@ and @ZQ@ are direct aliases for commands that already exist
-- behind the ex-command prompt -- @:wq@ and @:q!@ -- so they reuse
-- 'writeQuit' and 'quit' rather than a second implementation of what
-- either one means.
normal NWriteQuit       e = writeQuit e
normal NQuitDiscard     e = quit True e
normal (NPasteText t)   e = pureT (edit (Doc.insert t) e)
normal (NUndo k)        e = pureT (travel k e)
normal (NRedo k)        e = pureT (travel (negate k) e)
normal NSave            e = save False e

-- | 'Delete' commits the cut document and keeps the text; 'Yank' keeps
-- only the text. Both read one 'Doc.operate', so no operator carries
-- per-motion knowledge and neither duplicates the other's bookkeeping.
-- | A change enters Insert mode whether or not its span was empty.
-- Otherwise @cw@ on a blank line leaves you in Normal mode, and the
-- word you then type is executed as commands -- which is how @ccMod@
-- silently appended a line during testing.
apply :: Operator -> Doc.Reach -> Editor -> Editor
apply o r e = maybe (idle o) (project o) (Doc.operate o r (document e))
  where
    project Delete (d, t) = commit d (stash t e)
    project Yank   (_, t) = stash t e
    -- 'Doc.operate' already emptied the row rather than removing it for
    -- a linewise change, so there is nothing left for this clause to
    -- arrange beyond the mode.
    project Change (d, t) = commit d (stash t e) { mode = Insert Fresh }
    -- Case and indent operators transform in place rather than cut, so
    -- unlike Delete/Change they never touch the register -- vim's own
    -- rule: @gu@\/@gU@\/@g~@\/@>@\/@<@ are not yank-equivalents.
    project ToLower    (d, _) = commit d e
    project ToUpper    (d, _) = commit d e
    project ToggleCase (d, _) = commit d e
    project Indent     (d, _) = commit d e
    project Dedent      (d, _) = commit d e
    idle Change = e { mode = Insert Fresh }
    idle Delete = e
    idle Yank   = e
    idle ToLower    = e
    idle ToUpper    = e
    idle ToggleCase = e
    idle Indent     = e
    idle Dedent     = e
    stash t x = x { register = Just (Clip linewise t) }
    linewise = case r of
      Doc.Lines _  -> True
      Doc.Chars _  -> False
      Doc.Upto _ _ -> False

-- | Insert mode's four entry points. @a@ steps right within the line and
-- is therefore the one place the gap is legitimately allowed past the
-- last character -- which is exactly why 'retract' is keyed on the
-- resulting mode and not applied unconditionally.
-- | The count given to @i@\/@a@\/@o@\/@O@ does not repeat the entry
-- itself -- @3i@ opens one insert session, not three -- it repeats the
-- /typed text/ once Escape ends that session. Recorded here as
-- 'insertRepeat' and consumed only by 'insertMode's 'IEscape' clause.
enter :: Int -> InsertAnchor -> Editor -> Editor
enter n Before    e = (e { mode = Insert Fresh }) { insertRepeat = max 1 n }
enter n After     e = (moveBy (Doc.Chars 1) e { mode = Insert Fresh }) { insertRepeat = max 1 n }
enter n LineBelow e = (commit (Doc.openLine 1 (document e)) e { mode = Insert Dirty }) { insertRepeat = max 1 n }
enter n LineAbove e = (commit (Doc.openLine 0 (document e)) e { mode = Insert Dirty }) { insertRepeat = max 1 n }

-- | Give a remembered command a new count, where it has one.
recount :: Int -> NormalCmd -> NormalCmd
recount k (NOperate _ o m) = NOperate k o m
recount k (NPaste _ a)     = NPaste k a
recount k (NJoin _)        = NJoin k
recount _ c@(NPasteText _)   = c
recount _ c@(NEnterInsert _ _) = c
recount _ c@NEnterReplace       = c
recount _ c@(NEnterPrompt _) = c
recount _ c@(NMove _ _)      = c
recount _ c@(NRepeat _)      = c
recount _ c@(NRepeatFind _ _) = c
recount _ c@(NRepeatTo _ _)   = c
recount k (NReplace _ c)     = NReplace k c
recount _ c@NWriteQuit        = c
recount _ c@NQuitDiscard      = c
recount _ c@(NUndo _)        = c
recount _ c@(NRedo _)        = c
recount _ NSave              = NSave

-- | Travel @|k|@ steps through history: into the past for @k > 0@, into
-- the future for @k < 0@. 'past' and 'future' are the two halves of one
-- tape, so undo and redo are one function read in two directions rather
-- than two mirror-image copies. The documents skipped over move to the
-- other half in reverse order, which is what makes @k@ undos followed by
-- @k@ redos the identity.
travel :: Int -> Editor -> Editor
travel k e = case reverse (take (abs k) src) of
  []          -> e { status = Just exhausted }
  new : older -> commitTo new (onBuffer (\b -> b { bHistory = rebuild (drop (abs k) src)
                                                                      (older ++ (document e : dst)) }) e)
  where
    back      = k > 0
    (src, dst) = if back then (past h, future h) else (future h, past h)
    rebuild s d = if back then History s d else History d s
    exhausted = if back then "already at oldest change" else "already at newest change"
    h = history e

-- Insert mode --------------------------------------------------------

insertMode :: InsertCmd -> Editor -> Step
insertMode (IInput t) e = pureT (case mode e of
  Replace _ -> overwriteAll t e
  _         -> typed (Doc.insert t) e)
insertMode IBackspace e = pureT (case mode e of
  Replace stack -> unwind stack e
  _             -> typed (Doc.backspace unicode) e)
insertMode (IMove d)  e = pureT (moveBy (Doc.reach unicode 1 (MChar d) (document e)) (restart e))
-- | A counted insert (@3ifoo\<Esc\>@) repeats the whole session's typed
-- text, not just the final keystroke -- so the repetition happens
-- here, once, against everything 'typing' accumulated, rather than
-- per-character as each 'IInput' arrives. Bounded the same way paste
-- is (2.10b): a count is a count regardless of which command it
-- reached the editor through, and the risk -- a small per-unit cost
-- multiplied by an unbounded repeat -- is identical.
insertMode IEscape    e = pureT (moveBy (Doc.Chars (-1)) (repeatTyped e) { mode = Normal, insertRepeat = 1 })
  where
    repeatTyped x
      | insertRepeat x <= 1 || Text.null (typing x) = x
      | otherwise = maybe x (`commitTo` x) (Doc.insert more (document x))
      where more = Text.replicate (boundedRepeatCount (insertRepeat x - 1) (typing x)) (typing x)

-- | An insert-mode edit. The first edit of a session opens an undo
-- entry and every edit after it extends that same one, so typing a word
-- and pressing @u@ removes the word rather than its last letter. This
-- is the transaction boundary 'History' previously had no notion of; it
-- needs no new field because the boundary is an interval of the mode
-- automaton, and the mode already records it.
typed :: (Doc.Document -> Maybe Doc.Document) -> Editor -> Editor
typed f e = maybe e keep (f (document e))
  where
    keep d = case mode e of
      Insert Fresh -> (commit d e) { mode = Insert Dirty }
      Insert Dirty -> commitTo d e
      Normal       -> commit d e
      Prompt {}    -> commit d e
      Replace _    -> commit d e  -- unreachable: 'insertMode' branches Replace to 'overwriteAll' before 'typed' is ever called

-- | A cursor move ends the session, so text typed after it is a
-- separate undo entry -- vim's rule.
restart :: Editor -> Editor
restart e = case mode e of
  Insert _   -> e { mode = Insert Fresh }
  Replace _  -> e { mode = Replace [] }
  Normal     -> e
  Prompt {}  -> e

-- | @R@: overwrite one character of input at a time, each pushing what
-- it overwrote onto the mode's own stack so backspace can restore it.
-- The first overwrite of a session opens an undo entry, as the first
-- keystroke of an ordinary insert session does; every one after it
-- extends that same entry -- mirrored from 'typed', since there is no
-- 'Session' flag to read for 'Replace' and the stack's emptiness is
-- exactly that same question answered a different way.
--
-- A newline is never folded into 'Doc.overwriteChar': that function
-- appends its character directly to a 'LineZ' half, and a 'LineZ' may
-- never contain one -- the exact invariant 'Doc.insert' already solves
-- for ordinary typing by routing a newline through a line split
-- instead. Pressing Enter in Replace mode opens a line the same way,
-- never "overwriting" the next line's first character the way a
-- plain keystroke overwrites one; a stack entry of @Just "\\n"@
-- records that this step was a split rather than an overwrite, which
-- is unambiguous because an actual overwritten cluster can never equal
-- a newline for the same reason the split exists.
-- | Processes every character of @t@ against the document directly,
-- committing only once at the end rather than once per character. An
-- earlier version called 'commit'\/'commitTo' inside the fold, which
-- bumped 'version' once per character of a single 'IInput' event
-- instead of once for the event as a whole -- breaking "version bumps
-- by exactly one when content changes" for any multi-character input,
-- such as a bracketed paste arriving while replacing.
-- 'Basilisk.Step.typed', which this otherwise mirrors, never had this
-- bug, because 'Doc.insert' already processes a whole string in one
-- call; this folds the /document and stack/ purely instead, and
-- reserves the commit for the final result.
overwriteAll :: Text -> Editor -> Editor
overwriteAll t e
  | Text.null t = e   -- nothing to process: declined, not a zero-length change that still commits
  | otherwise   = case mode e of
      Replace stack0 ->
        let (finalDoc, stack1) = Text.foldl' go (document e, stack0) t
            unchanged = Doc.toText finalDoc == Doc.toText (document e)
        in (if unchanged then e else if null stack0 then commit finalDoc e else commitTo finalDoc e)
             { mode = Replace stack1 }
      _ -> e   -- unreachable: only called while 'mode e' is 'Replace'
  where
    go (d, stack) ch = (d', original : stack)
      where (d', original) = overwriteOne ch d
    -- One character in, the document it produces (always succeeds --
    -- neither branch ever declines) and what to push onto the stack:
    -- the overwritten cluster, or @Just "\\n"@ marking a split. A
    -- newline is never folded into 'Doc.overwriteChar': that function
    -- appends its character directly to a 'LineZ' half, and a 'LineZ'
    -- may never contain one -- the exact invariant 'Doc.insert'
    -- already solves for ordinary typing by routing a newline through
    -- a line split instead. The @Just "\n"@ marker is unambiguous
    -- because an actual overwritten cluster can never equal a newline,
    -- for the same reason the split exists.
    overwriteOne :: Char -> Doc.Document -> (Doc.Document, Maybe Text)
    overwriteOne '\n' d = (fromMaybe d (Doc.insert "\n" d), Just "\n")
    overwriteOne ch    d = Doc.overwriteChar unicode ch d

-- | The mirror of 'overwriteAll' for one backspace: undo exactly one
-- typed character, restoring what it overwrote. An empty stack means
-- nothing has been typed yet this session, which vim's own @R@ leaves
-- as a no-op rather than backspacing past where the session started.
--
-- A stack entry of @Just "\\n"@ cannot be undone with 'Doc.restoreChar'
-- -- that function patches one 'LineZ' half on the current line, but a
-- newline moved the cursor onto a different line entirely, so undoing
-- it means rejoining two lines, not editing one. 'Doc.backspace' is
-- exactly vim's own join-on-backspace-at-start-of-line behaviour,
-- reused rather than re-implemented. What the next line used to start
-- with is not restored by this -- an accepted simplification, not an
-- oversight: doing so faithfully would need its own restore
-- mechanism parallel to this one, for a case (backspacing across a
-- Replace-mode newline) rare enough that this project's budget goes
-- elsewhere first.
unwind :: [Maybe Text] -> Editor -> Editor
unwind []                 e = e
unwind (Just "\n" : rest) e = settleReplace rest (fromMaybe (document e) (Doc.backspace unicode (document e))) e
unwind (top : rest)       e = settleReplace rest (Doc.restoreChar top (document e)) e

-- | Commits the restored document only if it actually differs from
-- what was there, the same rule every other edit in this module
-- follows: a 'Maybe'-returning primitive reports a true no-op as
-- declining, and this is the one case in 'Replace' mode where the
-- result has to be checked after the fact rather than before, since
-- 'Doc.restoreChar' and 'Doc.backspace' cannot know on their own
-- whether the text they are restoring happens to coincide with what a
-- later edit already produced. The mode still updates either way --
-- the stack was genuinely popped -- only the undo-observable state
-- does not move when nothing visibly did.
settleReplace :: [Maybe Text] -> Doc.Document -> Editor -> Editor
settleReplace rest d e
  | Doc.toText d == Doc.toText (document e) = e { mode = Replace rest }
  | otherwise                               = (commitTo d e) { mode = Replace rest }

-- Prompt mode --------------------------------------------------------

-- | The prompt currently open, if any. This is the entire residue of the
-- mode/command diagonal: one function, exhaustive over 'Mode', so a new
-- mode is a compile error here rather than a value silently absorbed
-- somewhere in a thirty-clause case.
openPrompt :: Editor -> Maybe (PromptKind, Text)
openPrompt e = case mode e of
  Normal     -> Nothing
  Insert _   -> Nothing
  Replace _  -> Nothing
  Prompt k b -> Just (k, b)

promptMode :: PromptCmd -> Editor -> Step
promptMode c e = maybe (pureT e) (onPrompt c e) (openPrompt e)

onPrompt :: PromptCmd -> Editor -> (PromptKind, Text) -> Step
onPrompt (PInput t) e (k, b) = pureT e { mode = Prompt k (b <> t) }
onPrompt PBackspace e (k, b) = pureT e { mode = Prompt k (Text.dropEnd 1 b) }
onPrompt PEscape    e _      = pureT e { mode = Normal, status = Nothing }
onPrompt PSubmit    e (k, b) = submit k b e { mode = Normal }

-- | Ex-command dispatch. @:w@ shares 'save' with the save command rather
-- than duplicating it, and @:q@ requests a quit through the same
-- 'Effect' channel, since the pure core may report a quit but never act
-- on one.
submit :: PromptKind -> Text -> Editor -> Step
submit ExCommand c e
  | c `elem` ["w", "write"]   = save False e
  | c `elem` ["w!", "write!"] = save True e
  | c `elem` ["q", "quit"]    = quit False e
  | c `elem` ["q!", "quit!"]  = quit True e
  | c `elem` ["wq", "x"]      = writeQuit e
  | otherwise                 = pureT e { status = Just "unknown command" }
-- | A search moves the cursor and is remembered, so @n@ and @N@ have
-- something to repeat. A pattern that is not found says so and leaves
-- the cursor where it was, rather than moving it somewhere arbitrary.
submit Search pat e
  | Text.null pat = pureT e { mode = Normal }
  | otherwise     = pureT (seek False 1 pat e { lastFind = Just (False, pat) })

-- | Jump to the @k@th match. The motion produces an 'Doc.Upto', which
-- is the reach shape that can name a position on another row -- the
-- same shape a selection will use.
seek :: Bool -> Int -> Text -> Editor -> Editor
seek back k pat e = case Doc.reach unicode (bounded k) (MFind back pat) (document e) of
  Doc.Chars 0 -> e { status = Just ("not found: " <> pat) }
  r           -> (moveBy r e) { status = Nothing, lastFind = Just (back, pat) }

-- | The write is an effect the shell performs; 'step' only computes the
-- bytes, line endings included, so nothing downstream re-derives them.
-- @force@ is the user's @!@, which overrides the shell's on-disk
-- staleness check -- a decision the pure core can record but not make.
save :: Bool -> Editor -> Step
save force e
  | readOnly e && not force = pureT e { status = Just "read-only file (:w! to override)" }
  | otherwise = maybe (pureT e { status = Just "no file name" }) write (path e)
  where
    write p = (e, [WriteFile p (serialise e) force])

-- | Quitting with unsaved changes is refused rather than confirmed:
-- there is no dialogue to answer in a modal editor, and a keystroke
-- that silently discards an hour of work is the one failure a text
-- editor may not have. @!@ overrides.
quit :: Bool -> Editor -> Step
quit force e
  | force || not (modified e) = (e, [RequestQuit])
  | otherwise = pureT e { status = Just "no write since last change (:q! to override)" }

-- | @:wq@. The quit is conditional on the write actually being
-- requested: with no filename there is nothing to write, so quitting
-- would discard the buffer on the strength of a command that asked for
-- it to be saved.
writeQuit :: Editor -> Step
writeQuit e = case save False e of
  (e', [])      -> (e', [])
  (e', effects) -> (e', effects <> [RequestQuit])

-- shared machinery ---------------------------------------------------

pureT :: Editor -> Step
pureT = (, [])

-- | Move, and set the remembered column iff the motion was horizontal.
-- 'Chars' sets it, 'Lines' preserves it: that is the complete
-- specification of 'desiredColumn', in two clauses. The gap is retracted
-- before the column is read, so a horizontal motion that the Normal-mode
-- invariant pushes back records the column it actually landed on.
moveBy :: Doc.Reach -> Editor -> Editor
moveBy r e = sync (withDocument (gap (Doc.move unicode (desiredColumn (cursor e)) r (document e))) e)
  where
    gap = case mode e of
      Normal     -> Doc.clampGap unicode
      Insert _   -> id
      Replace _  -> id
      Prompt {}  -> id
    sync = case r of
      Doc.Chars _  -> resync
      Doc.Upto _ _ -> resync   -- a jump names a column; it does not preserve one
      Doc.Lines _  -> id

-- | Apply an edit that may decline. A declined edit changes nothing --
-- no history entry, no version bump -- and 'Nothing' is the primitive's
-- own report, so this costs @O(1)@ and never compares two documents.
edit :: (Doc.Document -> Maybe Doc.Document) -> Editor -> Editor
edit f e = maybe e (`commit` e) (f (document e))

-- | Record a changed document: push the previous one, clear the redo
-- stack, bump the version, resync the column.
commit :: Doc.Document -> Editor -> Editor
commit d e = commitTo d (onBuffer (\b -> b { bHistory = History (take undoLimit (document e : past (history e))) [] }) e)

-- | As 'commit' but leaving 'history' to the caller -- 'travel' has
-- already rebuilt it.
commitTo :: Doc.Document -> Editor -> Editor
commitTo d e = resync (onBuffer (\b -> b { bDocument = d, bVersion = bVersion b + 1 }) e)


resync :: Editor -> Editor
resync e = e { cursor = syncColumn (document e) }

-- | Re-establish the document invariants after every transition: the
-- cursor sits on a grapheme-cluster boundary in every mode, and in
-- Normal mode it additionally sits on a character rather than in the
-- gap past the last one.
-- 'Doc.clampGap' is idempotent, so applying it here as well as inside
-- 'moveBy' is free, and applying it to every result makes the invariant
-- hold by induction over the whole event stream. A retraction that
-- actually moved the cursor resyncs; one that did not cannot, or it
-- would clobber the column a vertical motion is preserving -- and after
-- a vertical motion 'moveBy' has already retracted, so the test is
-- exactly right in both directions, at @O(1)@.
retract :: Editor -> Editor
retract e = settle (normalise (document e))
  where
    normalise = case mode e of
      Normal    -> Doc.clampGap unicode . Doc.alignCursor unicode
      Insert _  -> Doc.alignCursor unicode
      Replace _ -> Doc.alignCursor unicode
      Prompt {} -> Doc.alignCursor unicode
    settle d
      | Doc.cursorCol d == Doc.cursorCol (document e) = e
      | otherwise                                     = resync (withDocument d e)
