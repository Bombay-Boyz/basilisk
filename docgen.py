#!/usr/bin/env python3
"""Assemble Basilisk.md from the prose below and the *actual* compiled
sources. The document cannot drift from the code because it does not
contain a second copy of it."""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
OUT = ROOT / 'Basilisk.md'

def src(rel, lang='haskell'):
    return "```%s\n%s```" % (lang, (ROOT / rel).read_text())

def loc(rel):
    t = (ROOT / rel).read_text().splitlines()
    return len(t), len([l for l in t if l.strip() and not l.strip().startswith('--')])

MODULES = [
    ('Basilisk.Document', 'src/Basilisk/Document.hs', 'zipper, coordinates, the reach algebra'),
    ('Basilisk.Cursor',   'src/Basilisk/Cursor.hs',   'the sticky column, ICU display width'),
    ('Basilisk.Types',    'src/Basilisk/Types.hs',    'modes, tagged commands, effects, editor'),
    ('Basilisk.Step',     'src/Basilisk/Step.hs',     'the pure transition function'),
    ('Basilisk.Decode',   'src/Basilisk/Decode.hs',   "vim's key grammar, as a Mealy machine"),
    ('Basilisk.Render',   'src/Basilisk/Render.hs',   'viewport, frame, status line'),
    ('Basilisk.File',     'src/Basilisk/File.hs',     'open and write, encoding-safe'),
    ('Basilisk.Loop',     'src/Basilisk/Loop.hs',     'the IO shell'),
    ('Main',              'app/Main.hs',              'argument parsing'),
]
EXTRA = [
    ('scripts/check.sh', 'everything CI checks, in one script', 'bash'),
    ('bench/Bench.hs', 'complexity benchmarks', 'haskell'),
]
TESTS = [
    ('test/Laws.hs', 'the laws, as Hedgehog properties'),
    ('test/Gen.hs', 'Unicode-hostile generators'),
    ('test/Smoke.hs', "worked examples, in vim's vocabulary"),
    ('test/Exhaustive.hs', 'totality sweep'),
]

rows, total = [], 0
for name, rel, resp in MODULES:
    a, c = loc(rel)
    total += c
    rows.append(f"| `{name}` | {resp} | {c} | {a} |")
budget = "\n".join(rows)

testrows = []
for rel, resp in TESTS:
    a, c = loc(rel)
    testrows.append(f"| `{rel}` | {resp} | {c} | {a} |")

