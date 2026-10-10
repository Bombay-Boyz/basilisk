{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The value types shared across the editor. Every field of 'Editor' is
-- state that cannot be derived from anything else; cursor row and column
-- in particular are stored nowhere at all (see "Basilisk.Document").
module Basilisk.Types
  ( -- * Re-exports from the document algebra
    Direction (..)
  , Motion (..)
  , Operator (..)
    -- * Modes and commands
  , PromptKind (..)
  , Session (..)
  , Mode (..)
  , InsertAnchor (..)
  , NormalCmd (..)
  , InsertCmd (..)
  , PromptCmd (..)
  , Action (..)
    -- * Effects
  , Effect (..)
    -- * Editor state
  , Clip (..)
  , History (..)
  , Eol (..)
  , Stamp
  , modified
  , Buffer (..)
  , Editor (..)
  , onBuffer
  , withDocument
  , document
  , history
  , version
  , saved
  , path
  , stamp
  , eol
  , finalEol
  , bornEmpty
  , readOnly
  , undoLimit
  , maxCount
  , maxPasteChars
  , boundedRepeatCount
  , bounded
  , newEditor
  , encodeEol
  , decodeEol
  , serialise
  ) where

import Control.DeepSeq (NFData)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)

import Basilisk.Cursor (Cursor (..))
import Basilisk.Document
  ( Column (..)
  , Direction (..)
  , Document
  , Motion (..)
  , Operator (..)
  , fromText
  , toText
  )

-- | The largest count any command will act on.
--
-- Vim accumulates a count into a machine integer and, until 2023, did
-- not check it: CVE-2023-48233 through CVE-2023-48236 are four separate
-- overflows in four separate count parsers, each fixed by adding a
-- bound. An unchecked @10 * n + d@ wraps to a negative count, and a
-- count that survives into @replicate@ is an allocation bomb.
--
-- 'bounded' saturates instead of erroring, which needs no failure path
-- and keeps every count-taking function total. It is applied where a
-- count enters the system ("Basilisk.Decode") and again where one could
-- allocate, so a hand-constructed 'Action' is as safe as a typed one.
maxCount :: Int
maxCount = 1000000

bounded :: Int -> Int
bounded = max 0 . min maxCount

-- | The largest number of characters a single paste may put into the
-- document, regardless of how that arises from combining a count with
-- a register's length.
--
-- 'bounded' alone caps the count, which is the right bound for a
-- repetition whose per-unit cost is O(1) or O(line) -- an undo, a
-- redo, a motion. Paste is different: its cost is the /product/ of the
-- count and the register's length, so a count that is itself perfectly
-- 'bounded' can still multiply a short register into a multi-megabyte
-- single line. Measured directly, not assumed: pasting a
-- 1,000,000-count copy of an eight-character register took
-- twenty-seven seconds, and every keystroke on the resulting line cost
-- a further twenty-plus seconds each -- the O(line) cost the
-- benchmarks already measured and named @Linear*@. 'bounded' does not
-- protect against that, because it was never asked to: it bounds a
-- count, not a product.
--
-- The figure below keeps a single paste's total output within the
-- range the benchmark measured as comfortably fast: at 144,000
-- characters a keystroke on the resulting line costs about 53ms, so a
-- third of that keeps every subsequent action on the pasted text well
-- under 20ms.
maxPasteChars :: Int
maxPasteChars = 50000

-- | How many times @t@ may be repeated without the total exceeding
-- 'maxPasteChars'. Total for every @t@, including empty text, where
-- any count is safe because there is nothing to multiply.
boundedRepeatCount :: Int -> Text -> Int
boundedRepeatCount k t
  | Text.null t = bounded k
  | otherwise   = min (bounded k) (max 0 (maxPasteChars `div` Text.length t))

data PromptKind = ExCommand | Search
  deriving (Eq, Show, Generic, NFData)

-- | Whether the current insert session has already opened an undo
-- entry. Carried by 'Mode' for the same reason the prompt buffer is: it
-- is state that cannot meaningfully exist outside the one mode it
-- belongs to, so putting it on 'Editor' would create a field that is
-- undefined most of the time.
data Session = Fresh | Dirty
  deriving (Eq, Show, Generic, NFData)

-- | 'Prompt' carries its own input buffer, so there is no separate
-- command-buffer field that could drift out of sync with whether a
-- prompt is open: it is structurally impossible for a buffer to exist in
-- 'Normal' or 'Insert'.
-- | 'Replace's list is a stack of what each typed character overwrote:
-- @Just cluster@ when there was one to restore, @Nothing@ when typing
-- only extended the line. Carried in the mode for the same reason the
-- prompt buffer and the insert session's count are: it means something
-- only while a replace session is open.
data Mode = Normal | Insert !Session | Prompt !PromptKind !Text | Replace ![Maybe Text]
  deriving (Eq, Show, Generic, NFData)

data InsertAnchor = Before | After | LineBelow | LineAbove
  deriving (Eq, Show, Generic, NFData)

