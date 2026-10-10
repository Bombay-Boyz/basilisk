{-# LANGUAGE OverloadedStrings #-}

-- | Keys to actions. Vim's grammar is @[count] operator [count] motion@
-- or @[count] command@, so a decoder cannot be a function of one event:
-- it is a Mealy machine @(state, input) -> (state, output)@ whose state
-- is exactly the pending count and pending operator vim itself tracks.
-- Nothing about a completed command is remembered past the key that
-- completes it, so the state is bounded however long the user pauses.
--
-- 'decode' is given the current 'Mode' and therefore always builds a
-- correctly tagged 'Action' ("Basilisk.Types"); this is the stage at
-- which a mode and a command are matched, which is why no later stage
-- has to check.
module Basilisk.Decode
  ( KeyState
  , initialKeyState
  , decode
  ) where

import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import qualified Graphics.Vty as Vty

import Basilisk.Types

-- | Counts compose multiplicatively (@2d3w@ is @6w@), so a pending
-- operator carries the count that preceded it and the motion's own count
-- multiplies in when it arrives.
data KeyState = KeyState
  { tally   :: !(Maybe Int)
  , pending :: !(Maybe (Int, Operator))
  , prefix  :: !(Maybe Char)   -- ^ a key that only means something doubled, i.e. @g@
  , awaiting :: !(Maybe (Char -> Motion))
    -- ^ @f t F T@ take their target as the next keystroke, so the
    -- decoder has to hold a half-built motion. Storing the function
    -- rather than the key that started it keeps the four cases in one
    -- table instead of four branches here.
  , awaitingChar :: !(Maybe (Int -> Char -> NormalCmd))
    -- ^ @r@ takes its replacement as the next keystroke, the same
    -- shape of wait as 'awaiting' but completing to a command directly
    -- rather than a motion a pending operator might still consume.
  }

initialKeyState :: KeyState
initialKeyState = KeyState Nothing Nothing Nothing Nothing Nothing

-- | Ctrl-C is deliberately unbound. It quit, unconditionally and
-- without checking for unsaved changes, which made the most commonly
-- mistyped key in a terminal the fastest way to lose a buffer. In vim
-- it interrupts; here it does nothing, and quitting goes through the
-- ex-commands that can refuse.

-- | One key in, at most one completed command out, plus the state to
-- carry into the next key. A resize or a mouse event produces no action
-- and disturbs no pending sequence; only 'Basilisk.Loop' cares about
-- resizes, and it reads the terminal size directly.
decode :: Mode -> KeyState -> Vty.Event -> (KeyState, Maybe Action)
decode m st (Vty.EvKey k ms) = case m of
  Normal     -> normalKey st k ms
  Insert _   -> (initialKeyState, insertKey k ms)
  Replace _  -> (initialKeyState, insertKey k ms)
  Prompt {}  -> (initialKeyState, promptKey k ms)
decode m _ (Vty.EvPaste bs) = (initialKeyState, Just (pasted m (decodeUtf8With lenientDecode bs)))
decode _ st _ = (st, Nothing)

-- | A bracketed paste is one action for the whole block, never one per
-- character: a five-hundred-character paste is one 'step', one redraw
-- and one undo entry.
pasted :: Mode -> Text -> Action
pasted Normal      t = InNormal (NPasteText t)
pasted (Insert _)  t = InInsert (IInput t)
pasted (Replace _) t = InInsert (IInput t)
pasted (Prompt _ _) t = InPrompt (PInput (Text.filter (/= '\n') t))

-- Normal mode --------------------------------------------------------

count :: KeyState -> Int
count = max 1 . fromMaybe 1 . tally

-- | The count as typed, with @0@ meaning "none given". Only @G@ and
-- @gg@ need the distinction: every other command treats an absent
-- count as one.
rawCount :: KeyState -> Int
rawCount = max 0 . fromMaybe 0 . tally

-- | Complete a pending sequence: a motion after an operator is an
-- operation over the product of the two counts, and a motion alone is a
-- move. Either way the state resets.
complete :: KeyState -> Int -> Motion -> (KeyState, Maybe Action)
complete st n m =
  ( initialKeyState
  , Just . InNormal $ case pending st of
      Nothing      -> NMove n m
      Just (k, op) -> NOperate (bounded (k * n)) op m
  )

-- | @G@ and @gg@ take an absolute line rather than a repetition, so
-- the caller supplies what "no count" means: the last line for @G@,
-- the first for @gg@. Beyond that they are identical, which is why
-- they share one function. The count is used as typed and is not
-- multiplied by a pending operator's -- but the operator itself still
-- applies, or @dG@ would silently drop the @d@ and become a bare move.
gotoLine :: Int -> KeyState -> (KeyState, Maybe Action)
gotoLine dflt st = emit $ case pending st of
  Nothing      -> NMove n MGotoLine
  Just (_, op) -> NOperate n op MGotoLine
  where n = if rawCount st == 0 then dflt else rawCount st

emit :: NormalCmd -> (KeyState, Maybe Action)
emit = (,) initialKeyState . Just . InNormal

normalKey :: KeyState -> Vty.Key -> [Vty.Modifier] -> (KeyState, Maybe Action)
normalKey st k ms
  | Vty.MCtrl `elem` ms = case k of
      Vty.KChar 'r' -> emit (NRedo (count st))
      _             -> (initialKeyState, Nothing)
-- @gg@ is the only doubled non-operator key, so the prefix state is
-- one 'Char' rather than a general trie. @gu@\/@gU@\/@g~@ are g-prefixed
-- too, but introduce a pending operator rather than completing a motion
-- immediately, so they need their own clause ahead of the generic one.
-- A pending @f@\/@t@ or @r@ consumes the very next key, whatever it is.
normalKey st (Vty.KChar c) _
  | Just mk <- awaiting st     = complete st { awaiting = Nothing } (count st) (mk c)
  | Just mc <- awaitingChar st = emit (mc (count st) c)
normalKey st (Vty.KChar c) _
  | prefix st == Just 'g', Just op <- gOperatorOf c =
      (initialKeyState { pending = Just (count st, op) }, Nothing)
normalKey st (Vty.KChar c) _
  | prefix st == Just 'Z', c == 'Z' = emit NWriteQuit
  | prefix st == Just 'Z', c == 'Q' = emit NQuitDiscard
normalKey st (Vty.KChar 'g') _
  | prefix st == Just 'g' = gotoLine 1 st
  | otherwise             = (st { prefix = Just 'g' }, Nothing)
normalKey st (Vty.KChar 'Z') _ = (st { prefix = Just 'Z' }, Nothing)
-- @G@ with a count names a line; without one it means the last.
normalKey st (Vty.KChar 'G') _ = gotoLine 0 st
normalKey st (Vty.KChar c) _
  | Just d <- digitOf c, d > 0 || isJust (tally st) =
      (st { tally = Just (bounded (10 * fromMaybe 0 (tally st) + d)), prefix = Nothing }, Nothing)
  -- A doubled operator is the linewise motion. @guu@\/@gUU@\/@g~~@
  -- double by their bare second letter, not by repeating @g@, so the
  -- check tries both tables: a letter that introduces an operator one
  -- way can still complete it the other way round.
  | Just (k, op) <- pending st, operatorOf c == Just op || gOperatorOf c == Just op =
      emit (NOperate (bounded (k * count st)) op MLine)
  | Just op <- operatorOf c, isNothing (pending st) =
      (initialKeyState { pending = Just (count st, op) }, Nothing)
  -- Vim's one irregular pairing: @cw@ acts as @ce@, so that changing a
  -- word does not swallow the space after it and leave you typing two
  -- words joined together.
  | Just mk <- targetOf c = (st { awaiting = Just mk }, Nothing)
  | c == 'r' = (st { awaitingChar = Just NReplace }, Nothing)
  | Just m <- motionOf c = complete st (count st) (if changingAWord st m then MWordEnd else m)
  -- A command key is not a motion, so it cannot complete a pending
  -- operator. Executing it anyway would silently drop the operator --
  -- @ciw@ would enter insert mode and type "w" as text. Vim would be
  -- waiting for a text object here; until those exist (see the pending
  -- list) the honest answer is to abandon the sequence.
  | Just _ <- pending st, Just _ <- commandOf c = (initialKeyState, Nothing)
  | Just f <- commandOf c = emit (f (count st))
  | otherwise = (initialKeyState, Nothing)
normalKey st k _ = case arrowOf k of
  Just d  -> complete st (count st) (MChar d)
  Nothing -> (initialKeyState, Nothing)

changingAWord :: KeyState -> Motion -> Bool
changingAWord st m = m == MWord && fmap snd (pending st) == Just Change

digitOf :: Char -> Maybe Int
digitOf c = if c >= '0' && c <= '9' then Just (fromEnum c - fromEnum '0') else Nothing

operatorOf :: Char -> Maybe Operator
-- | The g-prefixed case operators. A separate table from 'operatorOf'
-- because they share no key with it -- 'u'\/'U'\/'~' mean undo, redo
-- is elsewhere, and toggle-case-under-cursor respectively when /not/
-- preceded by @g@.
gOperatorOf :: Char -> Maybe Operator
gOperatorOf 'u' = Just ToLower
gOperatorOf 'U' = Just ToUpper
gOperatorOf '~' = Just ToggleCase
gOperatorOf _   = Nothing

operatorOf 'd' = Just Delete
operatorOf 'y' = Just Yank
operatorOf 'c' = Just Change
operatorOf '>' = Just Indent
operatorOf '<' = Just Dedent
operatorOf _   = Nothing

-- | A motion is usable alone or after an operator; that is what makes
-- @w@ and @dw@ one grammar rule rather than two tables. @0@ reaches here
-- only when no count is pending, which is vim's own rule.
motionOf :: Char -> Maybe Motion
motionOf 'h' = Just (MChar DLeft)
motionOf 'l' = Just (MChar DRight)
motionOf 'j' = Just (MChar DDown)
motionOf 'k' = Just (MChar DUp)
motionOf 'W' = Just (MBigWord False)
motionOf 'B' = Just (MBigWord True)
motionOf '}' = Just (MParagraph False)
motionOf '{' = Just (MParagraph True)
motionOf '%' = Just MMatch
motionOf '|' = Just MColumn
motionOf 'w' = Just MWord
motionOf 'b' = Just MWordBack
motionOf 'e' = Just MWordEnd
motionOf '0' = Just MLineStart
motionOf '^' = Just MFirstNonBlank
motionOf '$' = Just MLineEnd
motionOf _   = Nothing

-- | Commands that take a count but no motion. @x@ is not a primitive:
-- it is @d@ applied to one character forward, which is what it is in
-- vim too.
commandOf :: Char -> Maybe (Int -> NormalCmd)
commandOf 'i' = Just (\n -> NEnterInsert n Before)
commandOf 'a' = Just (\n -> NEnterInsert n After)
commandOf 'o' = Just (\n -> NEnterInsert n LineBelow)
commandOf 'O' = Just (\n -> NEnterInsert n LineAbove)
commandOf 'R' = Just (const NEnterReplace)
commandOf ':' = Just (const (NEnterPrompt ExCommand))
commandOf '/' = Just (const (NEnterPrompt Search))
commandOf 'p' = Just (\n -> NPaste n True)
commandOf 'P' = Just (\n -> NPaste n False)
commandOf 'u' = Just NUndo
commandOf 'J' = Just NJoin
commandOf '.' = Just NRepeat
commandOf 'n' = Just (\k -> NRepeatFind k False)
commandOf 'N' = Just (\k -> NRepeatFind k True)
commandOf ';' = Just (\k -> NRepeatTo k False)
commandOf ',' = Just (\k -> NRepeatTo k True)
-- Derived: each is an operator applied to a motion that already
-- exists, which is why none of them is a new command in the core.
commandOf 'x' = Just (\n -> NOperate n Delete (MChar DRight))
commandOf 'X' = Just (\n -> NOperate n Delete (MChar DLeft))
commandOf 'D' = Just (\n -> NOperate n Delete MLineEnd)
commandOf 'C' = Just (\n -> NOperate n Change MLineEnd)
commandOf 's' = Just (\n -> NOperate n Change (MChar DRight))
commandOf 'S' = Just (\n -> NOperate n Change MLine)
commandOf '~' = Just (\n -> NOperate n ToggleCase (MChar DRight))
commandOf _   = Nothing

-- | The four motions that take their target from the next keystroke.
targetOf :: Char -> Maybe (Char -> Motion)
targetOf 'f' = Just (MTo False False)
targetOf 't' = Just (MTo False True)
targetOf 'F' = Just (MTo True False)
targetOf 'T' = Just (MTo True True)
targetOf _   = Nothing

arrowOf :: Vty.Key -> Maybe Direction
arrowOf Vty.KLeft  = Just DLeft
arrowOf Vty.KRight = Just DRight
arrowOf Vty.KUp    = Just DUp
arrowOf Vty.KDown  = Just DDown
arrowOf _          = Nothing

-- Insert and prompt mode ---------------------------------------------

insertKey :: Vty.Key -> [Vty.Modifier] -> Maybe Action
insertKey k ms
  | Vty.MCtrl `elem` ms = Nothing
  | otherwise = fmap InInsert $ case k of
      Vty.KChar c -> Just (IInput (Text.singleton c))
      Vty.KEnter  -> Just (IInput "\n")
      Vty.KBS     -> Just IBackspace
      Vty.KEsc    -> Just IEscape
      _           -> fmap IMove (arrowOf k)

promptKey :: Vty.Key -> [Vty.Modifier] -> Maybe Action
promptKey k ms
  | Vty.MCtrl `elem` ms = Nothing
  | otherwise = fmap InPrompt $ case k of
      Vty.KChar c -> Just (PInput (Text.singleton c))
      Vty.KEnter  -> Just PSubmit
      Vty.KBS     -> Just PBackspace
      Vty.KEsc    -> Just PEscape
      _           -> Nothing