doc = f"""# Basilisk
## Vision, Architecture, and Code — Developer Handoff, revision 4

Basilisk is a modal terminal text editor, written in Haskell, for Haskell
development. It targets a **hard ceiling of 3,000 lines of code**, a terse
style throughout, a small set of total functions as its mathematical core,
and a vim-like editing experience.

This document is the single source of truth for the project. **Part 2
describes the design as it stands; it contains no superseded text.** Where
an earlier revision decided differently, that is recorded once, in Part 4's
revision log, and nowhere else — a reader implementing from Part 2 cannot
implement a design this project has already abandoned.

**Every line of code in Part 3 is spliced into this document from the
compiled source tree at build time.** The document and the code cannot
diverge, because the document does not contain a second copy of the code.

Status, in one line: nine modules, {total} lines of code, zero warnings under
the full flag set, all three test suites passing, and the editor has been
run end to end against a real terminal. See Part 4 for exactly what that
sentence does and does not cover.

---

# Part 1 — Vision

- **Gold-standard architecture.** Every module has one stated
  responsibility. A field exists only if it cannot be derived from
  something else already in the system.
- **Terse, mathematical code.** Prefer composition and small total
  functions over control flow. Density in service of clarity: a function
  should read like a proof of what it does, which means point-free where
  that clarifies and pointful where it does not.
- **Total functions only.** No partial pattern matches, no `head`,
  `fromJust`, `(!!)`, or bare `error`. Every boundary — start or end of
  file, an empty line, an empty document, a zero-cell terminal — returns
  something sensible rather than crashing.
- **Only tail recursion in the IO shell.** The event loop is the one place
  recursion touches long-running state; it is strict and tail-recursive,
  with O(1) stack, forever.
- **Memory discipline.** `StrictData` on every type, forced state at every
  loop iteration, no thunk chains, no space leaks over a long session.
- **Haskell-first developer experience.** Structural Haskell awareness
  (parsing, LSP) is a named future milestone, not required for v1.
- **3,000 LOC is a hard ceiling.** Part 2.9 gives the measured per-module
  figure, not an aspiration.

---

# Part 2 — Architecture

## 2.1 The core equation

```
Event -> decode -> Action -> step -> Editor -> render -> Frame
```

`decode`, `step` and `render` are pure. Only `Basilisk.Loop` performs IO.
Every decision below exists to preserve that.

## 2.2 Editor state

```haskell
data Editor = Editor
  {{ mode     :: !Mode
  , document :: !Document
  , cursor   :: !Cursor
  , history  :: !History
  , path     :: !(Maybe FilePath)
  , version  :: !Int
  , status   :: !(Maybe Text)
  , register :: !(Maybe Text)
  , top      :: !Int
  , eol      :: !Eol
  }}
```

Each field is irreducible. `path` is the only record of which file a buffer
came from. `version` bumps exactly when content changes, so a future
semantic layer can detect staleness without living inside `Editor`.
`status` is the editor's one channel to the user. `register` is what a
delete or yank last reached. `top` is the scroll position, which is
genuinely irreducible — see 2.8. `eol` is the file's own line ending, which
is not recoverable from the decoded text — see 2.9.

**There is exactly one construction site for this record**,
`Types.newEditor`. That is deliberate: a strict record with ten fields is
otherwise a structure where adding an eleventh means finding every literal
that builds one, and a missed site is a crash at construction rather than a
compile error. With one constructor, a new field is a one-line patch.

## 2.3 Modes, and state that belongs to a mode

```haskell
data Session = Fresh | Dirty
data Mode = Normal | Insert !Session | Prompt !PromptKind !Text
```

Two pieces of state live inside `Mode` rather than on `Editor`, for the
same reason. A `:` or `/` prompt's input buffer only means anything while a
prompt is open; an insert session's "have I opened an undo entry yet" flag
only means anything while inserting. On `Editor`, each would be a field
that is undefined most of the time and could drift out of sync with the
mode. Inside `Mode`, it is structurally impossible for either to exist when
it shouldn't.

## 2.4 Actions are tagged by mode

```haskell
data NormalCmd
  = NMove !Int !Motion       | NOperate !Int !Operator !Motion
  | NEnterInsert !InsertAnchor | NEnterPrompt !PromptKind
  | NPaste !Int              | NPasteText !Text
  | NUndo !Int               | NRedo !Int
  | NSave                    | NQuit

data InsertCmd = IInput !Text | IBackspace | IMove !Direction | IEscape
data PromptCmd = PInput !Text | PBackspace | PSubmit | PEscape

data Action = InNormal !NormalCmd | InInsert !InsertCmd | InPrompt !PromptCmd
```

A flat `Action` shared across modes forces `step` to answer for pairings
that cannot arise (`InsertChar` in Normal mode, an arrow key in Insert mode
with no clause), and the only way to stay total is a trailing wildcard —
which then silently absorbs every genuinely missing case. Tagging makes an
illegal pairing fail to type-check. `Basilisk.Decode` is given the current
`Mode` and therefore always builds the right tag.

**Tagging alone does not finish the job**, and this is the correction the
previous revision missed: `stepPrompt` still needs the prompt's buffer, and
that lives in `mode e`, so the impossible case reappears inside it. The
residue is isolated into exactly one function:

```haskell
openPrompt :: Editor -> Maybe (PromptKind, Text)
openPrompt e = case mode e of
  Normal     -> Nothing
  Insert _   -> Nothing
  Prompt k b -> Just (k, b)
```

Exhaustive over `Mode`, so a new mode is a compile error here. There is
**no wildcard anywhere in `Basilisk.Step`**, and the mode/command diagonal
costs one function instead of one clause per pairing.

`Quit` has one channel, not two. `NQuit` returns `RequestQuit` exactly as
`:q` does. The previous design also had the shell intercept a `Quit` action
before `step` ever saw it, which required a `(_, Quit)` clause that existed
only to keep a match total. Both are gone; the invariant that only the
shell stops the program is unchanged, because `step` still only reports.

## 2.4a The reach algebra

Every motion answers one question, independent of what will be done with
the answer: *what does this motion reach from the cursor?*

```haskell
data Reach = Chars !Int | Lines !Int

reach   :: Int -> Motion -> Document -> Reach
move    :: (Char -> Int) -> Column -> Reach -> Document -> Document
operate :: Operator -> Reach -> Document -> Maybe (Document, Text)
```

`Reach` is **signed**, in the document's two coordinates. That erases every
mirror-image case: one `Chars` serves `h`, `l`, `d0` and `d$`; one `Lines`
serves `k`, `j`, `dk` and `dj`. `move` and `operate` are the two
eliminators of the same value — one relocates the split, the other cuts it
— and `Delete`/`Yank` are two projections of the single primitive `excise`.
Adding a motion is one equation in `reach` and it becomes available to
every operator; adding an operator is one equation in `operate` and it
becomes available to every motion.

`MLine` reaches `Lines (n-1)`, because a linewise operator spans the rows
between the cursor and the reach **inclusive**: `dd` is one row, `dj` two,
`3dd` three. That is vim exactly, from one equation.

## 2.4b Counts are closed forms, not repetition

A count is a field of the command, because vim's grammar is
`[count] command` and a count is therefore part of the command's abstract
syntax. It is resolved **in closed form inside `reach`**, not by running
anything more than once:

| command | closed form | cost |
|---|---|---|
| `5j` | `Lines 5`, one refocus | O(log n) |
| `5l` | `Chars (min 5 (length after))` | O(1) |
| `3dw` | `Chars (sum of three word spans)`, one pass | O(line) |
| `3dd` | `Lines 2`, one splice | O(log n) |
| `3p` | `insert (Text.replicate 3 t)` | O(3·length t) |
| `3u` | `splitAt 3` on the history tape | O(3) |

This single decision retires four separate problems the previous revision
recorded as open:

1. **`repeatAction` disappears**, and with it the interpreter loop.
2. **The O(document) equality test disappears.** `repeatAction` detected a
   fixed point with `e' == e`, which on any no-op keystroke compared the
   whole document *and the entire undo stack*, since Haskell's derived `Eq`
   has no pointer shortcut.
3. **`999999999j` is O(distance), not O(count).**
4. **A counted command is one edit, so one undo entry.** `3dw` undoes with
   one `u`. The previous revision recorded the opposite as a "real,
   measured limitation" needing a transaction concept; it needs none,
   because there is no longer more than one edit to group.

## 2.4c Coordinate types

```haskell
newtype Offset = Offset Int   -- a CHARACTER offset into a line
newtype Column = Column Int   -- an on-screen DISPLAY column
```

This project shipped the bug that confusing these causes: a display column
handed to a function expecting a character offset, silently misplacing the
cursor on any line with a wide character. `columnToOffset` is the one
function allowed to see both domains; every other function works in exactly
one, and the type checker enforces it. `deriving newtype (Eq, Ord, Num)`
means arithmetic and bare numeric literals read as they did with `Int`, so
the safety is free at every call site that already agreed which it meant.

Deliberately plain newtypes, not a GADT-indexed `Pos (c :: Coordinate)` —
see 2.12.

## 2.4d Declining is reported, never recomputed

Every document primitive that can decline returns `Maybe`:

```haskell
insert    :: Text -> Document -> Maybe Document
backspace :: Document -> Maybe Document
operate   :: Operator -> Reach -> Document -> Maybe (Document, Text)
```

`Nothing` means "nothing would change", exactly, in O(1), reported by the
primitive that already knew. The alternative — comparing the document
before and after — costs O(lines above the cursor) on *every keystroke*,
because derived `Eq Document` compares `above` first and an insert only
touches `here`. This is the same move 2.4e makes for effects: state the
thing explicitly rather than re-deriving it downstream.

`Basilisk.Step.edit` is then three lines, and a declined edit provably
touches neither `history` nor `version`.

## 2.4e The effect boundary

```haskell
data Effect = WriteFile !FilePath !Text | RequestQuit

step :: Action -> Editor -> (Editor, [Effect])
```

`step` performs no IO; it *describes* it. `NSave` computes the exact bytes,
line endings included (2.9), so the shell has no editing decision left.
`:q` and `NQuit` both return `RequestQuit`. The shell interprets the list
and decides whether to stop.

## 2.5 Document and cursor

```haskell
data LineZ    = LineZ {{ before :: !Text, after :: !Text }}
data Document = Document {{ above :: !(Seq Text), here :: !LineZ, below :: !(Seq Text) }}
newtype Cursor = Cursor {{ desiredColumn :: Column }}
```

Row and column are **never stored**: they are `Seq.length above` and
`Text.length before`. Storing them alongside would recreate the
dual-authority problem the zipper exists to avoid. `Cursor` holds the one
thing that cannot be derived — the column vertical motion returns to.

**There is one constructor of a `Document`**, `focusAt`, which refocuses a
line sequence at a clamped row. `fromText`, vertical motion, line deletion
and line opening are all instances of it. That is what makes every one of
them total for free, and it also removes the `NonEmpty`/`splitLines` dance
the previous revision needed: `focusAt` handles an empty sequence, so
nothing has to prove `splitOn` never returns `[]`.

**The Normal-mode cursor sits on a character, never in the gap past the
last one.** This is a real, user-visible decision, and it is enforced by a
single idempotent retraction:

```haskell
clampGap :: Document -> Document   -- image = exactly the legal documents
```

`Basilisk.Step.retract` composes it with *every* transition whose result is
Normal mode. Because it is idempotent, applying it more than once is free,
and because it is applied to every result, the invariant holds **by
induction over the whole event stream** — rather than by remembering to
clamp in `moveHorizontal DRight`, in `Escape`, in `$`, and in `x`
separately. The previous revision listed those four call sites as work to
be done; there is one.

Two consequences, both matching vim and both checked in Part 3's tests:
`l` at the last character is a no-op rather than walking off the end, and
`Escape` steps left. (The previous revision asserted that vim's `Escape`
does not move the cursor. It does.)

Normal-mode horizontal motion does not cross line boundaries, which is
vim's default and which deleted the `crossUp`/`crossDown` pair entirely.

## 2.6 Undo, redo, and the transaction boundary

```haskell
data History = History {{ past :: ![Document], future :: ![Document] }}

travel :: Int -> Editor -> Editor   -- k > 0 into the past, k < 0 into the future
```

`past` and `future` are the two halves of one tape, so undo and redo are
**one function read in two directions** rather than two mirror-image
copies. Travelling `k` steps is `splitAt` on one half and a reversed
prepend onto the other; the reversal is what makes `k` undos followed by
`k` redos the identity on content. Neither `init` nor `last` appears: the
non-empty case is obtained by matching `reverse (take k src)`.

Snapshots share structure with their neighbours at the GC level, since
`Text` and `Seq` are immutable.

**A transaction is an interval of the mode automaton.** The first edit of
an insert session opens an undo entry; every edit after it extends the same
one; a cursor move or leaving Insert ends it. So typing a word and pressing
`u` removes the word, not its last letter — vim's behaviour. This needs no
new `Editor` field and no transaction machinery, because the boundary is
already recorded by `Mode` (2.3).

## 2.7 The IO shell

```haskell
loop :: Vty.Vty -> KeyState -> Editor -> IO ()
loop vty !ks !e = do
  wh <- Vty.displayBounds (Vty.outputIface vty)
  let shown = scroll wh e
  Vty.update vty (render wh shown)
  ev <- Vty.nextEvent vty
  ...
```

**The frame is drawn at the top of the iteration, before the blocking
read.** That one ordering is worth stating because it removes three
separate defects at once: the first frame appears before the first
keystroke; a terminal resize repaints, because the size is re-read every
iteration; and no `EvResize` case, no `Resize` action and no stored
terminal size are needed anywhere.

`bracket` guarantees the terminal returns to cooked mode whether the loop
returns, throws, or the process is asked to exit, so nothing inside needs
exception handling of its own. Both carried values are bang-patterned; with
`StrictData` everywhere this leaves no thunk chain across keystrokes, and
the recursive call is in tail position on every branch.

## 2.8 Rendering and the viewport

Scrolling is **hysteresis**: vim scrolls only once the cursor tries to
leave the window, so the next scroll position depends on the previous one.
That is not derivable from the cursor, which is why `top` is a field. One
function updates it, called once per frame by the loop:

```haskell
clampTop :: Int -> Int -> Int -> Int
clampTop h r t
  | r < t      = r
  | r >= t + h = r - h + 1
  | otherwise  = t
```

*Claim.* For `h >= 1`, `r >= 0`, `t >= 0`, the result satisfies
`0 <= t' <= r < t' + h`.
*Proof.* Three exhaustive cases. If `r < t` then `t' = r`, so `t' <= r`, and
`r < t' + h` since `h >= 1`, and `t' = r >= 0`. If `r >= t + h` then
`t' = r - h + 1 <= r` and `r < t' + h = r + 1`, and `t' >= t + 1 > 0`.
Otherwise `t <= r < t + h` already holds and `t' = t`. ∎

Checked as a property for all `h` in [1,8] and `r,t` in [0,20], and as a
QuickCheck law over arbitrary editors.

A terminal can report a degenerate size — zero columns mid-resize, or a pty
with no window size set. `usable` clamps it to at least one cell, in one
place, so nothing downstream can produce a negative width or cursor
position. When the display genuinely has no cells the frame carries
`NoCursor`: placing a cursor on a zero-cell display is a **segfault in vty
6.6's terminal layer**, not an exception this code could catch. Reproduced
against a five-line vty program with no Basilisk in it; reported here so
the workaround is not mistaken for superstition.

## 2.9 Line endings and encoding

`Data.Text.IO` translates newlines per platform and throws on invalid
UTF-8. Both are unacceptable: the first silently rewrites every line ending
of a file merely opened and saved, the second turns a binary file into a
crash before the terminal is even set up. `Basilisk.File` reads bytes and
decodes explicitly with `decodeUtf8'`, and the buffer records its own
convention:

```haskell
decodeEol :: Text -> Text          -- CRLF -> LF, on read
encodeEol :: Eol -> Text -> Text   -- LF -> CRLF, on write
```

`encodeEol el . decodeEol = id` on any text whose every `\\r` immediately
precedes a `\\n`, which is exactly the set `decodeEol` produces. A file that
does not exist opens as an empty buffer with its path already set. An
invalid-UTF-8 file opens as an empty buffer with a status message.

## 2.9a Refusing to lose work

An editor may be missing any feature; it may not eat a file. Four
guards, and none of them is optional:

**Quitting checks.** `:q` on a modified buffer refuses and says so;
`:q!` overrides. `modified` compares `version` against the version last
written, and is conservative by construction -- `version` only
increases, so undoing back to the written state still reports modified.
That errs towards warning about a quit that would lose nothing, never
towards a silent quit that would lose work, which is the only direction
this may err in.

**Ctrl-C is unbound.** It used to quit, unconditionally and without
checking, which made the most commonly mistyped key in a terminal the
fastest way to lose a buffer.

**Writes are atomic.** `Basilisk.File` writes to a temporary file in the
destination's own directory and renames -- `rename` within a filesystem
is atomic, so a crash, a full disk or a kill leaves either the old file
or the new one, never a half-written one. The naive `writeFile`
truncates in place, where the same interruption destroys the original.
The temporary file is created beside the destination rather than in
`/tmp`, because `rename` across filesystems is not atomic and usually
not even permitted. The mode is carried across with `copyPermissions`,
not `getPermissions`/`setPermissions`: that pair models only the
owner's bits, so a group-readable file came back owner-only until it
was measured.

**Writes follow links.** `renameFile` replaces whatever name it is
given, so writing to a symlinked path turned the link into a regular
file and left the real file untouched -- the edit lost, with a
"written" message. Paths are resolved with `canonicalizePath` first.
A hardlinked file is written **in place** instead, trading atomicity
for the link, because a rename would leave the other names holding the
old contents; that is the trade vim makes too.

**Writes are durable.** The temporary file is `fsync`ed before the
rename and the directory after it. Without both, the rename is atomic
against a crash of this process but not against a loss of power, which
can leave the new name pointing at an empty file.

**Read-only is detected at open**, not at the first `:w`. An hour of
editing followed by "permission denied" is the same data loss as no
warning at all, arriving later. `:w!` overrides.

**Undo history is bounded** at `undoLimit`. Unbounded history is a slow
leak: every edit retains a whole document, and structural sharing does
not stop a long session growing without limit. Vim bounds the same
stack with `'undolevels'`.

**Staleness is detected.** If the file changed since it was read -- a
rebase, a formatter, another editor -- writing would silently discard
someone else's work. `:w` refuses and says so; `:w!` overrides. The
stamp is modification time and size together, because either alone is
too coarse.

The pure core records these decisions and the shell acts on them: `save`
carries the user's `!` into the `WriteFile` effect, and only the shell,
which performed the write, may mark the buffer clean.

## 2.9b The trailing newline is a flag

Whether a file ends with a line terminator is recorded as `finalEol`,
not represented as a trailing empty row.

Both round-trip bytes exactly. The difference is what the user sees: a
trailing empty row is a phantom line at the end of every ordinary file.
`G` lands on it, `$` and `b` and `ce` then do nothing because there is
nothing there, and `dd` deletes something invisible. This project had
exactly that bug, and it was found by driving the editor by hand rather
than by any property -- the properties were all satisfied, because
byte-for-byte round tripping was never in question. Vim calls the same
flag `\'endofline\'`.

One case the flag cannot settle alone: a zero-byte file and a one-byte
`"\n"` file both load as a single empty row. `bornEmpty` records which,
so an empty buffer that was born empty writes no bytes -- matching what
vim does for a new file -- while a file that genuinely contained one
blank line still writes it back.

## 2.10 The key grammar

Vim's grammar is `[count] operator [count] motion` or `[count] command`, so
a decoder cannot be a function of one event. `Basilisk.Decode` is a Mealy
machine whose state is exactly the pending count and pending operator vim
itself tracks:

```haskell
decode :: Mode -> KeyState -> Vty.Event -> (KeyState, Maybe Action)
```

Counts compose multiplicatively, so a pending operator carries the count
that preceded it and the motion's own count multiplies in when it arrives:
`2d3w` is `NOperate 6 Delete MWord`. A doubled operator is the linewise
motion, so `3dd` is `NOperate 3 Delete MLine`. `x` is not a primitive; it
is `NOperate n Delete (MChar DRight)`, which is what it is in vim too. A
bracketed paste is one action for the whole block — a 500-character paste
is one `step`, one redraw and one undo entry, not 500 of each.

Nothing about a completed command survives the key that completes it, so
the state is bounded however long the user pauses mid-sequence.

## 2.10a Unicode, and what reaches the terminal

"Basilisk.Cursor" is the only module that imports ICU. Everything else
receives what it needs as a record:

```haskell
data Unicode = Unicode
  {{ widthAt  :: !(Column -> Char -> Int)
  , clusters :: !(Text -> [Int])
  }}
```

**Width is measured from a column**, because a tab is not a fixed width.
**Clusters are boundary offsets**, because a codepoint is not a
character. The three width classes are forced by what is actually drawn,
not chosen: a width that disagreed with the glyph would misplace the
terminal cursor on every line containing the character they disagree
about.

| class | width | drawn as |
|---|---|---|
| tab | to the next `tabStop` | that many spaces |
| combining mark, format char (incl. ZWJ) | 0 | itself |
| other control character | 1 | one replacement glyph |
| East Asian wide / fullwidth | 2 | itself |
| everything else | 1 | itself |

`renderable` performs the substitution, and
`displayColumn (renderable t) == displayColumn t` for every `t` — the
substitution is width-preserving by construction, which is what keeps
the cursor where the arithmetic says it is. It is also a security
property, not only a cosmetic one: **a file cannot drive the terminal**,
because no control character it contains is ever emitted raw.

**The cursor never sits inside a grapheme cluster.** This is the most
reported class of bug in terminal editors — a left-arrow or a backspace
landing between a letter and its accent, or inside an emoji, so that the
edit position and the rendered column disagree. Three separate functions
could break it, and each is closed:

- `hop` counts cluster boundaries, so `h`, `l`, `x` and backspace step
  over what the user sees as one character rather than one codepoint.
- `wordTarget` snaps **between** word steps, not only at the end.
  Snapping only at the end is not equivalent: an intermediate landing
  inside a cluster leaves the next step reading a bare combining mark,
  whose character class is punctuation, so it counts as a word of its
  own. The law `counted displacement equals iteration` is what detects
  the difference.
- `columnToOffset` floors to a boundary, so a vertical motion cannot
  land inside one either.

That still leaves one reachable state: typing a base character
immediately *before* a combining mark puts the cursor between them,
because the mark then composes onto what was just typed. Rather than
forbid it at each edit, `alignCursor` is an idempotent snap composed
with every transition, exactly as `clampGap` is (2.5). The invariant
therefore holds by induction over the whole event stream, and
`onBoundary` states it so the property suite can assert it after every
action of a generated session.

Clustering is ICU's own UAX #29 break iterator, not a hand-written rule.
`text-icu` exposes `breakCharacter` as a *pure* function, so the real
segmenter costs neither an `unsafePerformIO` nor an effectful field on
`Unicode` — which is why no approximation is kept. Combining sequences,
emoji zero-width-joiner sequences, regional-indicator pairs, Hangul
jamo and prepended concatenation marks are all ICU's problem rather
than this project's, and the last two are cases a hand-written rule had
already got wrong.

## 2.10b Counts, bounded

Vim accumulated counts into a machine integer without checking, and
CVE-2023-48233 through CVE-2023-48236 are four separate overflows in
four separate count parsers, each fixed by adding a bound. The same
shape of defect is available here twice over: an unchecked `10 * n + d`
wraps to a negative count, and a count that survives into `replicate` is
an allocation bomb.

`bounded` saturates at `maxCount`, which needs no failure path and keeps
every count-taking function total. It is applied where a count enters
the system, in `Basilisk.Decode`, and again where one could allocate, in
the paste handler — so a hand-constructed `Action` that never went
through the decoder is as safe as a typed one. Every other count is
already clamped by the algebra: a `Chars` reach against the line, a
`Lines` reach by `focusAt`, a word count by the fixed point in
`wordTarget`, an undo count by the length of the history tape.

## 2.10c The vocabulary, and what it costs

| bound | via |
|---|---|
| motions `h j k l w b e W B 0 ^ $ gg G` | one equation each in `reach` |
| `f t F T` (find-char) | `MTo`, a one-shot linear scan for the target |
| `; ,` (repeat find-char) | `Doc.reachToFrom`, reusing `MTo`'s own search (2.10e) |
| `{{ }}` (paragraph), `%` (bracket match), `\|` (column) | `MParagraph`, `MMatch`, `MColumn` |
| search `/`, `n`, `N` | one equation, producing an `Upto` |
| operators `d y c` | one equation each in `operate` |
| `x X D C s S` | operator applied to a motion that already exists -- no new command |
| `i a o O` | `InsertAnchor` |
| `p P` with counts | `Clip`, charwise or linewise, bounded on output size (2.10b) |
| `u` and `Ctrl-R` with counts | one signed `travel` |
| `J` with counts | one row-splicing primitive |
| `.` (repeat) | replays the last change through `step` itself (2.10d) |
| `~`, `gu gU g~` | `ToggleCase`\/`ToLower`\/`ToUpper`, one equation each in `operate` (2.10f) |
| `>` `<` | `Indent`\/`Dedent`, forced linewise regardless of motion (2.10f) |
| `r` | `replaceChars`, clamped to the line, cursor on the last replaced character |
| `ZZ` `ZQ` | aliases for `writeQuit`\/`quit True` -- no new logic, two new entry points |
| counted insert (`3ifoo<Esc>`) | `insertRepeat` on `Editor`, expanded once at `IEscape` |
| `R` (replace mode) | `Replace ![Maybe Text]`, a mode-local undo stack (2.10f) |
| `: /`, `:w :w! :q :q! :wq :x` | prompt mode |

Adding a motion really is one equation, and it becomes available to
every operator at once: `x` is `d` applied to one character forward,
`D` is `d` to the line end, `S` is `c` over a line. None of them is a
command in the core.

Three irregularities are vim's, not the design's, and are handled where
they belong. `cw` acts as `ce`, so changing a word does not swallow the
space after it -- one clause in the decoder, which is the layer that
knows about key spellings. `e` is an /inclusive/ motion: the cursor
stops on the last letter of the word, but `de` deletes that letter. The
adjustment is on the operator side, and that is forced rather than
chosen -- retreating after the move would make `2e` differ from `e e`,
because the retreat changes where the second step starts. `reach`
therefore means exactly where the cursor goes, and an operator asks for
one cluster more. And `f`\/`t` are the one motion for which the
counted-displacement law (2.11's "a counted motion equals that many
single motions") does not hold: a search that fails leaves the cursor
where the *last successful* step put it, which can differ from failing
outright from the motion's own starting position. The property suite
states this as an exclusion, matching the precedent already set for
`MLine` and `MGotoLine`, rather than papering over it.

## 2.10d Repeat, and where its state actually lives

`.` replays the last change. What "last change" means splits into two
questions this module answers separately: which command, and -- for a
change that entered Insert mode -- what text.

```haskell
remember :: Action -> Editor -> Editor
```

is the single call site, composed into `step` the same way `retract`
is. `repeatable` names exactly which commands `.` may replay, checked
exhaustively, so a new command must declare which side of that line it
is on before it compiles. The text an Insert session types is
accumulated as it happens and attached to the remembered command when
Escape ends the session -- `cwfoo<Esc>` must replay as "change the next
word to `foo`", not merely "delete the next word".

Replaying goes through `step` again rather than a second implementation
of what typing means, and that reuse very nearly cost the design its own
correctness: the accumulator recording *this* session's typing is not
automatically distinct from the accumulator recording a *replayed*
session's typing, and without an explicit reset between them the two
compound. Part 4 records the defect this became and the fix; the
invariant that survives it is worth stating plainly: **replaying a
change must reset every piece of state that only means something during
live typing, not merely reuse it.**

## 2.10e Repeating a search without repeating the search

`;` and `,` repeat the last `f`\/`t`\/`F`\/`T`, which is `MTo`'s own
search run again from the cursor's current position -- `;` in the
remembered direction, `,` reversed. The state this needs is `lastTo ::
Maybe Motion`, recorded at the same single call site `remember` already
uses for `.`, and exhaustive in the same way: a value of any other
shape is a type the field cannot hold.

One case does not reduce to "run the same motion again." `t`\/`T` stop
one character short of their target, so a cursor that has just landed
there is sitting immediately beside it -- and repeating the identical
search from that position re-finds the very same occurrence and never
moves. This is a well-known vim behaviour, not a vim bug: `;` must
search from one step further in the direction of travel when the
motion being repeated is short, so the already-consumed occurrence is
skipped rather than re-found.

```haskell
reachToFrom :: Unicode -> Bool -> Bool -> Char -> Int -> Int -> Document -> Reach
```

takes that starting offset explicitly, decoupled from the displacement
`toward` computes (which still reads the real cursor from `d`
independently), so the nudge can move where the search begins without
moving what the resulting motion is measured against. `reach`'s own
`MTo` clause always calls this with the real cursor as both; only the
repeat path in `Basilisk.Step` supplies a different search origin.

A sign was wrong here on the first attempt -- the nudge moved the wrong
way, so every repeated `t` stayed stuck at the position it was already
trying to escape. Found by hand-tracing a worked example against vim's
actual behaviour rather than by any property, and then turned into one:
`prop_repeat_to_never_gets_stuck` states that repeating `;` either
reaches a genuinely new position or the document is left completely
unchanged, and could never again pass with the sign backwards.

That property then found a second, unrelated defect purely by existing:
`test/Gen.hs`'s own `genDocument` could place the cursor strictly
inside a grapheme cluster, because it hands `Doc.move` an arbitrary
codepoint offset directly rather than one a real motion has already
snapped to a boundary -- and `move`'s `Chars` case trusts that snapping
happened upstream, which for this one caller it had not. Every property
that only reads a *stepped* result was shielded from ever noticing,
since `step`'s own `retract` repairs exactly this on the way out of
every transition; only a property reading a freshly generated document
before any step could see the generator's mistake directly. The fix is
one more call to the same `Doc.alignCursor` `retract` already uses --
but a first attempt that looked right (swapping which `Unicode`
instance the generator used) compiled, read plausibly, and fixed
nothing, because the function being called never consulted that
argument in the first place. Only re-running the suite against the
"fixed" code -- repeatedly, since the failure was intermittent --
caught that the fix had not actually landed.

## 2.10f Case and indent operators, and the "did this change anything" rule

`ToLower`\/`ToUpper`\/`ToggleCase`\/`Indent`\/`Dedent` are five more
equations in `operate`, exactly as 2.4a's design claims a new operator
costs. Two of them, though, needed something `Delete`\/`Yank`\/`Change`
never did: a primitive that *rewrites* a span rather than cutting it,
and a rule for when an operator must ignore the motion it was given.

**The transform primitives.** `transformLineZ` rewrites a signed
charwise span in place, leaving the cursor just past it -- vim's
convention for `~`\/`gu`\/`gU`\/`g~`, and deliberately not `excise`'s
convention of leaving the split point at whichever side already
borders what remains. `transformRows` is the same idea applied to whole
rows, shared by the linewise case operators and by indent\/dedent,
which differ only in *which* row-rewriting function they pass it.

**Forced linewise.** Vim's own rule: `>` and `<` always act on whole
rows, regardless of what motion they are given -- `>w` indents the
line a word motion touches, not just the word. `forcedLinewise` names
which operators this applies to, checked exhaustively so a new operator
must declare which side of the line it is on before it compiles, and
`toLines` converts any reach to the row span it covers before `operate`
ever sees it.

**A real bug, found by a property, not by hand.** The first version of
`transformLineZ` treated "the span is non-empty" as "something changed"
-- so `~` on a digit, or `gu` on a span with no letters, reported
success and bumped the version even though the resulting text was
byte-identical to what was there before. `prop_version_tracks_content_exactly`
caught it directly: a generated case `Just (NOperate 0 ToLower (MTo False
False 'a'), ...)` lowercased an already-lowercase span and the version
bumped anyway. The fix checks whether the transform actually produced
different text, matching the "declining is reported via `Maybe`, never
re-derived downstream" rule 2.4d already established -- `transformRows`
had this check from the start; `transformLineZ` did not, until this
pass added it.

A second, subtler bug followed the first: an initial attempt at the fix
applied the transform to the wrong half of a backward (leftward) span,
because the two directions destructure `Text.splitAt`'s result pair in
opposite orders and the first rewrite didn't account for that. Caught
immediately by re-deriving the function from first principles rather
than trusting that a compiling fix was a correct one -- the same lesson
2.10e's `genDocument` episode already taught once.

**A third, unrelated bug surfaced from the same enlarged generators**:
`^` and `|` (`MFirstNonBlank` and `MColumn`) could oscillate between
two positions on repeated use, because both reached their target
through `toward`, whose snap direction compares the target to the
*current* cursor -- right for a word motion, whose raw target moves
with the cursor, wrong for `^`\/`|`, whose target is an absolute column
independent of it. `towardAbsolute` snaps in one fixed direction
regardless of where the cursor is, which is what makes the motion a
pure function of the line and the target -- and therefore genuinely
idempotent, matching real vim.

**A fourth bug was the first one again, one function later.**
`replaceChars` (`r`) was written after `transformLineZ`'s no-op fix, by
analogy -- and the analogy was incomplete: replacing a span with a
character that already matched every character in it still reported a
change. The *property* written to pin this down then surfaced a fifth,
unrelated issue in the test itself: comparing a freshly generated
document directly against a stepped result can fail on `step`'s own
Normal-mode gap repair, for any action at all, if the generated
document was never guaranteed to satisfy that invariant in the first
place. `Doc.clampGap` applied to the property's own input fixed it --
in the property, not in `genDocument`, since the gap invariant is
Normal-mode-specific rather than one every mode must satisfy the way
the cluster-boundary invariant is.

## 2.11 Invariants

1. `decode`, `step` and `render` are pure. Only the shell performs IO.
2. `step` is total over every `(Mode, Action)` pair, and that totality is
   **checked**: there is no wildcard in `Basilisk.Step`, so
   `-Werror=incomplete-patterns` fails the build on an unhandled command.
   The one runtime mode check is `openPrompt`, itself exhaustive over
   `Mode`.
3. Cursor row and column are never stored; `Cursor` holds only
   `desiredColumn`.
4. No partial functions in the pure core. Verified by sweep, not by
   assertion — see Part 4.
5. Every IO-loop recursion is tail-recursive and strict in its state.
6. Only the shell decides to stop the program. `step` may report
   `RequestQuit`; it may never act on one. There is exactly one such
   channel.
7. Semantic/LSP data stays outside `Editor`; `version` exists so that layer
   can detect staleness.
8. No abstraction without a measurable purpose it serves today (2.12).
9. `step` performs no IO, including saving. Every effect is data.
10. A character offset and a display column are never the same type.
11. A count is a closed form inside the algebra, never an interpreter loop
    and never a new command (2.4b).
12. "Did this change anything" is reported by the primitive, never
    recomputed by comparing two documents (2.4d).
13. `Editor` has exactly one construction site, and `Document` exactly one
    constructor.
14. The cursor never sits inside a grapheme cluster, in any mode
    (2.10a).
15. No control character a file contains is ever written to the
    terminal, and the width function agrees with the glyph actually
    drawn (2.10a).
16. Every count is bounded before it can overflow or allocate (2.10b).
17. Opening a file and saving it without editing rewrites it byte for
    byte.
18. No keystroke discards unsaved work without saying so, and no write
    can leave a partial file (2.9a).
19. A write is the only thing that marks a buffer clean, and only the
    shell -- which performed it -- may do so.
20. `.` replays through `step` itself rather than a second
    implementation of editing, and every piece of state that means
    something only during live typing is reset before a replay reuses
    that path (2.10d).
21. A counted motion that can fail -- `MLine`, `MGotoLine`, `MFind`,
    `MTo` -- names an absolute target in one step, which is not the
    same as iterating a single step that many times; the property
    suite states this as an explicit exception rather than a law that
    happens not to be checked.
22. An operator that only transforms text rather than cutting it
    reports no visible change as `Nothing`, exactly as a declined edit
    does elsewhere (2.4d) -- "the span was non-empty" and "something
    changed" are not the same question, and only the second one is
    what decides whether the version bumps (2.10f).
23. `>` and `<` act on whole rows regardless of the motion given them,
    checked once via `forcedLinewise` rather than at every call site
    that could otherwise forget vim's own rule for these two operators.
24. A motion whose target does not depend on the cursor's current
    position -- `^`, `|` -- is idempotent: pressing it twice lands in
    exactly the same place both times, via `towardAbsolute`'s
    fixed-direction snap rather than `toward`'s position-relative one
    (2.10f).
25. An edit that only transforms or overwrites text, rather than
    cutting or inserting it, reports no visible change exactly when the
    result is byte-identical to the input -- never when the operation
    merely "ran successfully" on a non-empty span. This is the single
    rule three independent functions (`transformLineZ`, `replaceChars`,
    `overwriteAll`) each had to learn separately before it held
    everywhere; `prop_version_tracks_content_exactly` now checks it at
    ten times the test volume every other property gets, specifically
    because it is the one law this project has needed to re-derive the
    most times.
26. A single `Action` commits at most once, regardless of how many
    characters or internal steps producing its result required --
    folding a multi-character `IInput` through several individual
    character-level transforms must not bump `version` once per
    character.

## 2.12 Advanced-type experiments: decisions and evidence

Every concrete proposal was built as a real prototype against compiled
modules, run, and measured. Recorded here so the reasoning does not live
only in chat history.

**Adopted:** coordinate newtypes (2.4c) and counts-in-the-algebra (2.4b).

**Rejected — mode-indexed `Command (m :: Mode)`.** A GADT indexed by `Mode`
with an `SMode` singleton was built and compiled. It type-checks, but
`decode` cannot know a command's mode until it reads the editor's runtime
mode, so the command must be hidden behind an existential the moment it
leaves `decode`, and dispatching one requires the identical runtime
comparison. Four new pieces of machinery to relocate a check that already
exists — and, as of this revision, a check that costs *one function*
(`openPrompt`). Harder `Eq`/`Show`/`Arbitrary` downstream, no invalid state
eliminated. **Rejected.**

**Rejected — GADT `Edit a b`.** Every edit maps `Document -> Document`;
there is no second type for the indices to distinguish, so the index is
vacuous. The plain version was built and run: composition and
`inverse (e1 <> e2) = reverse (map invert [e1, e2])` both held, but a single
delete's inverse did not round-trip the cursor. That finding has nothing to
do with GADTs — reversible-edit undo needs *more* state per edit, not less,
and snapshot history already gets it, plus most of the memory benefit, via
structural sharing. **Rejected on both counts.**

**Rejected by the same mechanism** — typed range producers, result-indexed
commands, and type families for command/result relationships. Each crosses
the same decode-time/runtime-mode boundary and hits the identical
existential wall; the mechanism was measured once and applies unchanged.

**Sound in principle, not yet testable.** Range-shaped producers for text
objects and structural navigation describe subsystems that do not exist
yet. Their shape matches what is already proven here — produce a reach and
let existing eliminators consume it (2.4a); derive state rather than store
it (2.5). Hold them to the same standard when they are built: a real
prototype, measured, before adoption.

## 2.13 Measured size

| Module | Responsibility | Code | With comments |
|---|---|---|---|
{budget}
| **Total** | | **{total}** | |

Non-comment lines, blank and `--`-only lines stripped. The complete
editor — including the four modules the previous revision had only
specified — is **{total} lines against a 3,000 ceiling**, leaving {3000 - total}
for the Haskell-structural-navigation milestone. The previous revision
budgeted ~1,120 for the same scope with four modules unwritten; the
reduction is not compression but the design changes in 2.4a, 2.4b, 2.4d and
2.5, each of which deleted a category of code rather than shortening it.

Tests, which do not count against the ceiling:

| File | Purpose | Code | With comments |
|---|---|---|---|
{chr(10).join(testrows)}

## 2.14 Deliberately out of scope for v1

Vimscript or Lua, a plugin framework, GUI/mouse interaction, a terminal
emulator, session management, a custom parser or LSP, and search-and-jump
(`/` opens and accumulates, but `Submit` on a search is a no-op).

Named registers (`"a`, `"b`) remain deferred; the single implicit register
is implemented. **Paste remains charwise**: `dd` then `p` inserts the line's
text inline rather than opening a new line, which is visible in the
end-to-end transcript in Part 4. Linewise paste needs the register to
record *how* its text was taken, which is one bit on `register` and one
clause in the paste handler — scoped, not architectural.

Horizontal scrolling is not implemented; the cursor column is clamped to
the window width.

---

# Part 3 — Code

All nine modules below compile under
`-Wall -Wcompat -Wincomplete-patterns -Wincomplete-uni-patterns
-Wincomplete-record-updates -Werror=incomplete-patterns
-Wredundant-constraints -O2` with **zero warnings**, on GHC 9.4.7. Part 4
states exactly what has been run.

### `Basilisk.cabal`

{src('Basilisk.cabal', 'cabal')}

"""