-- | Commands legal in Normal mode. Counts are fields, not a wrapper:
-- vim's grammar is @[count] command@, so the count is part of the
-- command's abstract syntax and is resolved in closed form by
-- 'Basilisk.Document.reach' rather than by re-running anything.
data NormalCmd
  = NMove !Int !Motion
  | NOperate !Int !Operator !Motion
  | NEnterInsert !Int !InsertAnchor  -- ^ a count repeats the typed text that many times on Escape
  | NEnterReplace                    -- ^ @R@: as 'NEnterInsert', but overwriting instead of inserting.
                                      -- A count is deliberately not supported: that would need a second,
                                      -- overwrite-based repeat mechanism parallel to 'insertRepeat', and
                                      -- plain @R@ is the overwhelmingly common case.
  | NEnterPrompt !PromptKind
  | NPaste !Int !Bool
  | NJoin !Int
  | NRepeat !Int             -- ^ @.@: the last change again
  | NRepeatFind !Int !Bool   -- ^ @n@ and @N@: the last search again, reversed when 'True'
  | NRepeatTo !Int !Bool     -- ^ @;@ and @,@: the last @f@\/@t@\/@F@\/@T@ again, reversed when 'True'
  | NReplace !Int !Char      -- ^ @r@: replace the next @n@ characters with one
  | NWriteQuit               -- ^ @ZZ@: save (if there is a path) then quit unconditionally
  | NQuitDiscard             -- ^ @ZQ@: quit unconditionally, discarding any changes
  | NPasteText !Text
  | NUndo !Int
  | NRedo !Int
  | NSave
  deriving (Eq, Show, Generic, NFData)

data InsertCmd = IInput !Text | IBackspace | IMove !Direction | IEscape
  deriving (Eq, Show, Generic, NFData)

data PromptCmd = PInput !Text | PBackspace | PSubmit | PEscape
  deriving (Eq, Show, Generic, NFData)

-- | An action is tagged with the mode it belongs to, so an illegal
-- (mode, command) pairing is not a value 'Basilisk.Step.step' has to
-- field -- it is a value that does not type-check. 'Basilisk.Decode' is
-- given the current 'Mode' and therefore always builds the right tag.
data Action = InNormal !NormalCmd | InInsert !InsertCmd | InPrompt !PromptCmd
  deriving (Eq, Show, Generic, NFData)

-- | Everything the pure core can ask the shell to do but may not do
-- itself. 'WriteFile' carries the exact bytes, already line-ending
-- encoded, so the shell has no editing decision left to make, and
-- whether the user overrode the on-disk staleness check.
-- 'RequestQuit' is how a quit reaches the shell without the pure core
-- ever deciding to stop the program.
data Effect = WriteFile !FilePath !Text !Bool | RequestQuit
  deriving (Eq, Show, Generic, NFData)

-- | What the register holds, and how it was taken. A linewise cut
-- pastes as whole rows and a charwise one pastes inline; without the
-- flag, @yy@ followed by @p@ joins the copied line onto the current
-- one instead of opening a new one.
data Clip = Clip { clipLinewise :: !Bool, clipText :: !Text }
  deriving (Eq, Show, Generic, NFData)

-- | Past and future snapshots, sharing structure with each other at the
-- GC level because 'Text' and 'Seq' are immutable.
data History = History { past :: ![Document], future :: ![Document] }
  deriving (Eq, Show, Generic, NFData)

-- | Which line ending this buffer round-trips through.
data Eol = LF | CRLF | CR
  deriving (Eq, Show, Generic, NFData)

-- | @encodeEol e . decodeEol = id@ on any text whose every @\\r@
-- immediately precedes a @\\n@, which is exactly the set 'decodeEol'
-- produces. The editor therefore never rewrites a file's line endings
-- just by opening and saving it.
decodeEol :: Eol -> Text -> Text
decodeEol LF   = id
decodeEol CRLF = Text.replace "\r\n" "\n"
decodeEol CR   = Text.replace "\r" "\n"

encodeEol :: Eol -> Text -> Text
encodeEol LF   = id
encodeEol CRLF = Text.replace "\n" "\r\n"
encodeEol CR   = Text.replace "\n" "\r"

-- | A file's modification time in nanoseconds together with its size.
-- Either alone is too coarse to detect a rewrite: filesystems round
-- timestamps, and a same-size edit is the common case.
type Stamp = (Integer, Integer)

-- | How many document snapshots the undo stack keeps.
--
-- Unbounded history is a slow leak rather than a feature: every edit
-- retains a whole document, and although 'Text' and 'Seq' share
-- structure, a long session on a large file still grows without limit.
-- Vim bounds the same stack with @\'undolevels\'@.
undoLimit :: Int
undoLimit = 1000

-- | The exact bytes a buffer writes, as 'Text'.
--
-- A buffer that was born empty -- a new file, or a zero-byte one --
-- and is still empty writes no bytes at all, rather than a lone
-- terminator. That is the one case the terminator flag cannot settle
-- on its own, because a zero-byte file and a one-byte @"\n"@ file both
-- load as a single empty row.
--
-- Whether the file ends with a line terminator is a /flag/, not a
-- line. Modelling it as a trailing empty row round-trips bytes
-- perfectly but puts a phantom line at the end of every ordinary file:
-- @G@ lands on it, @$@ and @b@ and @ce@ then do nothing, and @dd@
-- deletes something the user cannot see. Vim calls the flag
-- @\'endofline\'@ for the same reason. The round trip is unaffected --
-- the flag records exactly what was stripped.
serialise :: Editor -> Text
serialise e
  | bBornEmpty (buffer e) && Text.null body = Text.empty
  | otherwise = encodeEol (bEol (buffer e)) (body <> terminator)
  where
    body       = toText (bDocument (buffer e))
    terminator = if bFinalEol (buffer e) then Text.singleton '\n' else Text.empty

-- | What belongs to the file.
--
-- The split is not anticipation of multiple buffers -- it is a
-- property worth having with one. Saving, staleness, line endings and
-- the modified flag are all functions of this record alone, so no code
-- on the write path can read the cursor or the mode, and none of it
-- has to be re-examined when a second buffer appears.
--
-- Fields carry a @b@ prefix only because Haskell puts record selectors
-- in the module namespace; the accessors below give every one of them
-- its plain name on an 'Editor', so reading code is unaffected.
data Buffer = Buffer
  { bDocument  :: !Document
  , bHistory   :: !History
  , bVersion   :: !Int
  , bSaved     :: !Int
  , bPath      :: !(Maybe FilePath)
  , bStamp     :: !(Maybe Stamp)
  , bEol       :: !Eol
  , bFinalEol  :: !Bool
  , bBornEmpty :: !Bool
  , bReadOnly  :: !Bool
  } deriving (Eq, Show, Generic, NFData)

-- | What belongs to the session: where the user is looking, what mode
-- they are in, and the things vim keeps globally rather than per file
-- -- the register, the last search, the message line.
data Editor = Editor
  { buffer   :: !Buffer
  , mode     :: !Mode
  , cursor   :: !Cursor
  , top      :: !Int
  , status   :: !(Maybe Text)
  , register :: !(Maybe Clip)
  , lastFind :: !(Maybe (Bool, Text))
  , lastTo   :: !(Maybe Motion)   -- ^ always 'Nothing' or @Just (MTo _ _ _)@
  , lastEdit :: !(Maybe (NormalCmd, Text))
  , typing   :: !Text
  , insertRepeat :: !Int
    -- ^ set when entering Insert with a count greater than one;
    -- consumed on Escape, which then inserts the session's typed text
    -- this many times in total rather than once.
  } deriving (Eq, Show, Generic, NFData)

-- | Every buffer field, read through the session. Writes go through
-- 'onBuffer', which is deliberately the only way in: it is what makes
-- "this code touches the file" visible at the call site.
document  :: Editor -> Document
document  = bDocument . buffer
history   :: Editor -> History
history   = bHistory . buffer
version   :: Editor -> Int
version   = bVersion . buffer
saved     :: Editor -> Int
saved     = bSaved . buffer
path      :: Editor -> Maybe FilePath
path      = bPath . buffer
stamp     :: Editor -> Maybe Stamp
stamp     = bStamp . buffer
eol       :: Editor -> Eol
eol       = bEol . buffer
finalEol  :: Editor -> Bool
finalEol  = bFinalEol . buffer
bornEmpty :: Editor -> Bool
bornEmpty = bBornEmpty . buffer
readOnly  :: Editor -> Bool
readOnly  = bReadOnly . buffer

onBuffer :: (Buffer -> Buffer) -> Editor -> Editor
onBuffer f e = e { buffer = f (buffer e) }

-- | Replace the document without touching history or the version: a
-- move, a normalisation, or a test fixture -- never an edit, which
-- goes through "Basilisk.Step"'s @commit@.
withDocument :: Document -> Editor -> Editor
withDocument d = onBuffer (\b -> b { bDocument = d })

-- | Whether the buffer differs from what is on disk.
--
-- Conservative by construction: 'version' only ever increases, so
-- undoing back to the state that was last written still reports
-- modified. That errs towards warning about a quit that would lose
-- nothing, never towards a silent quit that would lose work, which is
-- the only direction a guard against data loss may err in.
modified :: Editor -> Bool
modified e = bVersion (buffer e) /= bSaved (buffer e)

-- | The one construction site for an 'Editor'. Adding a field to this
-- strict record touches this line and nothing else -- which is what
-- makes a new field a one-line patch instead of a sweep through every
-- module and test that ever built one.
newEditor :: Maybe FilePath -> Text -> Editor
newEditor p t = Editor
  { buffer   = Buffer
      { bDocument  = fromText t
      , bHistory   = History [] []
      , bVersion   = 0
      , bSaved     = 0
      , bPath      = p
      , bStamp     = Nothing
      , bEol       = LF
      , bFinalEol  = True
      , bBornEmpty = True
      , bReadOnly  = False
      }
  , mode     = Normal
  , cursor   = Cursor (Column 0)
  , top      = 0
  , status   = Nothing
  , register = Nothing
  , lastFind = Nothing
  , lastTo   = Nothing
  , lastEdit = Nothing
  , typing   = Text.empty
  , insertRepeat = 1
  }