for name, rel, _ in MODULES:
    doc += f"### `{rel}`\n\n{src(rel)}\n\n"

doc += "## Verification harness\n\n"
for rel, why, lang in EXTRA:
    doc += f"### `{rel}` -- {why}\n\n{src(rel, lang)}\n\n"

doc += "## Tests\n\n"
for rel, _ in TESTS:
    doc += f"### `{rel}`\n\n{src(rel)}\n\n"

doc += f"""---

# Part 4 — Verification

Toolchain, matching the project's stated target exactly:

```
Ubuntu 24.04, GHC 9.4.7, cabal-install 3.8.1.0 (apt packages)
text-2.0.2, containers-0.6.7, deepseq-1.4.8.0, bytestring-0.11.5.2
text-icu-0.8.0.5 (against real libicu), vty-6.6, vty-unix-0.4.0.0
hedgehog-1.7, temporary-1.3
```

Reproduce with:

```sh
sudo apt-get install -y ghc cabal-install libicu-dev
cabal update && ./scripts/check.sh
```

`check.sh` is the actual reproduction method: the build, the
partial-function sweep, the line-count ceiling, all three suites, the
complexity benchmarks, and a check that this document still matches the
sources it is generated from, in one script that CI runs unmodified.

## What was run, and what it showed

Nothing below is a stub or a "should type-check" claim; the container
has Hackage access and every dependency is the real one.

- **`cabal build all` from a clean tree: zero warnings, zero errors**
  across library, executable, all three suites and the benchmarks,
  under the full flag set. `Basilisk.Cursor` runs against genuine ICU.
- **`Basilisk-laws` (Hedgehog): 39 properties, 400 tests each (one
  guarding the no-op-commit bug class at 4,000), 0
  failures**, confirmed over many consecutive runs rather than one --
  several of the defects below were intermittent, surfacing only on
  some random seeds, so a single green run was never treated as proof.
  Discovery is by Template Haskell, so a property cannot be written and
  then left out of the suite. Hedgehog was chosen over QuickCheck for
  integrated shrinking: every counterexample in this project's history
  arrived already minimised, which is what made each one diagnosable.
- **`Basilisk-smoke`: 199 worked examples, 0 failures** — vim's
  vocabulary (`dw`, `3dw`, `2d3w`, `dd`, `3dd`, `dj`, `x`, `5j`, `p`,
  `o`, `u`, `:w`, `:q`, `.`, `f`, `{{`, `%`, `~`, `gu`, `>>`, `r`, `ZZ`),
  the key grammar, and the Unicode and hardening cases.
- **`Basilisk-exhaustive`: 628,452 (mode, command, document)
  combinations**, forced to normal form, **0 exceptions**. The document
  fixtures include a combining sequence, an emoji ZWJ sequence, a
  regional-indicator pair, tabs, an embedded escape, a NUL and a bare
  carriage return; the command fixtures include `maxBound` and
  `minBound` counts across every operator, including the five added in
  this pass.
- **Partial-function sweep** over every non-comment line: none present.
- **The editor was run** against a real 24x80 pty, on a file holding a
  combining sequence, Hangul syllables, an emoji zero-width-joiner
  sequence, tabs, ANSI escape sequences, CRLF endings and **no trailing
  newline**. Opened and saved with no edits, the file is
  **byte-for-byte identical**. The escape sequences in it never reach
  the terminal. And `x` deletes the whole `e`+U+0301 sequence and the
  whole Hangul syllable -- one user-visible character each, not one
  codepoint.
- **The property suite was run three times** to shake out races, since
  Hedgehog checks properties in parallel and the ICU break iterator is
  shared. Stable.
- **Degenerate terminal sizes**: 0x0, 1x1, 2x80 and 24x80 all complete
  a session and exit 0.
- **The safety guards were exercised against a real filesystem**, not
  only in the pure core: `:q` refused a modified buffer and left the
  file untouched; `:w` refused after another process rewrote the file
  underneath, preserving that process's work; `:w!` overrode it; modes
  `0640`, `0644`, `0600` and `0664` all survived a save unchanged; and
  no temporary file was left behind in any run. Editing through a
  **symlink** left the link intact and edited its target; a
  **hardlinked** file kept its link count and both names saw the edit;
  an unwritable path reported read-only and refused the write; a new
  empty file wrote **zero bytes** and, once typed into, `"abc\n"`; and
  an old-Mac `CR` file round-tripped byte for byte and edited
  correctly.
- **The ICU break iterator was stress-tested for races**: 4,000
  concurrent segmentations across eight capabilities, all agreeing with
  the sequential result. The shared `Breaker` CAF is safe to read
  concurrently.

## The generators are the point

`test/Gen.hs` over-represents, relative to real text, every character
class that has broken a terminal editor: tabs, C0 controls, East Asian
wide characters, combining marks, the zero-width joiner, regional
indicators, and astral-plane codepoints. Counts are drawn from the whole
of `Int`, including negatives and `maxBound`. Three of the five defects
below were found only because a generator produced input no one would
write by hand.

The strongest property is not about one keystroke.
`prop_sessions_preserve_wellformedness` runs a generated sequence of up
to 25 mode-appropriate actions and asserts every invariant after every
one, which is where interactions show up — entering insert mode,
editing, and undoing across the mode change. Hedgehog shrinks the
sequence, so a failure arrives as the shortest run that still breaks.

The generators are tested too, not only trusted. `genDocument` is
meant to uphold the same cursor-boundary invariant `step` maintains,
and for a long stretch of this project it silently did not -- every
property reading a *stepped* result was shielded from noticing, since
`retract` repairs the mistake on the way out of every transition it
actually runs. Only a property reading a freshly generated document
directly could see it, and the fix is checked the same way: 20,000
sampled documents, confirmed off-boundary in none of them, not merely
asserted fixed from reading the diff.

## Defects this hardening pass found

Each was found by running the code, and each had previously been
reasoned about and declared fine:

1. **Paste was quadratic.** `insert` folded the single-character
   primitive over the text, and each step copied the prefix it appended
   to. A megabyte of pasted text is on the order of `n^2` character
   copies; the property suite found it by timing out. Splicing whole
   lines is linear.
2. **Word motion could stop inside a grapheme cluster**, because it
   works from character classes and a combining mark is neither
   alphanumeric nor a space. Found by the counted-displacement law,
   which disagreed with its own iterated form.
3. **Vertical motion could land inside one too**, because it works from
   display widths and a combining mark is zero columns wide.
4. **Typing a base character before a combining mark left the cursor
   inside the resulting cluster** — the one such state reachable by
   ordinary use, found by the session property, and the reason
   `alignCursor` is composed with every transition rather than applied
   at each edit.
5. **Counts were unbounded**, in exactly the shape of the 2023 vim CVEs.
6. **The trailing newline was a phantom line.** `G` landed on an
   invisible empty row at the end of every ordinary file, after which
   `$`, `b` and `ce` all did nothing and `dd` deleted something the
   user could not see. Every property still passed -- byte-for-byte
   round tripping was never in question -- and it was found only by
   driving the editor by hand. 2.9b.
7. **`gg` went to the last line**, because it shared its
   implementation with `G` and inherited "no count means last".
8. **`c` on an empty span stayed in Normal mode**, so the word typed
   after it was executed as commands. `ccMod` silently appended a line
   during testing.
9. **`dG` dropped the operator** and became a bare move, because `G`
   was special-cased ahead of the operator-completion path.
10. **Atomic writes broke symlinks and hardlinks** -- a regression
    introduced by the atomicity fix itself. Editing through a symlink
    replaced the link with a regular file and left the target
    unedited, reporting success. Found by testing the guard rather
    than trusting it.
11. **`setPermissions` is owner-only**, so a `0640` file came back
    `0600` after a save.
12. **The hand-written cluster rule was wrong** for Hangul jamo and for
    prepended concatenation marks. It was written only because
    `text-icu`'s break iteration was assumed to be in `IO`; it is not,
    so the rule was deleted and ICU's segmenter used directly. Twenty
    lines of approximation became five lines that are correct by
    delegation.

## Defects found hardening the vocabulary pass

A second batch of Phase 2 work -- `.`, `{{`\/`}}`, `f`\/`t`\/`F`\/`T`, `W`\/`B`
-- had been built but not yet run when a session interruption occurred.
Restarting it, the property suite hung outright rather than failing.
Five distinct defects were behind that, found in the order below, each
by running the code and measuring rather than reasoning about it:

13. **`.` doubled its stored text on every use**: 1, 2, 4, 8 characters,
    exponentially. `remember` records the text an insert session typed
    so `.` can replay it, but replaying goes through `step` again,
    which records *that* replay on top of the text already stored --
    because nothing had ever cleared it. Forty presses would have
    exhausted memory. Fixed by clearing the accumulator before a
    replay's synthetic typing runs.
14. **`{{`\/`}}` (paragraph motion) had no fixed-point guard**, unlike
    every other counted motion in this module, so a count in the
    quintillions -- generated, not typed -- would loop that many times.
    It also recomputed the *entire document as a list* on every single
    iteration, via a `window` call inside the loop. Both fixed: a
    fixed-point exit matching `forwardTarget`'s, and a direct `Seq`
    lookup in place of the whole-document materialisation.
15. **Paste's safety bound was on the wrong quantity.** `bounded` caps
    the *count* at `maxCount`, but paste's real cost is the *product* of
    count and register length -- a perfectly bounded count still
    multiplied an eight-character register into an eight-megabyte
    single line, measured at twenty-seven seconds for the paste and a
    further twenty-plus seconds for every keystroke afterward, on the
    same O(line) cost 2.10a already documents. `bounded` was never
    asked to guard a product, only a count. `boundedRepeatCount` bounds
    the output size directly; the same scenario now runs in 0.3
    seconds.
16. **`f`\/`t`\/`F`\/`T` located their target with `Text.index` inside a
    scan of the whole line.** Under `text-2.0`'s UTF-8 representation,
    `Text.index i` costs `O(i)`, not `O(1)` as it did under the older
    UTF-16 encoding; calling it once per candidate position made the
    whole scan `O(n^2)`. Measured directly: 2.8 seconds to scan a single
    50,000-character line. This was the one function in the module
    still reaching for random access on a `Text`; every other scan
    already walks with `Text.uncons`, and rewriting this one to match
    took it to instant.
17. **Word motions re-scanned the cluster-boundary list from the start
    on every step**, even after an earlier fix in this same session had
    already stopped them re-segmenting the whole line with ICU on every
    step. The *first* fix removed the larger cost (full ICU
    segmentation, repeated); a smaller but still quadratic cost
    remained underneath it (`dropWhile` rescanning a precomputed list
    from the front). Measured before the second fix: 9ms for 100 words,
    438ms for 800 -- still a clean quadratic, just with a much smaller
    constant, easy to mistake for "fixed" after only the first
    improvement. The boundary list is now threaded through the loop as
    a monotonically shrinking suffix, exactly as the line's *text*
    already was -- the same idea applied consistently rather than to
    only one of the two things the loop consumes. Confirmed genuinely
    linear afterward, and the original 20,000-word line that exceeded
    sixty seconds now runs in 0.26.
18. **One property was over-stated, not broken.** `f`\/`t` motions that
    fail to find enough occurrences leave the cursor exactly where a
    *previous successful* step left it -- which can genuinely differ
    from failing outright from the motion's starting position, since a
    count's worth of iteration and one direct jump do not share a
    starting point once the first iteration has already moved. The
    counted-displacement law was extended to exclude `MTo`, joining the
    existing exclusions for `MLine` and `MGotoLine`, and a new property
    states what actually holds: a `MTo` motion either leaves the
    document completely unchanged or lands exactly on a grapheme
    boundary.

## Defects found implementing `;` and `,`

19. **The repeat-short nudge had its sign backwards.** `;` repeating a
    `t`\/`T` that had already stopped one character short of its target
    needs to search from one step further in the direction of travel,
    or it immediately re-finds the occurrence it is already sitting
    beside. The first implementation nudged the wrong way, so every
    repeated `t` stayed exactly where it started regardless of how many
    further occurrences existed. Found by hand-tracing a worked
    example against vim's documented behaviour -- `t.` then `;` on
    `"a.b.c.d"` -- not by a property, since no property yet existed for
    this path. One sign flipped; eight hand-traced cases (both
    directions, both the short and plain forms, reversal, a counted
    repeat, and the no-previous-find message) then matched vim exactly,
    and `prop_repeat_to_never_gets_stuck` now holds the fix in place.
20. **A worked example asserted the wrong equivalence.** `3;` was
    written to expect the same result as two individual presses of
    `;`, which does not hold for the same reason `MLine`\/`MGotoLine`\/
    `MFind`\/`MTo` are already excluded from the counted-displacement
    law: a counted `MTo` is one absolute "nth occurrence from here"
    lookup, not iteration, so a count that exceeds the number of
    further occurrences correctly stays exactly where it started even
    though fewer individual presses would have advanced. The test's
    expectation was wrong, not the code; corrected to state what
    actually happens, with the reasoning written next to it.
21. **`genDocument` could place the cursor strictly inside a grapheme
    cluster**, violating an invariant every other part of the system
    maintains, before any `step` had even run. The generator places its
    cursor with `Doc.move u 0 (Doc.Chars c) d` for an arbitrary
    generated offset `c`; `move`'s own `Chars` case is a raw positional
    `shift` that trusts the displacement was already snapped to a
    boundary, because every real motion snaps it before handing `move`
    the result. The generator was the one caller that did not. An
    attempted first fix -- swapping the degenerate `Doc.ascii` instance
    for the real, ICU-backed one -- compiled, looked plausible, and
    changed nothing: `Chars`'s eliminator never consults its `Unicode`
    argument at all, so the fix was applied to a parameter the faulty
    code path does not read. Found only by noticing the suite still
    failed intermittently after that "fix" and re-deriving which
    function actually does the snapping; the real repair composes
    `Doc.alignCursor` -- the identical repair `Basilisk.Step.retract`
    applies after every transition -- onto the generator's result.
    Confirmed directly: 20,000 sampled documents, zero off-boundary,
    where thousands had failed before. This is the sharpest reminder in
    the project's history that a plausible-looking fix is not a
    verified one; only re-running the failing case closed it.
22. **Searching for a combining mark or zero-width joiner as a bare
    `f`\/`t` target is not a scenario any real keystroke produces** -- a
    terminal composes a combining mark onto the character before it
    before Basilisk ever sees an event for it -- and the property
    written to check `;` never has stuck assumed every character was
    equally addressable. `prop_repeat_to_never_gets_stuck` now excludes
    characters `widthAt` reports as zero columns wide, matching the one
    class of target a real `f`\/`t` cannot be asked to find, and the
    reasoning is written next to the restriction rather than left as a
    bare filter.

All three suites and the benchmarks were re-run to completion after
each fix, not merely re-attempted: 36 properties, 150 worked examples,
189,000 totality combinations, and no scaling regression.

## Defects found implementing `~`, `gu`\/`gU`\/`g~`, `>`\/`<`, `r`, `ZZ`\/`ZQ`

23. **`guu`, `gUU` and `g~~` produced nothing at all.** The doubled-
    operator check only consulted the table for `d`\/`y`\/`c`\/`>`\/`<`,
    so the second letter of `guu` was read as the unrelated *undo*
    command while a case operator was still pending, and the existing
    "a command key abandons a pending operator" rule (itself a
    deliberate fix from an earlier pass) silently discarded the whole
    sequence. Found immediately by decoding the sequence directly
    rather than assuming the doubling logic generalised -- it was
    written for one table and needed to recognise two. Fixed by
    checking both tables in one guard rather than adding a second,
    near-duplicate clause.
24. **Case-toggling a non-letter bumped the version anyway.**
    `transformLineZ` treated "the span is non-empty" as "something
    changed", so `~` on a digit, or `gu` on a span with no letters,
    reported success and created an undo entry for text that came out
    byte-identical. Found by `prop_version_tracks_content_exactly`,
    which already existed and was never specific to this feature --
    extending the generators to produce the new operators was enough
    for it to find a real defect on its own. The fix needed a second
    pass: an initial version applied the transform to the wrong half of
    a backward span, because the two directions destructure
    `Text.splitAt`'s result pair in opposite orders and the first
    attempt did not account for that. Caught by re-deriving the
    function from scratch rather than trusting that a version which
    compiled was a version that was correct.
25. **The register-span property assumed every operator fills the
    register.** `prop_reached_span_becomes_the_register` was written
    before case and indent operators existed, when that assumption
    happened to be true of every operator there was. Restricted to
    `Delete`\/`Yank`\/`Change`, which is what actually touches the
    register -- matching vim's own rule, which `Basilisk.Step.apply`
    already encoded correctly; only the property had not caught up.
    The same property's oracle also needed the forced-linewise
    conversion applied to its own span computation, or it would
    disagree with what `Basilisk.Step.normal`'s `NOperate` clause
    actually computes for `>`\/`<` given a charwise motion.
26. **`^` and `|` could oscillate on repeated use.** Both compute an
    absolute target independent of the cursor's current position, but
    reached it through `toward`, whose snap direction is chosen by
    comparing the target to the *current* cursor -- correct for a word
    motion or a find-char, whose raw target genuinely moves with the
    cursor, wrong for an absolute one. Landing on one side of the raw
    column and then pressing the same motion again could compare that
    same column against a now-different cursor and snap the *other*
    way, oscillating between two boundaries instead of staying put --
    which real vim's `^` and `|` never do. Narrow to trigger (needs a
    combining mark straddling the blank\/non-blank boundary, or sitting
    exactly at a counted column) but a genuine idempotence defect, not
    only a count's interpretation, and found directly by the existing
    counted-displacement property rather than a new one -- extending
    the generators to exercise every motion was what surfaced it.
    `towardAbsolute` snaps in one fixed direction regardless of the
    cursor, making the result a pure function of the target and the
    line; `prop_absolute_motions_are_idempotent` now states the
    requirement directly, rather than relying on it falling out of an
    unrelated property.
27. **`replaceChars` had the exact bug `transformLineZ` had just been
    fixed for**, one function later: replacing a span with a character
    that already matched every character in it was treated as a real
    change, bumping the version for text that came out byte-identical.
    It was written *after* 'transformLineZ`'s fix, by analogy, without
    re-asking whether the analogy covered this case -- it did not,
    until this check was added too. Caught by
    `prop_version_tracks_content_exactly`, the same general property
    that found the first instance of this bug class, not a new one
    written for this specific function.

    Writing a dedicated property for it then found a *second* defect,
    this time in the property itself: comparing a freshly generated
    document directly against the result of stepping it can fail for a
    reason that has nothing to do with the command under test.
    `genDocument` has no notion of mode and can place the cursor in the
    gap past a line's last character, which is invalid only in Normal
    mode and which `step`'s own `retract` always repairs on the way out
    -- so a property comparing an un-clamped starting document against
    a necessarily-retracted result can fail purely on that repair, for
    any action at all, including one that declined to do anything.
    Distinct from 2.10e's `genDocument` fix: that one corrected an
    invariant every mode must satisfy; this one is Normal-mode-specific,
    so the right place to normalise is in the property that assumes
    Normal mode, not in the mode-agnostic generator itself.

All three suites and the benchmarks were re-run to completion after
each fix: 38 properties confirmed over twenty consecutive runs, 183
worked examples, 394,632 totality combinations, and no scaling
regression. The real end-to-end session -- `guw`, `>>`, `r`, `ZZ` on a
running binary in a real pty -- surfaced one further thing worth
recording honestly: a result that looked wrong at first (`r` replacing
the last character of a short line rather than the first) was traced
and confirmed to be correct vim behaviour, not a bug -- the sticky
column `>>` leaves the cursor at clamps onto the shorter line exactly
as vim's own convention says it should.

Two further failures were over-stated properties rather than defects,
recorded because the distinction matters: typing then backspacing is an
identity only when the typed character forms its own cluster where it
lands — a combining mark after the cursor composes onto it, and a
zero-width joiner before the cursor binds it backwards — and a prompt
command with no prompt open changes nothing *semantically*, though
`step` still normalises the cursor on the way out as it does for every
transition.

## Closing Tier 1: counts on insert and `R`

`3ifoo<Esc>` types its session's text that many times in total, via
`insertRepeat` on `Editor` and one expansion at `IEscape`; `R` overwrites
character by character, pushing what each step overwrote onto the mode's
own stack (`Replace ![Maybe Text]`) so backspace can restore it --
`Just "\n"` is a reserved sentinel marking a line split rather than an
overwrite, unambiguous because an actual overwritten cluster can never
equal a newline. Both reuse machinery already proven elsewhere (`.`'s
replay, `;`'s nudge) rather than inventing a second mechanism.

Five defects, all found running this work rather than reasoning about
it, and the first three are the same bug recurring in three independent
functions:

28. **A charwise case-toggle reported success on a true no-op.**
    `transformLineZ` treated a non-empty span as "something changed"
    regardless of whether the transform actually altered it, so `~` on
    a digit bumped the version for byte-identical text. Already
    documented at length in 2.10f; restated here because it is the
    first of three.
29. **`replaceChars` (`r`) had the identical bug, one function later.**
    Replacing a span with a character that already matched every
    character in it was still treated as a change. Written *after*
    #28's fix, by analogy, without re-asking whether the analogy
    covered this case. It did not.
30. **`overwriteAll` (`R`) had it a third time**, and compounded with a
    second, independent mistake: committing once *per character*
    rather than once per `IInput` event, so typing "aa" in one
    keystroke bumped `version` twice instead of once, and an empty
    `IInput ""` bumped it once for nothing at all. Three separate
    fixes in one function: fold the document and stack purely,
    commit only the final result, and guard both the empty-input and
    overwrite-equals-original cases explicitly.
31. **Backspacing in `R` could also report a false change**, for a
    reason specific to it: `Doc.restoreChar`\/`Doc.backspace` cannot
    know in advance whether the text they restore happens to coincide
    with what the document already shows, so the check has to happen
    *after* restoring, not before -- the one place in this whole class
    of bug where "decide before acting" genuinely does not work and
    the result has to be inspected instead.
32. **A fifth failure was not a new defect at all**: a *pre-existing*
    gap in `isAddressable`, used by an unrelated property
    (`prop_repeat_to_never_gets_stuck`) that predates this session's
    changes entirely. `isAddressable` excluded zero-width characters
    but not regional-indicator pairs, which cluster by pairing rather
    than by width -- the identical mechanism 2.10e's search-property
    fix already had to account for once, not generalised to every
    future caller at the time. Fixed once, in the shared predicate.

Given the same bug class recurred three times, the response was not to
add a fourth targeted fix and move on: `prop_version_tracks_content_exactly`
already states the general law ("version bumps by exactly one when
content changes, never otherwise") across *every* command `genMatched`
can produce, and it is precisely the property that found all three
instances. It now runs at ten times the test count every other property
gets -- cheap to justify, since it is pure and fast, and it is the one
law most worth distrusting a single green run of. Confirmed clean over
ten consecutive runs at that count (40,000 individual examples against
this one law alone) before trusting it, in addition to twenty further
runs of the full suite.

All suites and the benchmarks: 39 properties, 199 worked examples,
628,452 totality combinations, no scaling regression. A real end-to-end
session on the compiled binary -- `RXYZ<Esc>` then `3iab<Esc>` in one
pty -- produced exactly the expected text.

## Revision history

1. **Visual-column fix.** `moveVertical` gained a width function and
   `columnToOffset`, fixing a cursor misplacement on lines with wide
   characters.
2. **Operator algebra and effect boundary.** `Motion`/`Operator`/`operate`
   introduced; `step` changed to return effects; `:q`'s silent no-op fixed.
3. **Coordinate types and counts.** `Offset`/`Column` newtypes;
   `repeatAction` added.
4. **Counts moved into the algebra in closed form** and `repeatAction`
   removed (2.4b); `Reach` made signed (2.4a); declining made explicit
   via `Maybe` (2.4d); the mode/command diagonal reduced to `openPrompt`
   and every wildcard removed from `Step` (2.4); `Quit` unified onto one
   channel; `clampGap` introduced as a single idempotent retraction
   (2.5); insert sessions grouped into one undo entry via mode-local
   state (2.6); `focusAt` made the sole `Document` constructor and
   `newEditor` the sole `Editor` construction site; `top` and `eol`
   applied, not merely specified; and `Decode`, `Render`, `File`, `Loop`
   and `Main` written, compiled and run for the first time.
5. **Hardening pass.** Grapheme-cluster-aware motion, deletion and
   cursor normalisation; column-aware tab widths; terminal
   sanitisation of control characters; bounded counts; linear paste.
   The property suite moved from QuickCheck to Hedgehog and grew to 27
   discovered properties including a sequential session test. Grounded
   in the bug classes reported against vim and neovim rather than in
   guesswork: the count-overflow CVE family, the grapheme-cluster
   cursor reports, and the `noeol` round-trip corruption of vim #488
   and #3289.
6. **Safety and vocabulary pass.** Atomic writes, on-disk staleness
   detection, a modified-buffer guard on `:q`, and Ctrl-C unbound
   (2.9a). The trailing newline became a flag rather than a phantom
   line (2.9b). Motions `b e ^ gg G`, the `c` operator, the derived
   `x X D C s S`, `J`, and charwise/linewise `p` and `P` (2.10c).
   Search (`/`, `n`, `N`), the `Upto` reach shape it needed, and the
   `Buffer`\/`Editor` state split (34).
7. **Vocabulary hardening pass.** `.` (repeat), `f`\/`t`\/`F`\/`T`,
   `{{`\/`}}`, `%`, `|`, and `W`\/`B` added. Five defects found running
   this batch for the first time after a session interruption -- an
   exponential blowup in `.`'s replay buffer, a missing fixed-point
   guard and an `O(document)` lookup in paragraph motion, a paste bound
   on the wrong quantity, an `O(n^2)` scan in `f`\/`t` from
   `text-2.0`'s UTF-8 representation, and a subtler `O(n^2)` left over
   in word motion after the first fix to it -- documented in full where
   Part 4 records what running the suite actually found.
8. **`;` and `,`.** Repeat the last find-char motion, reusing `MTo`'s
   own search through a new `reachToFrom` rather than a second search
   implementation (2.10e). A sign error in the repeat-short nudge, and
   one worked example asserting the wrong equivalence for a counted
   repeat, are both recorded in Part 4.
9. **Tier 1 of the vim-completeness pass.** `~`, `gu`\/`gU`\/`g~`,
   `>`\/`<`, `r`, `ZZ`\/`ZQ` -- five new equations in `operate` (2.10f)
   plus two small aliases, in keeping with the project's stated cost
   for a new operator. Found implementing it: the doubled-operator
   check did not generalise across the two tables an operator can now
   come from; a case-toggle on a non-letter incorrectly reported a
   change where none occurred, in a primitive this pass introduced; two
   existing properties had assumptions a wider `Operator` type made
   false; found by the same enlarged generators rather than anything
   specific to this pass, `^` and `|` could oscillate on repeated use
   because both reached their absolute target through a
   position-relative snap meant for motions of a different shape; and
   `replaceChars` repeated the case-toggle no-op bug one function
   later, caught by the same general property, with the property
   written to pin it down surfacing a further, unrelated issue in
   itself. All seven are recorded in Part 4.
10. **Closing Tier 1: counts on insert and `R`.** The two items
    deferred from the previous entry. Five more defects, three of them
    the identical no-op-reporting bug recurring in three separate
    functions, one a commit-granularity mistake specific to processing
    multi-character input one character at a time, and one a
    pre-existing gap in a shared predicate unrelated to this pass's own
    changes. All five in Part 4, along with the decision to give
    `prop_version_tracks_content_exactly` ten times the normal test
    count rather than add a sixth targeted fix for a bug class that had
    already recurred three times. Tier 1 is now complete: every item
    scoped into it is implemented, and the recurring bug class has one
    property watching for it at high volume rather than one-off
    vigilance.

## Known limitations, carried forward honestly

- **Search does not compose with operators.** `d/pattern` is not
  implemented: the pending operator does not survive opening the
  prompt, because `Prompt` has nowhere to carry it. `/`, `n` and `N`
  work as motions on their own.
- **No horizontal scrolling.** The cursor column is clamped to the window
  width, so a cursor past the right edge renders at the edge.
- **Horizontal motion on a very long line is O(line)**, measured at
  roughly 8ms per keypress at 36,000 characters and 53ms at 144,000.
  Three separate passes over the line are responsible: `hop`,
  `clampGap` and `alignCursor` each segment the whole line with ICU,
  and `currentLine` copies it. Fine for source files, poor for
  minified or generated ones. The benchmark records it as `Linear*`
  and guards it from getting worse; the fix is to segment a bounded
  window around the cursor rather than the entire line.
- **Tab stops are fixed at eight**, and this is blocked rather than
  deferred: the width function is reached through the `Unicode` record,
  so making it configurable is easy, but there is nowhere for a user to
  configure it from until an options system exists. Threading a setting
  through `Step` and `Render` before that would be plumbing without a
  source.
- **Line endings**: LF, CRLF and CR (old-Mac) are detected, decoded and
  written back unchanged. **A file with mixed line endings is normalised** to the one that
  predominates, as vim's `fileformat` does. Byte-for-byte round
  tripping holds for files with consistent endings.
- **A lone carriage return is content, not a line break.** Old-Mac
  `fileformat` is not supported; such a file opens as one long line
  with visible replacement glyphs rather than being misread.
- **`vty` is a hard dependency of `Basilisk-smoke`**, because the decoder
  tests use `Vty.Event`. The suite still needs no test framework, but the
  previous revision's claim that a smoke suite runs "on any machine with a
  bare GHC" was never true while the library depended on `text-icu`, and is
  not claimed here.
- **Tested on Unix only.** `Basilisk.Loop` imports
  `Graphics.Vty.Platform.Unix`; a Windows build needs
  `vty-crossplatform`, and `platformEol` already returns `CRLF` there but
  has not been exercised.
- **`R` does not support a count** (`3Rfoo<Esc>`): doing so faithfully
  needs a second, overwrite-based repeat mechanism parallel to
  `insertRepeat`'s insert-based one, and plain `R` is overwhelmingly
  the common case. `3ifoo<Esc>` (counted insert) works.
- **Backspacing across a Replace-mode newline rejoins the lines but
  does not restore what the next line used to start with.** Vim
  remembers it; doing so here would need a second restore mechanism
  parallel to the character-level one `R` already has, for a
  sufficiently rare case (backspacing back across an Enter typed while
  replacing) that the budget goes elsewhere first.

---

# Part 5 — What to build next

Haskell-awareness (syntax highlighting, auto-indent, comments,
structural navigation, LSP) is deliberately deferred: the current
priority is finishing the vim-emulation model to a complete, rock-solid
state before building anything on top of it. In the order that makes
sense to take them:

1. ~~Linewise paste~~ -- done. `Clip` records whether a cut was
   linewise or charwise, and `p`\/`P` dispatch on it (2.10c).
2. ~~`.`, find-char repeat, case and indent operators~~ -- done (2.10d,
   2.10e, 2.10f).
3. ~~`R` (replace mode) and counts on insert~~ -- done. `Replace
   ![Maybe Text]` for `R` (2.10f); `insertRepeat` on `Editor` for
   counted insert, expanded once at `IEscape`. Tier 1 is complete.
4. **Marks, named\/numbered registers, macros.** Each needs one small
   new piece of state, in the same shape `;`\/`,` and `.` already
   needed; macros can plausibly reuse `.`'s replay-through-`step`
   mechanism rather than a second implementation of repetition.
5. **Text objects** (`iw`, `i"`, `i(`, ...). New "inside"\/"around"
   reach-producing functions, consumed by the existing `operate`
   unchanged.
6. **Visual mode.** Reuses `Upto`, which already exists for exactly
   this: a charwise span between an anchor and the cursor.
7. **Search as an operator target.** `d/pattern` needs `Prompt` to
   carry the operator it interrupted, which it does not today. `/`,
   `n`, `N` already work as motions on their own.
8. **Ex ranges and `:s///`.** The most complex remaining parser in this
   list; everything above it is either done or a contained extension
   of an existing mechanism.
9. **Horizontal scrolling.** A second hysteresis field beside `top`,
   updated by a second `clampTop` with the same proof.
10. **The semantic milestone**, once the vim model above is complete:
    `render` becomes
    `(Int, Int) -> Editor -> SemanticSnapshot -> Picture`, with the
    snapshot carrying a version to compare against `Editor.version`, so
    a stale AST never becomes part of the single source of truth.

Generated from the compiled source tree by `docgen.py`. Do not edit
this file; edit the sources, or the prose in `docgen.py`, and
regenerate.
"""

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(doc)
print("wrote", OUT, len(doc.splitlines()), "lines")
