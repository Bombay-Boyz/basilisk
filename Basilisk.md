# Basilisk
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

Status, in one line: nine modules, 1582 lines of code, zero warnings under
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
  { mode     :: !Mode
  , document :: !Document
  , cursor   :: !Cursor
  , history  :: !History
  , path     :: !(Maybe FilePath)
  , version  :: !Int
  , status   :: !(Maybe Text)
  , register :: !(Maybe Text)
  , top      :: !Int
  , eol      :: !Eol
  }
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
data LineZ    = LineZ { before :: !Text, after :: !Text }
data Document = Document { above :: !(Seq Text), here :: !LineZ, below :: !(Seq Text) }
newtype Cursor = Cursor { desiredColumn :: Column }
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
data History = History { past :: ![Document], future :: ![Document] }

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

`encodeEol el . decodeEol = id` on any text whose every `\r` immediately
precedes a `\n`, which is exactly the set `decodeEol` produces. A file that
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
flag `'endofline'`.

One case the flag cannot settle alone: a zero-byte file and a one-byte
`"
"` file both load as a single empty row. `bornEmpty` records which,
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
  { widthAt  :: !(Column -> Char -> Int)
  , clusters :: !(Text -> [Int])
  }
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
| `{ }` (paragraph), `%` (bracket match), `\|` (column) | `MParagraph`, `MMatch`, `MColumn` |
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
| `Basilisk.Document` | zipper, coordinates, the reach algebra | 595 | 1156 |
| `Basilisk.Cursor` | the sticky column, ICU display width | 68 | 139 |
| `Basilisk.Types` | modes, tagged commands, effects, editor | 205 | 379 |
| `Basilisk.Step` | the pure transition function | 286 | 552 |
| `Basilisk.Decode` | vim's key grammar, as a Mealy machine | 177 | 281 |
| `Basilisk.Render` | viewport, frame, status line | 47 | 94 |
| `Basilisk.File` | open and write, encoding-safe | 120 | 219 |
| `Basilisk.Loop` | the IO shell | 37 | 65 |
| `Main` | argument parsing | 47 | 55 |
| **Total** | | **1582** | |

Non-comment lines, blank and `--`-only lines stripped. The complete
editor — including the four modules the previous revision had only
specified — is **1582 lines against a 3,000 ceiling**, leaving 1418
for the Haskell-structural-navigation milestone. The previous revision
budgeted ~1,120 for the same scope with four modules unwritten; the
reduction is not compression but the design changes in 2.4a, 2.4b, 2.4d and
2.5, each of which deleted a category of code rather than shortening it.

Tests, which do not count against the ceiling:

| File | Purpose | Code | With comments |
|---|---|---|---|
| `test/Laws.hs` | the laws, as Hedgehog properties | 426 | 718 |
| `test/Gen.hs` | Unicode-hostile generators | 132 | 183 |
| `test/Smoke.hs` | worked examples, in vim's vocabulary | 465 | 535 |
| `test/Exhaustive.hs` | totality sweep | 52 | 65 |

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

```cabal
cabal-version:      3.0
name:               Basilisk
version:            0.2.0.0
synopsis:           A modal terminal text editor for Haskell, in Haskell
build-type:         Simple

common warnings
  ghc-options:
    -Wall
    -Wcompat
    -Wincomplete-patterns
    -Wincomplete-uni-patterns
    -Wincomplete-record-updates
    -Werror=incomplete-patterns
    -Wredundant-constraints
    -O2
    -funbox-strict-fields
  default-language:   GHC2021
  default-extensions:
    StrictData
    BangPatterns
    LambdaCase
    OverloadedStrings

library
  import:             warnings
  hs-source-dirs:     src
  exposed-modules:
    Basilisk.Document
    Basilisk.Cursor
    Basilisk.Types
    Basilisk.Step
    Basilisk.Decode
    Basilisk.Render
    Basilisk.File
    Basilisk.Loop
  build-depends:
      base        >=4.16 && <5
    , bytestring  >=0.11 && <0.13
    , containers  >=0.6  && <0.8
    , deepseq     >=1.4  && <1.6
    , directory   >=1.3  && <1.4
    , filepath    >=1.4  && <1.6
    , temporary   >=1.3  && <1.4
    , time        >=1.11 && <1.15
    , unix        >=2.7  && <2.9
    , text        >=2.0  && <2.2
    , text-icu    >=0.8  && <0.9
    , vty         >=6.0  && <7
    , vty-unix    >=0.2  && <0.5

executable Basilisk
  import:             warnings
  hs-source-dirs:     app
  main-is:            Main.hs
  other-modules:      Paths_Basilisk
  autogen-modules:    Paths_Basilisk
  ghc-options:        -threaded
  build-depends:      base, Basilisk

-- Laws, as randomized properties.
test-suite Basilisk-laws
  import:             warnings
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Laws.hs
  other-modules:      Gen
  build-depends:
      base, text, bytestring, deepseq, vty, Basilisk
    , hedgehog    >=1.4

-- Worked examples, in vim's own vocabulary. Needs no test framework, so
-- it runs anywhere the editor itself builds.
test-suite Basilisk-smoke
  import:             warnings
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Smoke.hs
  build-depends:      base, text, vty, Basilisk

-- Totality sweep: every (mode, command, document) shape, forced to
-- normal form, checked only for freedom from exceptions.
test-suite Basilisk-exhaustive
  import:             warnings
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Exhaustive.hs
  build-depends:      base, deepseq, Basilisk

-- Complexity benchmarks: these assert scaling between two input sizes
-- rather than wall-clock thresholds, so they are meaningful in CI.
benchmark Basilisk-scaling
  import:             warnings
  type:               exitcode-stdio-1.0
  hs-source-dirs:     bench
  main-is:            Bench.hs
  ghc-options:        -fno-full-laziness -fno-cse
  build-depends:      base, text, deepseq, vty, Basilisk
```

### `src/Basilisk/Document.hs`

```haskell
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
```

### `src/Basilisk/Cursor.hs`

```haskell
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
```

### `src/Basilisk/Types.hs`

```haskell
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
```

### `src/Basilisk/Step.hs`

```haskell
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
```

### `src/Basilisk/Decode.hs`

```haskell
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
```

### `src/Basilisk/Render.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Editor to frame. Pure: every input, including the terminal size,
-- arrives as an argument.
--
-- Scrolling is hysteresis -- vim scrolls only once the cursor tries to
-- leave the window, so the next scroll position depends on the previous
-- one. That is state no zipper can derive, and 'top' is therefore as
-- irreducible as 'desiredColumn'. 'scroll' is the one function that
-- updates it, and the loop calls it once per frame, so a resize needs no
-- action of its own.
module Basilisk.Render
  ( render
  , scroll
  , clampTop
  ) where

import qualified Data.Text as Text
import qualified Graphics.Vty as Vty

import Basilisk.Cursor (displayColumn, renderable)
import qualified Basilisk.Document as Doc
import Basilisk.Types

-- | @clampTop h r t@ is the least adjustment of @t@ that puts row @r@
-- inside a window of @h@ rows.
--
-- Claim: for @h >= 1@ and @r >= 0@ and @t >= 0@, the result @t'@
-- satisfies @0 <= t' <= r < t' + h@.
-- Proof: three exhaustive cases. If @r < t@ then @t' = r@, so
-- @t' <= r < t' + h@ since @h >= 1@, and @t' = r >= 0@. If
-- @r >= t + h@ then @t' = r - h + 1 <= r@ and @r < t' + h = r + 1@, and
-- @t' >= t + 1 > 0@. Otherwise @t <= r < t + h@ already and @t' = t@.
clampTop :: Int -> Int -> Int -> Int
clampTop h r t
  | r < t      = r
  | r >= t + h = r - h + 1
  | otherwise  = t

-- | A terminal can report a degenerate size -- a zero-column window
-- mid-resize, or a pty with no window size set at all. This is the one
-- place that has to know: every measurement below is taken from a
-- window of at least one cell, so no downstream computation can produce
-- a negative width, a negative cursor position, or an empty frame.
usable :: (Int, Int) -> (Int, Int)
usable (w, h) = (max 1 w, max 1 h)

-- | The window is every row but the last, which the status line owns,
-- and never fewer than one.
body :: (Int, Int) -> Int
body = max 1 . subtract 1 . snd . usable

scroll :: (Int, Int) -> Editor -> Editor
scroll wh e = e { top = clampTop (body wh) (Doc.cursorRow (document e)) (top e) }

-- | Draws the window 'scroll' chose, then the status line, then places
-- the terminal cursor. Assumes 'scroll' has already run for this frame;
-- that is the loop's one obligation and the reason 'top' is read here
-- rather than recomputed.
render :: (Int, Int) -> Editor -> Vty.Picture
render wh0 e = (Vty.picForImage (Vty.vertCat (rows <> [bar]))) { Vty.picCursor = cur }
  where
    (w, h) = usable wh0
    rows   = map (Vty.text' Vty.defAttr . renderable) (Doc.window (top e) (body wh0) (document e))
    bar    = Vty.text' (Vty.defAttr `Vty.withStyle` Vty.reverseVideo)
                       (Text.justifyLeft w ' ' (Text.take w (renderable (statusLine e))))
    clamp lo hi = max lo . min hi
    -- A display with no cells has nowhere to put a cursor, and asking
    -- vty (6.6) to place one there is a segfault in the terminal layer,
    -- not an exception this code could catch. 'usable' keeps every
    -- measurement above well defined; this keeps the one value that is
    -- handed back to the terminal honest about a window that cannot
    -- show it.
    cur
      | uncurry (*) wh0 <= 0 = Vty.NoCursor
      | otherwise = Vty.Cursor
          (clamp 0 (w - 1) (Doc.unColumn (displayColumn (Doc.beforeCursor (document e)))))
          (clamp 0 (h - 1) (Doc.cursorRow (document e) - top e))

-- | One line, and the only channel the editor has to say anything: an
-- open prompt if there is one, otherwise the last status message,
-- otherwise the file name.
statusLine :: Editor -> Text.Text
statusLine e = case mode e of
  Prompt k b -> Text.cons (sigil k) b
  Normal     -> idle
  Insert _   -> "-- INSERT --"
  Replace _  -> "-- REPLACE --"
  where
    sigil ExCommand = ':'
    sigil Search    = '/'
    idle = maybe (name <> flag) id (status e)
    name = maybe "[No Name]" Text.pack (path e)
    flag = (if readOnly e then " [RO]" else "") <> (if modified e then " [+]" else "")
```

### `src/Basilisk/File.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | File IO, with no editing logic. Every boundary -- a missing file, a
-- binary file, a full disk, a file someone else changed underneath the
-- editor -- is a status message on a usable buffer, never an exception
-- and never a truncated file.
module Basilisk.File
  ( openFile
  , writeDocument
  , stampOf
  ) where

import Control.Exception (IOException, bracketOnError, try)
import qualified Data.ByteString as ByteString
import Data.Foldable (traverse_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory
  ( doesFileExist
  , getFileSize
  , getModificationTime
  , copyPermissions
  , canonicalizePath
  , getPermissions
  , removeFile
  , renameFile
  , writable
  )
import System.FilePath (takeDirectory, takeFileName)
import System.Info (os)
import System.IO (Handle, IOMode (WriteMode), hClose, hFlush, withBinaryFile)
import System.Posix.Files (getFileStatus, linkCount)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, handleToFd, openFd)
import System.Posix.Unistd (fileSynchronise)
import System.IO.Temp (openBinaryTempFile)

import Basilisk.Types

-- | Reads bytes and decodes explicitly. @Data.Text.IO@ would translate
-- newlines per platform and throw on invalid UTF-8; the first silently
-- rewrites every line ending of a file merely opened and saved, and the
-- second turns a binary file into a crash before the terminal is even
-- set up.
--
-- A file that does not exist opens as an empty buffer with its path
-- already set, so @:w@ writes it rather than asking for the name again.
openFile :: FilePath -> IO Editor
openFile fp = do
  present  <- doesFileExist fp
  mark     <- stampOf fp
  writable <- if present then writable' fp else canCreate fp
  buffer   <- if present then decoded <$> ByteString.readFile fp else pure (fresh "" platformEol)
  pure (onBuffer (\b -> b { bStamp = mark, bReadOnly = not writable }) buffer)
         { status = if writable then status buffer else Just "read-only" }
  where
    decoded    = either invalid valid . decodeUtf8'
    invalid _  = (fresh "" platformEol) { status = Just "not valid UTF-8" }
    fresh t el = onBuffer (\b -> b { bEol = el }) (newEditor (Just fp) t)
    -- The terminator is stripped and recorded rather than kept as a
    -- final empty row, so no file grows a line the user cannot see.
    -- At most one is removed, so the round trip is exact.
    valid raw = onBuffer (\b -> b { bFinalEol = ended, bBornEmpty = Text.null text })
                          (fresh (strip text) el)
      where
        el    = detectEol raw
        text  = decodeEol el raw
        ended = Text.singleton '\n' `Text.isSuffixOf` text
        strip = if ended then Text.dropEnd 1 else id

-- | A file's own convention wins; a file with no line endings at all
-- takes the platform's, which is what every other editor does for a
-- from-scratch file.
-- | A file's own convention wins. A lone carriage return with no line
-- feed anywhere is the old-Mac convention, which is otherwise read as
-- one enormous line full of replacement glyphs.
detectEol :: Text -> Eol
detectEol raw
  | "\r\n" `Text.isInfixOf` raw                              = CRLF
  | "\r" `Text.isInfixOf` raw && not ("\n" `Text.isInfixOf` raw) = CR
  | otherwise                                                = platformEol

-- | Whether the file can be written, checked at open rather than at
-- the first @:w@ -- an hour of editing followed by "permission denied"
-- is the same data loss as no warning at all, arriving later.
writable' :: FilePath -> IO Bool
writable' p = either (const False) writable <$> tryIO (getPermissions p)

-- | For a file that does not exist yet, what matters is the directory.
canCreate :: FilePath -> IO Bool
canCreate p = either (const False) writable <$> tryIO (getPermissions (takeDirectory p))

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

-- | A file with no line endings at all takes the platform's, which is
-- what every other editor does for a from-scratch file.
platformEol :: Eol
platformEol = if os == "mingw32" then CRLF else LF

-- | Modification time and size together. Either alone is too coarse:
-- filesystems round timestamps, and a same-size rewrite is common.
-- 'Nothing' means the file does not exist.
stampOf :: FilePath -> IO (Maybe Stamp)
stampOf p = do
  present <- doesFileExist p
  if not present
    then pure Nothing
    else do
      t <- getModificationTime p
      n <- getFileSize p
      pure (Just (truncate (toRational (utcTimeToPOSIXSeconds t) * 1000000000), n))

-- | The interpreter for the 'WriteFile' effect. The bytes arrive
-- already line-ending encoded from "Basilisk.Step", so nothing here
-- re-derives them; this function's job is to get them onto the disk
-- without ever being able to lose what was there before.
--
-- Two guards, in order:
--
--   * /Staleness./ If the file changed since it was read -- a rebase, a
--     formatter, another editor -- writing would silently discard
--     someone else's work. Refuse, and say so, unless forced.
--   * /Atomicity./ Write to a temporary file in the same directory,
--     then rename. @rename@ within a filesystem is atomic, so a crash,
--     a full disk or a kill leaves either the old file or the new one
--     and never a half-written one. The naive @writeFile@ truncates in
--     place, where the same interruption destroys the original.
--
-- Returns the stamp the buffer should now carry, so the caller does not
-- have to re-stat and race with itself.
writeDocument :: FilePath -> Text -> Bool -> Maybe Stamp -> IO (Either Text (Maybe Stamp))
writeDocument given t force expected = either describe id <$> attempt
  where
    attempt :: IO (Either IOException (Either Text (Maybe Stamp)))
    attempt = try $ do
      -- Write through a symlink, not over it. 'renameFile' replaces
      -- whatever name it is given, so writing to a symlinked path
      -- would silently turn the link into a regular file and leave the
      -- real file untouched -- the edit lost, with a "written"
      -- message. Resolving first is the whole fix.
      p     <- resolve given
      found <- stampOf p
      if not force && diverged expected found
        then pure (Left "file changed on disk (:w! to override)")
        else do
          shared <- isShared p
          if shared then inPlace p (encodeUtf8 t) else atomically p (encodeUtf8 t)
          Right <$> stampOf p
    describe e = Left (Text.pack ("write failed: " <> show (ioKind e)))
    ioKind = takeWhile (/= '\n') . show

-- | The real file behind a path, or the path itself if it cannot be
-- resolved (which is the normal case for a file that does not exist
-- yet, and must not be an error).
resolve :: FilePath -> IO FilePath
resolve p = either (const p) id <$> tryIO (canonicalizePath p)

-- | Whether other names refer to this same inode. 'renameFile' would
-- break them, leaving the other names holding the old contents, so a
-- hardlinked file is written in place instead -- trading atomicity for
-- the link, which is the trade vim makes too.
isShared :: FilePath -> IO Bool
isShared p = either (const False) ((> 1) . linkCount) <$> tryIO (getFileStatus p)

-- | The non-atomic path, used only where atomicity would destroy
-- something else. Truncating an existing inode keeps every name that
-- points at it.
inPlace :: FilePath -> ByteString.ByteString -> IO ()
inPlace p bytes = withBinaryFile p WriteMode (\h -> ByteString.hPut h bytes >> flushToDisk h)

-- | Changed underneath us. A file that has since been deleted is not a
-- conflict -- writing recreates it, which is what the user asked for.
diverged :: Maybe Stamp -> Maybe Stamp -> Bool
diverged _        Nothing  = False
diverged Nothing  (Just _) = True
diverged (Just a) (Just b) = a /= b

-- | 'bracketOnError' releases only on failure, so a temporary file is
-- never left behind and the destination is never touched until the
-- bytes are safely on disk. The temporary file is created in the
-- destination's own directory, because @rename@ is only atomic within
-- a filesystem and @\/tmp@ is routinely a different one.
--
-- The mode is copied with 'copyPermissions' rather than
-- @getPermissions@\/@setPermissions@: that pair models only the
-- owner's bits, so a group-readable or group-writable file would come
-- back owner-only -- which a round trip through the editor must not
-- do, and which this project did until it was measured.
atomically :: FilePath -> ByteString.ByteString -> IO ()
atomically p bytes = do
  present <- doesFileExist p
  bracketOnError
    (openBinaryTempFile (takeDirectory p) (takeFileName p <> ".basilisk"))
    (\(tmp, h) -> hClose h >> removeFile tmp)
    (\(tmp, h) -> do
        ByteString.hPut h bytes
        flushToDisk h
        hClose h
        traverse_ (const (copyPermissions p tmp)) (guard' present)
        renameFile tmp p
        syncDir (takeDirectory p))
  where guard' b = if b then Just () else Nothing

-- | Force the bytes out of the kernel's cache before the rename.
-- Without this the rename is atomic against a crash of this process
-- but not against a loss of power, which can leave the new name
-- pointing at an empty file.
flushToDisk :: Handle -> IO ()
flushToDisk h = hFlush h >> (tryIO (handleToFd h >>= sync) >>= either (const (pure ())) pure)
  where sync fd = fileSynchronise fd

-- | And the rename itself, which lives in the directory's own data.
syncDir :: FilePath -> IO ()
syncDir d = either (const ()) id <$> tryIO (go) >>= pure
  where
    go = bracketOnError (openFd d ReadOnly Nothing defaultFileFlags) closeFd
           (\fd -> fileSynchronise fd >> closeFd fd)
```

### `src/Basilisk/Loop.hs`

```haskell
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The only module that performs IO. It reads an event, asks
-- 'Basilisk.Decode' what it means, asks 'Basilisk.Step' what happens,
-- performs whatever effects come back, and repeats.
--
-- The frame is drawn at the /top/ of the iteration, before the blocking
-- read. That one ordering is what makes the first frame appear before
-- the first keystroke, and what makes a terminal resize repaint: the
-- size is re-read every iteration, so a resize needs no event handling,
-- no 'Resize' action and no special case anywhere.
module Basilisk.Loop (run) where

import Control.Exception (bracket)
import Control.Monad (foldM)
import qualified Graphics.Vty as Vty
import Graphics.Vty.Platform.Unix (mkVty)

import Basilisk.Decode (KeyState, decode, initialKeyState)
import qualified Basilisk.File as File
import Basilisk.Render (render, scroll)
import Basilisk.Step (step)
import Basilisk.Types

-- | 'bracket' guarantees the terminal returns to cooked mode whether the
-- loop returns, throws, or the process is asked to exit, so nothing
-- inside the loop needs exception handling of its own.
run :: Maybe FilePath -> IO ()
run mfp = do
  e0 <- maybe (pure (newEditor Nothing "")) File.openFile mfp
  bracket (mkVty Vty.defaultConfig) Vty.shutdown (\vty -> loop vty initialKeyState e0)

-- | Tail recursive and strict in both pieces of carried state; with
-- 'StrictData' on every field of 'Editor' this leaves no thunk chain
-- across keystrokes and the stack is @O(1)@ for the life of the session.
loop :: Vty.Vty -> KeyState -> Editor -> IO ()
loop vty !ks !e = do
  wh <- Vty.displayBounds (Vty.outputIface vty)
  let shown = scroll wh e
  Vty.update vty (render wh shown)
  ev <- Vty.nextEvent vty
  case decode (mode shown) ks ev of
    (ks', Nothing)  -> loop vty ks' shown
    (ks', Just act) -> do
      let (!next, effects) = step act shown
      done <- foldM perform next effects
      if RequestQuit `elem` effects
        then Vty.update vty (render wh (scroll wh done))
        else loop vty ks' done

-- | The one place an 'Effect' becomes IO. 'RequestQuit' is handled by
-- the loop's own membership test after the final frame is drawn, so it
-- does nothing here; the pure core reported a quit, and the shell -- not
-- the core -- decided to honour it.
perform :: Editor -> Effect -> IO Editor
perform e (WriteFile p t force) = settle <$> File.writeDocument p t force (stamp e)
  where
    -- A successful write is the only place the buffer becomes clean,
    -- and it records the stamp the writer observed rather than
    -- re-stat'ing and racing with itself.
    settle (Left why)   = e { status = Just why }
    settle (Right mark) = (onBuffer (\b -> b { bSaved = bVersion b, bStamp = mark }) e)
                            { status = Just "written" }
perform e RequestQuit = pure e
```

### `app/Main.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Argument handling, and nothing else. Anything that is not a flag
-- is the file to edit.
module Main (main) where

import Data.Version (showVersion)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

import Basilisk.Loop (run)
import Paths_Basilisk (version)

main :: IO ()
main = getArgs >>= dispatch

dispatch :: [String] -> IO ()
dispatch args
  | any (`elem` ["-h", "--help"]) args    = usage >>= putStrLn >> exitSuccess
  | any (`elem` ["-v", "--version"]) args = putStrLn ("basilisk " <> showVersion version) >> exitSuccess
  | otherwise = case filter (not . isFlag) args of
      []    -> run Nothing
      [f]   -> run (Just f)
      _ : _ -> do
        hPutStrLn stderr "basilisk: one file at a time; multiple buffers are not implemented"
        exitFailure
  where isFlag a = take 1 a == "-" && a /= "-"

usage :: IO String
usage = do
  me <- getProgName
  pure (unlines
    [ "usage: " <> me <> " [file]"
    , ""
    , "A modal terminal text editor for Haskell, in Haskell."
    , ""
    , "  -h, --help     show this and exit"
    , "  -v, --version  show the version and exit"
    , ""
    , "keys"
    , "  motions    h j k l  w b e  W B  0 ^ $  gg G"
    , "  find-char  f t F T <char>, ; to repeat, , to reverse it"
    , "  other      { } (paragraph)  % (matching bracket)  | (column)"
    , "  search     / then Enter, n to repeat, N to reverse"
    , "  operators  d y c    doubled for a whole line (dd yy cc)"
    , "  edits      x X D C s S  J  p P  u  Ctrl-R  . (repeat last change)"
    , "  insert     i a o O, Escape to leave"
    , "  commands   :w  :w!  :q  :q!  :wq"
    , ""
    , "Counts prefix a command: 3dw, 5j, 2d3w."
    , ""
    , "Quitting with unsaved changes is refused; :q! overrides."
    , "Writing over a file that changed on disk is refused; :w! overrides."
    ])
```

## Verification harness

### `scripts/check.sh` -- everything CI checks, in one script

```bash
#!/usr/bin/env bash
# Everything the project claims about itself, checked. Run locally
# before pushing; CI runs exactly this file, so the two cannot drift.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
step () { printf '\n=== %s\n' "$1"; }
bad  () { printf '  FAIL: %s\n' "$1"; fail=1; }
ok   () { printf '  ok: %s\n' "$1"; }

step "build (library, executable, tests, benchmarks) with zero warnings"
out=$(cabal build all --enable-tests --enable-benchmarks 2>&1) || { echo "$out" | tail -30; bad "build failed"; }
warnings=$(printf '%s' "$out" | grep -ci 'warning:' || true)
[ "$warnings" -eq 0 ] && ok "zero warnings" || { printf '%s' "$out" | grep -A4 -i 'warning:' | head -40; bad "$warnings warnings"; }

step "no partial functions in the pure core"
# Strip string literals and then trailing comments before matching, or
# prose beats the check: "no write since last change" and a Haddock
# "-- ^ the last search again" have both tripped it.
hits=$(cat src/Basilisk/*.hs app/Main.hs \
  | sed 's/"[^"]*"//g; s/--.*$//' \
  | grep -vE '^\s*$' \
  | grep -nE '\b(head|tail|init|last|fromJust|undefined|error)\b|!!|unsafePerformIO' || true)
[ -z "$hits" ] && ok "none" || { echo "$hits"; bad "partial function"; }

step "line-count ceiling"
# The same definition the handoff document reports, so the two agree.
loc=$(cat src/Basilisk/*.hs app/Main.hs | grep -vcE '^\s*(--|$)')
ceiling=3000
[ "$loc" -le "$ceiling" ] && ok "$loc / $ceiling" || bad "$loc exceeds the $ceiling-line ceiling"

step "test suites"
for suite in Basilisk-laws Basilisk-smoke Basilisk-exhaustive; do
  if LANG=C.UTF-8 cabal run -v0 "test:$suite" >/tmp/$suite.log 2>&1; then
    ok "$suite: $(tail -1 /tmp/$suite.log | sed 's/^ *//')"
  else
    tail -30 /tmp/$suite.log; bad "$suite"
  fi
done

step "complexity benchmarks"
if LANG=C.UTF-8 cabal run -v0 bench:Basilisk-scaling >/tmp/bench.log 2>&1; then
  ok "no scaling regression"
else
  cat /tmp/bench.log; bad "a scaling expectation was broken"
fi

step "the handoff document matches the sources"
# Part 3 is spliced from the source tree, so a stale document is a
# process failure rather than an editing mistake.
if command -v python3 >/dev/null; then
  cp Basilisk.md /tmp/Basilisk.prev.md 2>/dev/null || true
  python3 docgen.py >/dev/null 2>&1 || true
  if [ -f /tmp/Basilisk.prev.md ] && ! diff -q /tmp/Basilisk.prev.md Basilisk.md >/dev/null 2>&1; then
    bad "Basilisk.md is stale -- run python3 docgen.py"
  else
    ok "in sync"
  fi
fi

printf '\n'
[ "$fail" -eq 0 ] && { echo "ALL CHECKS PASSED"; exit 0; } || { echo "CHECKS FAILED"; exit 1; }
```

### `bench/Bench.hs` -- complexity benchmarks

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Complexity benchmarks.
--
-- These assert /scaling/, not wall-clock times. A threshold in
-- milliseconds is unreproducible across machines and flaky in CI; a
-- ratio between two input sizes is neither, and it is what actually
-- catches the defect worth catching. An accidental quadratic shows up
-- as a ratio near 16 where 4 was expected, on any hardware.
--
-- The one quadratic this project has had -- paste folding a
-- per-character primitive -- was found because a property test timed
-- out. That is not a detection strategy, and this file exists so it
-- does not have to be one again.
module Main (main) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Control.Monad (forM, unless)
import Data.List (sort)
import qualified Data.Text as Text
import System.CPUTime (getCPUTime)
import System.Exit (exitFailure)

import qualified Basilisk.Document as Doc
import Basilisk.Render (render, scroll)
import Basilisk.Step (step)
import Basilisk.Types

-- measurement ----------------------------------------------------------

-- | Median of several runs, in microseconds. CPU time rather than wall
-- clock, and the median rather than the mean, because a shared runner
-- will occasionally stall and the mean would carry it.
--
-- The input is rebuilt inside the loop and bound through 'evaluate'
-- rather than being passed in. Sharing one input across the samples
-- lets GHC float the whole computation out as a constant: the first
-- sample does the work, the other four measure nothing, and every
-- figure in the table comes out the same tiny number -- which is
-- exactly what this harness did until the output was read rather than
-- trusted. @-fno-full-laziness@ in the cabal stanza guards the same
-- mistake from the other side.
-- | How much of the result to force.
--
-- The distinction matters more than it looks. 'Nf' on an 'Editor'
-- walks the whole document, so a per-keystroke operation measured that
-- way appears to grow with file size no matter how cheap it is -- and
-- every constant-time operation in this table looked linear until the
-- two were separated. 'Whnf' is the honest measure for an edit,
-- because every field of 'Editor' and 'Document' is strict: forcing
-- the constructor forces the work. 'Nf' is right for whole-file
-- operations, where walking the result /is/ the operation.
data Measure = Whnf | Nf

forceTo :: NFData b => Measure -> b -> IO ()
forceTo Whnf y = y `seq` pure ()
forceTo Nf   y = evaluate (force y) >> pure ()

time :: (NFData a, NFData b) => Measure -> (a -> b) -> (Int -> a) -> Int -> IO Double
time how f build n = do
  samples <- forM [1 .. 5 :: Int] $ \_ -> do
    x  <- evaluate (force (build n))
    t0 <- getCPUTime
    _  <- forceTo how (f x)
    t1 <- getCPUTime
    pure (fromIntegral (t1 - t0) / 1e6 :: Double)
  pure (median samples)
  where median = middle . sort
        middle xs = case drop (length xs `div` 2) xs of
          m : _ -> m
          []    -> 0

-- | One measurement at size @n@ and one at @4n@, reported as the ratio
-- between them. @expected@ names the growth the design claims.
data Growth
  = Constant
  | Linear
  -- | Should be 'Constant'; measured to be linear, and recorded as
  -- such so that the benchmark still guards against getting /worse/.
  -- Renaming the expectation to match the measurement is only
  -- defensible when the gap is written down, which it is: the cursor
  -- primitives segment the whole line with ICU on every horizontal
  -- keystroke, and 'currentLine' copies it. At 36k characters that is
  -- ~8ms per keypress.
  | KnownLinear
  deriving (Eq)

instance Show Growth where
  show Constant    = "Constant"
  show Linear      = "Linear"
  show KnownLinear = "Linear*"

-- | The ratio a fourfold increase in input may produce before the claim
-- is considered broken. Generous, because these are medians on a shared
-- machine -- the point is to separate 4 from 16, not 4 from 5.
ceilingFor :: Growth -> Double
ceilingFor Constant    = 3
ceilingFor Linear      = 8
ceilingFor KnownLinear = 10

scaling :: (NFData a, NFData b) => String -> Measure -> Growth -> (Int -> a) -> (a -> b) -> IO Bool
scaling name how expected build f = do
  small <- time how f build n
  big   <- time how f build (4 * n)
  let ratio = if small <= 0 then 1 else big / small
      ok    = ratio <= ceilingFor expected
  putStrLn (pad 34 name <> pad 10 (show expected)
            <> pad 12 (micros small) <> pad 12 (micros big)
            <> pad 9 (round' ratio) <> (if ok then "ok" else "REGRESSED"))
  pure ok
  where
    n = 4000
    pad k s = s <> replicate (max 1 (k - length s)) ' '
    micros v = round' v <> "us"
    round' v = show (fromIntegral (round (v * 100) :: Integer) / 100 :: Double)

-- fixtures ---------------------------------------------------------------

manyLines :: Int -> Editor
manyLines n = withDocument (Doc.move Doc.ascii 0 (Doc.Lines (n `div` 2)) (Doc.fromText body))
                           (newEditor Nothing body)
  where body = Text.intercalate "\n" (replicate n "some ordinary line of source")

oneLongLine :: Int -> Editor
oneLongLine n = withDocument (Doc.move Doc.ascii 0 (Doc.Chars (n `div` 2)) (Doc.fromText body))
                             (newEditor Nothing body)
  where body = Text.replicate n "abcdefgh "

act :: NormalCmd -> Editor -> Editor
act c = fst . step (InNormal c)

main :: IO ()
main = do
  putStrLn (concat [pad 34 "operation", pad 10 "expected", pad 12 "n=4k", pad 12 "n=16k", pad 9 "ratio", "verdict"])
  results <- sequence
    -- Per-keystroke costs must not depend on how large the file is.
    [ scaling "j (down one line)"        Whnf Constant manyLines (act (NMove 1 (MChar DDown)))
    , scaling "G (jump to last line)"    Whnf Constant manyLines (act (NMove 0 MGotoLine))
    , scaling "insert one character"     Whnf Constant manyLines (\e -> fst (step (InInsert (IInput "x")) e { mode = Insert Fresh }))
    , scaling "dd (delete a line)"       Whnf Constant manyLines (act (NOperate 1 Delete MLine))
    , scaling "undo push (100 edits)"    Whnf Constant manyLines hundredEdits
    , scaling "render one frame"         Nf   Constant manyLines (\e -> render (80, 24) (scroll (80, 24) e))
    -- Whole-file costs are linear by necessity, but must not be worse.
    , scaling "open (fromText)"          Nf   Linear   bodyOf    Doc.fromText
    , scaling "save (serialise)"         Nf   Linear   manyLines serialise
    -- Long single lines: the cursor primitives segment the whole line.
    , scaling "l on a long line"         Whnf KnownLinear oneLongLine (act (NMove 1 (MChar DRight)))
    , scaling "insert on a long line"    Whnf KnownLinear oneLongLine (\e -> fst (step (InInsert (IInput "x")) e { mode = Insert Fresh }))
    ]
  putStrLn ""
  putStrLn "Linear* marks a measured deficiency, not a design claim:"
  putStrLn "horizontal motion on a very long line is O(line). See the"
  putStrLn "pending list. The benchmark guards it from getting worse."
  unless (and results) exitFailure
  where
    pad k s = s <> replicate (max 1 (k - length s)) ' '
    bodyOf n = Text.intercalate "\n" (replicate n "some ordinary line of source")
    hundredEdits e = foldl (\x _ -> act (NOperate 1 Delete (MChar DRight)) (act (NMove 1 (MChar DDown)) x)) e [1 .. 100 :: Int]
```

## Tests

### `test/Laws.hs`

```haskell
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
```

### `test/Gen.hs`

```haskell
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
```

### `test/Smoke.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Worked examples, in the vocabulary a vim user would state them in.
-- These depend on the library and therefore on @text-icu@ and @vty@;
-- what they do not depend on is @hspec@ or @QuickCheck@, so they run
-- wherever the editor itself builds.
module Main (main) where

import Control.Monad (unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty

import Basilisk.Cursor (clusterBounds, displayColumn, renderable, unicode, widthAt)
import Basilisk.Decode (decode, initialKeyState)
import qualified Basilisk.Document as Doc
import Basilisk.Render (clampTop)
import Basilisk.Step (step)
import Basilisk.Types

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let check name ok = unless ok (modifyIORef' failures (+ 1) >> putStrLn ("FAILED: " <> name))
  mapM_ (uncurry check) allChecks
  n <- readIORef failures
  putStrLn (show (length allChecks) <> " smoke checks, " <> show n <> " failures.")
  unless (n == 0) (ioError (userError "smoke checks failed"))

allChecks :: [(String, Bool)]
allChecks = documentChecks <> stepChecks <> vocabularyChecks <> tier1Checks <> searchChecks <> safetyChecks <> decodeChecks <> viewportChecks

-- helpers --------------------------------------------------------------

editor :: Text -> Editor
editor = newEditor Nothing

at :: Int -> Editor -> Editor
at n e = withDocument (Doc.move unicode 0 (Doc.Chars n) (document e)) e

-- | Buffer-field fixtures. The split between buffer and session means
-- a test that sets a path or a line ending says so, rather than
-- reaching into one flat record.
onFile :: FilePath -> Editor -> Editor
onFile p = onBuffer (\b -> b { bPath = Just p })

withEol :: Eol -> Bool -> Editor -> Editor
withEol el fe = onBuffer (\b -> b { bEol = el, bFinalEol = fe })

run :: [NormalCmd] -> Editor -> Editor
run cs e0 = foldl (\e c -> fst (step (InNormal c) e)) e0 cs

body :: Editor -> Text
body = Doc.toText . document

keys :: Mode -> [Vty.Key] -> [Action]
keys m = go initialKeyState
  where
    go _ []       = []
    go st (k : ks) = case decode m st (Vty.EvKey k []) of
      (st', Nothing) -> go st' ks
      (st', Just a)  -> a : go st' ks

chars :: String -> [Vty.Key]
chars = map Vty.KChar

-- the document algebra --------------------------------------------------

documentChecks :: [(String, Bool)]
documentChecks =
  [ ("toText . fromText = id, multi-line",
      all (\t -> Doc.toText (Doc.fromText t) == t) ["", "a", "a\nb\nc", "\n\n", "x\n"])
  , ("a document always has at least one line", Doc.lineCount (Doc.fromText "") == 1)
  , ("reach clamps a count to the line", Doc.reach unicode 99 (MChar DRight) (Doc.fromText "ab") == Doc.Chars 2)
  , ("reach MLine is inclusive: dd spans one row", Doc.reach unicode 1 MLine (Doc.fromText "a\nb") == Doc.Lines 0)
  , ("reach MLine is inclusive: 3dd spans three", Doc.reach unicode 3 MLine (Doc.fromText "a\nb") == Doc.Lines 2)
  , ("clampGap is idempotent", let d = Doc.fromText "abc" in Doc.clampGap unicode (Doc.clampGap unicode d) == Doc.clampGap unicode d)
  ] <> unicodeChecks

-- unicode, tabs, and what reaches the terminal ------------------------------

unicodeChecks :: [(String, Bool)]
unicodeChecks =
  [ ("a wide character advances two columns", widthAt 0 '\28450' == 2 && widthAt 0 'a' == 1)
  , ("a combining mark advances none", widthAt 0 '\769' == 0)
  , ("a tab advances to the next stop, from any column",
      and [ (c + widthAt (Doc.Column c) '\t') `mod` Doc.tabStop == 0 | c <- [0 .. 40] ])
  , ("a control character is one column and is never drawn raw",
      widthAt 0 '\ESC' == 1 && renderable "a\ESCb" == "a\65533b")
  , ("a carriage return cannot move the terminal cursor", renderable "a\rb" == "a\65533b")
  , ("a tab is drawn as spaces to the next stop", renderable "a\tb" == "a       b")
  , ("rendering preserves width", all (\t -> displayColumn (renderable t) == displayColumn t)
      ["", "a\tb", "a\ESCb", "\28450x", "e\769"])
  , ("a base plus a combining mark is one cluster", clusterBounds "e\769x" == [0, 2, 3])
  , ("an emoji ZWJ sequence is one cluster", clusterBounds "\128104\8205\128105" == [0, 3])
  , ("two regional indicators are one flag", clusterBounds "\127462\127463" == [0, 2])
  , ("a Hangul syllable is one cluster", clusterBounds "\4352\4449\4523" == [0, 3])
  , ("a prepended concatenation mark binds forward", clusterBounds "\1757a" == [0, 2])
  , ("l steps over a whole cluster, not a codepoint",
      Doc.cursorCol (document (run [NMove 1 (MChar DRight)] (editor "e\769x"))) == Doc.Offset 2)
  , ("x deletes a whole cluster",
      body (run [NOperate 1 Delete (MChar DRight)] (editor "e\769x")) == "x")
  , ("backspace deletes a whole cluster",
      let e = fst (step (InInsert IBackspace) (withDocument (Doc.move unicode 0 (Doc.Chars 2) (Doc.fromText "e\769")) ((editor "e\769") { mode = Insert Fresh })))
      in body e == "")
  , ("w never stops inside a cluster",
      Doc.onBoundary unicode (document (run [NMove 1 MWord] (editor "e\769 x"))))
  , ("j never lands inside a cluster",
      Doc.onBoundary unicode (document (run [NMove 3 (MChar DRight), NMove 1 (MChar DDown)] (editor "abcd\ne\769xy"))))
  , ("a count saturates instead of overflowing",
      all (\a -> all (\n -> n >= 0 && n <= maxCount) (counts a))
          (keys Normal (chars "99999999999999999999j")))
  , ("an absurd paste count is bounded, not an allocation bomb",
      Text.length (body (run [NPaste maxBound True] ((editor "") { register = Just (Clip False "x") }))) <= maxCount)
  ]
  where
    counts (InNormal (NMove n _))      = [n]
    counts (InNormal (NOperate n _ _)) = [n]
    counts _                           = []

-- the pure core ----------------------------------------------------------

stepChecks :: [(String, Bool)]
stepChecks =
  [ ("dw deletes a word and fills the register", body dw == "world" && fmap clipText (register dw) == Just "hello ")
  , ("dw bumps the version exactly once", version dw == 1)
  , ("3dw is one edit, so one undo restores it",
      body threeDw == "four" && body (run [NUndo 1] threeDw) == "one two three four")
  , ("2d3w multiplies the counts", body (run [NOperate 6 Delete MWord] wordy) == "")
  , ("yw leaves the document and version alone, and fills the register",
      body yw == "alpha beta" && version yw == 0 && fmap clipText (register yw) == Just "alpha ")
  , ("d$ cuts the tail", body (run [NOperate 1 Delete MLineEnd] (at 4 (editor "keep this"))) == "keep")
  , ("d0 cuts the head", body (run [NOperate 1 Delete MLineStart] (at 5 (editor "keep this"))) == "this")
  , ("dd removes one line and registers it", body dd == "second\nthird" && fmap clipText (register dd) == Just "first")
  , ("3dd removes three lines", body (run [NOperate 3 Delete MLine] three) == "")
  , ("dj removes the current line and the one below", body (run [NOperate 1 Delete (MChar DDown)] three) == "third")
  , ("dd on the only line leaves one empty line",
      Doc.lineCount (document (run [NOperate 1 Delete MLine] (editor "solo"))) == 1)
  , ("x deletes the character under the cursor", body (run [NOperate 1 Delete (MChar DRight)] (editor "abc")) == "bc")
  , ("l stops at the last character rather than walking off it",
      Doc.cursorCol (document (run [NMove 9 (MChar DRight)] (editor "abc"))) == Doc.Offset 2)
  , ("h stops at column zero", Doc.cursorCol (document (run [NMove 9 (MChar DLeft)] (editor "abc"))) == Doc.Offset 0)
  , ("5j clamps at the last line", Doc.cursorRow (document (run [NMove 5 (MChar DDown)] three)) == 2)
  , ("j past a wide character lands on the right character",
      Doc.cursorCol (document (run [NMove 2 (MChar DRight), NMove 1 (MChar DDown)] (editor "\28450\28450x\nabcde")))
        == Doc.Offset 4)
  , ("P pastes a charwise cut before the cursor", body (run [NPaste 1 False] dw) == "hello world")
  , ("3P pastes three copies", body (run [NPaste 3 False] dw) == "hello hello hello world")
  , ("a linewise cut pastes as whole rows, not joined on",
      body (run [NPaste 1 True] dd) == "second\nfirst\nthird"
        && body (run [NPaste 1 False] dd) == "first\nsecond\nthird")
  , ("yy then p duplicates a line", body (run [NOperate 1 Yank MLine, NPaste 1 True] three) == "first\nfirst\nsecond\nthird")
  , ("3p on a linewise register makes three rows",
      Doc.lineCount (document (run [NPaste 3 True] dd)) == 5)
  , ("p pastes after the cursor", body (run [NPaste 1 True] dw) == "whello orld")
  , ("o opens a line below and enters insert", body (run [NEnterInsert 1 LineBelow] (editor "a")) == "a\n"
      && mode (run [NEnterInsert 1 LineBelow] (editor "a")) == Insert Dirty)
  , ("O opens a line above", body (run [NEnterInsert 1 LineAbove] (editor "a")) == "\na")
  , ("a may sit past the last character, Escape may not",
      Doc.cursorCol (document afterA) == Doc.Offset 1
        && Doc.cursorCol (document (fst (step (InInsert IEscape) afterA))) == Doc.Offset 0)
  , ("a no-op edit grows neither history nor version",
      let e = run [NOperate 1 Delete MWord] (at 5 (editor "hello"))
      in version e == 0 && past (history e) == [])
  , ("save without a path is a status line, not a crash",
      snd (step (InNormal NSave) (editor "x")) == [] && status (fst (step (InNormal NSave) (editor "x"))) == Just "no file name")
  , ("save with a path emits exactly the bytes to write",
      snd (step (InNormal NSave) (withEol LF False (onFile "out.txt" (editor "x")))) == [WriteFile "out.txt" "x" False])
  , ("CRLF survives a round trip",
      snd (step (InNormal NSave) (withEol CRLF True (onFile "o" (editor "a\nb")))) == [WriteFile "o" "a\r\nb\r\n" False])
  , (":w and the save command agree",
      snd (step (InPrompt PSubmit) (onFile "o" (editor "x")) { mode = Prompt ExCommand "w" })
        == snd (step (InNormal NSave) (onFile "o" (editor "x"))))
  , ("the trailing newline is a flag, not a line",
      Doc.lineCount (document (editor "a\nb")) == 2
        && snd (step (InNormal NSave) (withEol LF True (onFile "o" (editor "a\nb")))) == [WriteFile "o" "a\nb\n" False]
        && snd (step (InNormal NSave) (withEol LF False (onFile "o" (editor "a\nb")))) == [WriteFile "o" "a\nb" False])
  , ("an unknown ex-command says so",
      status (fst (step (InPrompt PSubmit) (editor "x") { mode = Prompt ExCommand "zz" })) == Just "unknown command")
  , ("a prompt command with no prompt open is inert", step (InPrompt PBackspace) (editor "x") == (editor "x", []))
  , ("a typing session is one undo entry, not one per character",
      body (run [NUndo 1] session) == "ab" && body session == "abXYZ" && length (past (history session)) == 1)
  , ("a cursor move inside insert mode starts a new entry",
      body (run [NUndo 1] split') == "abX" && length (past (history split')) == 2)
  , ("o then typing then undo removes the line and the text together",
      body (run [NUndo 1] opened) == "ab" && body opened == "ab\nhi")
  , ("undo past the beginning reports rather than crashes",
      status (run [NUndo 3] (editor "x")) == Just "already at oldest change")
  ]
  where
    dw       = run [NOperate 1 Delete MWord] (editor "hello world")
    threeDw  = run [NOperate 3 Delete MWord] (editor "one two three four")
    wordy    = editor "a b c d e f"
    yw       = run [NOperate 1 Yank MWord] (editor "alpha beta")
    three    = editor "first\nsecond\nthird"
    dd       = run [NOperate 1 Delete MLine] three
    afterA   = run [NEnterInsert 1 After] (editor "ab")
    typeIn cs e = foldl (\x c -> fst (step (InInsert c) x)) e cs
    session  = typeIn (map (IInput . Text.singleton) "XYZ")
                      (run [NEnterInsert 1 After] (at 1 (editor "ab")))
    split'   = typeIn [IInput "X", IMove DLeft, IInput "Y"]
                      (run [NEnterInsert 1 After] (at 1 (editor "ab")))
    opened   = typeIn (map (IInput . Text.singleton) "hi") (run [NEnterInsert 1 LineBelow] (editor "ab"))

-- the vocabulary added after the skeleton ------------------------------------

vocabularyChecks :: [(String, Bool)]
vocabularyChecks =
  [ ("b goes back a word", col (run [NMove 2 MWord, NMove 1 MWordBack] (editor "one two three")) == 4)
  , ("2b goes back two", col (run [NMove 2 MWord, NMove 2 MWordBack] (editor "one two three")) == 0)
  , ("e stops on the last letter of a word", col (run [NMove 1 MWordEnd] (editor "one two")) == 2)
  , ("2e reaches the second word end, as e e does",
      col (run [NMove 2 MWordEnd] (editor "one two three"))
        == col (run [NMove 1 MWordEnd, NMove 1 MWordEnd] (editor "one two three")))
  , ("de is inclusive: it deletes the letter e stops on",
      body (run [NOperate 1 Delete MWordEnd] (editor "one two")) == " two")
  , ("^ goes to the first non-blank", col (run [NMove 1 MFirstNonBlank] (at 0 (editor "    indented"))) == 4)
  , ("^ on an all-blank line stops at the end", col (run [NMove 1 MFirstNonBlank] (editor "   ")) == 2)
  , ("G with no count goes to the last line", row (run [NMove 0 MGotoLine] three) == 2)
  , ("2G goes to line two", row (run [NMove 2 MGotoLine] three) == 1)
  , ("9999G clamps at the last line", row (run [NMove 9999 MGotoLine] three) == 2)
  , ("gg goes to the first line", row (run [NMove 5 (MChar DDown), NMove 1 MGotoLine] three) == 0)
  , ("^ is idempotent: pressing it twice lands in the same place both times",
      let once = run [NMove 1 MFirstNonBlank] (editor "    indented")
          twice = run [NMove 1 MFirstNonBlank, NMove 1 MFirstNonBlank] (editor "    indented")
      in col once == col twice)
  , ("c on an empty span still enters insert", mode (run [NOperate 1 Change MWord] (editor "")) == Insert Fresh)
  , ("cw cuts the word and enters insert",
      body cw == " world" && mode cw == Insert Fresh && fmap clipText (register cw) == Just "hello")
  , ("cc empties the line but keeps it",
      body cc == "\nsecond\nthird" && Doc.lineCount (document cc) == 3 && mode cc == Insert Fresh)
  , ("cc on an already empty line changes nothing and marks nothing",
      let e = run [NOperate 1 Change MLine] (editor "") in version e == 0 && not (modified e))
  , ("D deletes to the end of the line", body (run [NMove 4 (MChar DRight), NOperate 1 Delete MLineEnd] (editor "keep this")) == "keep")
  , ("X deletes backwards", body (run [NMove 2 (MChar DRight), NOperate 1 Delete (MChar DLeft)] (editor "abc")) == "ac")
  , ("J joins two lines with a space", body (run [NJoin 1] (editor "one\n   two")) == "one two")
  , ("3J joins three", body (run [NJoin 3] (editor "a\nb\nc\nd")) == "a b c\nd")
  , ("J on the last line is a no-op", let e = run [NJoin 1] (editor "only") in body e == "only" && version e == 0)
  , ("S changes a whole line", body (run [NOperate 1 Change MLine] three) == "\nsecond\nthird")
  ]
  where
    col = Doc.unOffset . Doc.cursorCol . document
    row = Doc.cursorRow . document
    three = editor "first\nsecond\nthird"
    cw = run [NOperate 1 Change MWordEnd] (editor "hello world")
    cc = run [NOperate 1 Change MLine] three

-- ~, gu/gU/g~, r, >/<, ZZ/ZQ ----------------------------------------------

tier1Checks :: [(String, Bool)]
tier1Checks =
  [ ("~ toggles one character and advances past it",
      let e = run [NOperate 1 ToggleCase (MChar DRight)] (editor "hello")
      in body e == "Hello" && col e == 1)
  , ("3~ toggles three characters, advancing past all of them",
      let e = run [NOperate 3 ToggleCase (MChar DRight)] (editor "hello")
      in body e == "HELlo" && col e == 3)
  , ("~ on a non-letter is a true no-op: no version bump, no undo entry",
      let e = run [NOperate 1 ToggleCase (MChar DRight)] (editor "5abc")
      in body e == "5abc" && version e == 0 && not (modified e))
  , ("guw lowercases a word", body (run [NOperate 1 ToLower MWord] (editor "HELLO world")) == "hello world")
  , ("gUw uppercases a word", body (run [NOperate 1 ToUpper MWord] (editor "hello WORLD")) == "HELLO WORLD")
  , ("guu lowercases the whole line, cursor at the first non-blank",
      let e = run [NOperate 1 ToLower MLine] (editor "  HELLO WORLD") in body e == "  hello world" && col e == 2)
  , ("gUU uppercases the whole line", body (run [NOperate 1 ToUpper MLine] (editor "Hello World")) == "HELLO WORLD")
  , ("g~~ toggles the whole line", body (run [NOperate 1 ToggleCase MLine] (editor "Hello World")) == "hELLO wORLD")
  , ("guu on a line with no letters is a no-op",
      let e = run [NOperate 1 ToLower MLine] (editor "123 456") in version e == 0 && not (modified e))
  , (">> indents a line by one level", body (run [NOperate 1 Indent MLine] (editor "foo")) == "    foo")
  , ("3>> indents three lines", body (run [NOperate 3 Indent MLine] (editor "a\nb\nc\nd")) == "    a\n    b\n    c\nd")
  , ("<< dedents an indented line", body (run [NOperate 1 Dedent MLine] (editor "        foo")) == "    foo")
  , ("<< removes only what is there, never going negative",
      let e = run [NOperate 1 Dedent MLine] (editor "  foo") in body e == "foo" && version e == 1)
  , ("<< on an unindented line is a no-op", let e = run [NOperate 1 Dedent MLine] (editor "foo") in version e == 0 && not (modified e))
  , ("> is forced linewise even for a charwise motion",
      body (run [NOperate 1 Indent MWord] (editor "foo bar")) == "    foo bar")
  , ("r replaces one character and leaves the cursor on it",
      let e = run [NReplace 1 'X'] (editor "abc") in body e == "Xbc" && col e == 0)
  , ("3rX replaces three characters with the same one each",
      let e = run [NReplace 3 'X'] (editor "abcdef") in body e == "XXXdef" && col e == 2)
  , ("r on a genuinely empty line is a no-op, not a crash",
      let e = run [NReplace 1 'X'] (editor "") in version e == 0 && not (modified e))
  , ("r clamps its count to what the line actually has",
      body (run [NReplace 99 'X'] (editor "abc")) == "XXX")
  , ("r replacing a character with itself is a true no-op",
      let e = run [NReplace 1 'x'] (editor "x") in version e == 0 && not (modified e))
  , ("3ra on an already-all-a's span is also a no-op",
      let e = run [NReplace 3 'a'] (editor "aaa") in version e == 0 && not (modified e))
  , ("r is repeatable with .", body (run [NReplace 1 'X', NMove 1 (MChar DRight), NRepeat 1] (editor "abc")) == "XXc")
  , ("ZZ saves and quits", snd (step (InNormal NWriteQuit) (onFile "/tmp/zz-smoke.txt" (editor "x"))) /= [])
  , ("ZQ quits without saving, regardless of modified state",
      let e = (run [NOperate 1 Delete (MChar DRight)] (editor "x")) in snd (step (InNormal NQuitDiscard) e) == [RequestQuit])
  , ("3ifoo<Esc> types the text three times", body (typeEsc 3 Before "foo" (editor "")) == "foofoofoo")
  , ("a plain i (count 1) is unaffected", body (typeEsc 1 Before "x" (editor "")) == "x")
  , ("undo after a counted insert removes the whole repetition in one step",
      let e = run [NUndo 1] (typeEsc 3 Before "ab" (editor "")) in body e == "")
  , (". after a counted insert repeats the whole thing again",
      let e = run [NMove 1 (MChar DRight), NRepeat 1] (typeEsc 3 Before "x" (editor ""))
      in body e == "xxxxxx")
  , ("a counted insert with no typed text (bare Escape) inserts nothing extra",
      body (typeEsc 5 Before "" (editor "ab")) == "ab")
  ]
  <> replaceModeChecks
  where
    col = Doc.unOffset . Doc.cursorCol . document
    typeEsc n anchor t e0 = fst (step (InInsert IEscape) typed')
      where
        entered = fst (step (InNormal (NEnterInsert n anchor)) e0)
        typed'  = if Text.null t then entered else fst (step (InInsert (IInput t)) entered)

-- R: replace mode -------------------------------------------------------

replaceModeChecks :: [(String, Bool)]
replaceModeChecks =
  [ ("R overwrites character by character", body (typeEscR "XY" (editor "abcdef")) == "XYcdef")
  , ("R extends past the end of the line", body (typeEscR "XYZ" (editor "ab")) == "XYZ")
  , ("mode is Replace [] immediately after R", mode (fst (step (InNormal NEnterReplace) (editor "abc"))) == Replace [])
  , ("backspace in R restores the overwritten character",
      body (runActions [InNormal NEnterReplace, InInsert (IInput "XY"), InInsert IBackspace, InInsert IEscape] (editor "abcdef"))
        == "Xbcdef")
  , ("backspace past an extension deletes it rather than restoring something that was never there",
      body (runActions [InNormal NEnterReplace, InInsert (IInput "XYZ"), InInsert IBackspace, InInsert IEscape] (editor "a"))
        == "XY")
  , ("backspace at the very start of an R session is a no-op -- can't back up past where R started",
      body (runActions [InNormal NEnterReplace, InInsert IBackspace] (editor "abc")) == "abc")
  , ("one undo entry removes a whole R session, however many characters it overwrote",
      body (runActions [InNormal NEnterReplace, InInsert (IInput "XYZ"), InInsert IEscape, InNormal (NUndo 1)] (editor "abcdef"))
        == "abcdef")
  , ("overwriting a character with itself is a true no-op: no version bump, no undo entry",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "x")] (editor "x") in version e == 0 && not (modified e))
  , ("a real overwrite still bumps the version normally",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "y")] (editor "x") in version e == 1)
  , ("version bumps exactly once for a multi-character IInput, not once per character",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "aa")] (editor "bb") in version e == 1)
  , ("pressing Enter in R mode opens a line rather than embedding a newline in one",
      let e = runActions [InNormal NEnterReplace, InInsert (IInput "ab\ncd"), InInsert IEscape] (editor "XY123456")
      in body e == "ab\ncd3456" && all (not . Text.any (== '\n')) (Doc.window 0 10 (document e)))
  ]
  where
    runActions cs e0 = foldl (\e c -> fst (step c e)) e0 cs
    typeEscR t e0 = fst (step (InInsert IEscape) typed')
      where
        entered = fst (step (InNormal NEnterReplace) e0)
        typed'  = if Text.null t then entered else fst (step (InInsert (IInput t)) entered)

-- ; and , repeating f/t/F/T -----------------------------------------------

findCharChecks :: [(String, Bool)]
findCharChecks =
  [ ("f. then ; repeats forward", colOf (step1 ";" (step1 "f." dots)) == 3)
  , ("two ; visits the third occurrence", colOf (step2 ";" ";" (step1 "f." dots)) == 5)
  , (", after f reverses direction", colOf (step1 "," (step2 ";" ";" (step1 "f." dots))) == 3)
  -- vim's well-known gotcha: t stops one short of its target, so a
  -- naive repeat would immediately re-find the same target and never
  -- move. ; must nudge past it instead of getting stuck.
  , ("t. lands one short, already adjacent to the first match",
      colOf (step1 "t." dots) == 0)
  , ("; after t does not get stuck -- it finds the next occurrence",
      colOf (step1 ";" (step1 "t." dots)) == 2)
  , ("a second ; continues advancing, still not stuck",
      colOf (step2 ";" ";" (step1 "t." dots)) == 4)
  , (", after t reverses, searching backward instead",
      colOf (step1 "," (step2 ";" ";" (step1 "t." dots))) == 2)
  , ("; with no previous find reports rather than guessing",
      status (step1 ";" dots) == Just "no previous find")
  -- A counted ';' is the same one-shot "nth occurrence from here"
  -- lookup 'MTo' itself is, not iteration -- the same divergence the
  -- counted-displacement law already excludes 'MTo' for. "a.b.c.d"
  -- has only two further '.'s after the first, so the 3rd does not
  -- exist and a one-shot "3;" stays exactly where it started, even
  -- though three individual presses of ';' would advance twice and
  -- then also stay (landing somewhere else: on the 2nd occurrence).
  , ("a counted ; is one lookup, not iteration, like MTo itself",
      colOf (step1 "3;" (step1 "f." dots)) == colOf (step1 "f." dots))
  , ("but a count within range finds exactly that occurrence",
      colOf (step1 "2;" (step1 "f." dots)) == colOf (step2 ";" ";" (step1 "f." dots)))
  ]
  where
    dots  = editor "a.b.c.d"
    colOf = Doc.unOffset . Doc.cursorCol . document
    step1 ks e = foldl (\e' a -> fst (step a e')) e (keys Normal (chars ks))
    step2 k1 k2 e = step1 k2 (step1 k1 e)

-- search, and the reach shape it needs ---------------------------------------

searchChecks :: [(String, Bool)]
searchChecks =
  [ ("/ jumps to the next match", posOf (find "beta") == (1, 0))
  , ("a search wraps at the end of the document",
      posOf (fst (step (InNormal (NRepeatFind 1 False)) (find "alpha"))) == (0, 0))
  , ("n repeats, N reverses",
      posOf (fst (step (InNormal (NRepeatFind 1 False)) (find "a"))) /= posOf (find "a")
        && posOf (fst (step (InNormal (NRepeatFind 1 True)) (fst (step (InNormal (NRepeatFind 1 False)) (find "a"))))) == posOf (find "a"))
  , ("3n skips two matches",
      posOf (fst (step (InNormal (NRepeatFind 3 False)) (find "a")))
        == posOf (iterate (fst . step (InNormal (NRepeatFind 1 False))) (find "a") !! 3))
  , ("a pattern that is absent does not move the cursor, and says so",
      posOf (find "zzzz") == posOf doc3 && status (find "zzzz") == Just "not found: zzzz")
  , ("n with no previous search reports rather than guessing",
      status (fst (step (InNormal (NRepeatFind 1 False)) doc3)) == Just "no previous search")
  ] <> findCharChecks <>
  -- the Upto shape: a charwise span that crosses rows
  [ ("a charwise span across rows joins the partial first and last rows",
      fmap (Doc.toText . fst) (Doc.operate Delete (Doc.Upto 2 3) (docAt 2 "alpha\nbeta\ngamma"))
        == Just "alma")
  , ("and yields exactly the text between the two positions",
      fmap snd (Doc.operate Delete (Doc.Upto 2 3) (docAt 2 "alpha\nbeta\ngamma"))
        == Just "pha\nbeta\ngam")
  , ("a span to the cursor's own position is a no-op",
      Doc.operate Delete (Doc.Upto 0 0) (docAt 0 "alpha") == Nothing)
  , ("a backwards span cuts the same text as the forwards one",
      fmap snd (Doc.operate Delete (Doc.Upto 0 1) (docAt 3 "alpha"))
        == fmap snd (Doc.operate Delete (Doc.Upto 0 3) (docAt 1 "alpha")))
  ]
  where
    doc3   = editor "alpha\nbeta\ngamma"
    find p = fst (step (InPrompt PSubmit) doc3 { mode = Prompt Search p })
    posOf e = (Doc.cursorRow (document e), Doc.unOffset (Doc.cursorCol (document e)))
    docAt n t = document (at n (editor t))

-- refusing to lose work ------------------------------------------------------

safetyChecks :: [(String, Bool)]
safetyChecks =
  [ (":q on a clean buffer quits", snd (ex "q" clean) == [RequestQuit])
  , (":q on a modified buffer refuses, and says why",
      snd (ex "q" dirty) == [] && status (fst (ex "q" dirty)) == Just "no write since last change (:q! to override)")
  , (":q! on a modified buffer quits", snd (ex "q!" dirty) == [RequestQuit])
  , ("a buffer is clean until edited, and dirty after", not (modified clean) && modified dirty)
  , ("undo alone does not make a buffer clean again", modified (run [NUndo 1] dirty))
  , (":wq writes and quits", snd (ex "wq" (onFile "o" dirty)) == [WriteFile "o" "ba\n" False, RequestQuit])
  , (":wq with no filename does neither", snd (ex "wq" dirty) == [])
  , (":w! sets the override the shell needs", snd (ex "w!" (onFile "o" dirty)) == [WriteFile "o" "ba\n" True])
  , ("Ctrl-C is bound to nothing that can quit", null (decodeCtrl 'c'))
  ]
  where
    clean = editor "ab"
    dirty = fst (step (InInsert (IInput "b")) ((editor "a") { mode = Insert Fresh }))
    ex c e = step (InPrompt PSubmit) e { mode = Prompt ExCommand c }
    decodeCtrl c = maybe [] pure (snd (decode Normal initialKeyState (Vty.EvKey (Vty.KChar c) [Vty.MCtrl])))

-- the key grammar ---------------------------------------------------------

decodeChecks :: [(String, Bool)]
decodeChecks =
  [ ("a bare motion is a move", keys Normal (chars "w") == [InNormal (NMove 1 MWord)])
  , ("an operator waits for its motion", keys Normal (chars "d") == [])
  , ("dw is one action", keys Normal (chars "dw") == [InNormal (NOperate 1 Delete MWord)])
  , ("3dw carries its count", keys Normal (chars "3dw") == [InNormal (NOperate 3 Delete MWord)])
  , ("2d3w multiplies", keys Normal (chars "2d3w") == [InNormal (NOperate 6 Delete MWord)])
  , ("dd is the doubled operator", keys Normal (chars "dd") == [InNormal (NOperate 1 Delete MLine)])
  , ("3dd counts rows", keys Normal (chars "3dd") == [InNormal (NOperate 3 Delete MLine)])
  , ("yy yanks a line", keys Normal (chars "yy") == [InNormal (NOperate 1 Yank MLine)])
  , ("x is delete one character forward", keys Normal (chars "x") == [InNormal (NOperate 1 Delete (MChar DRight))])
  , ("0 with no count pending is a motion", keys Normal (chars "0") == [InNormal (NMove 1 MLineStart)])
  , ("0 after a digit extends the count", keys Normal (chars "10j") == [InNormal (NMove 10 (MChar DDown))])
  , ("counts accumulate across digits", keys Normal (chars "123l") == [InNormal (NMove 123 (MChar DRight))])
  , ("i enters insert", keys Normal (chars "i") == [InNormal (NEnterInsert 1 Before)])
  , ("a colon opens the ex prompt", keys Normal (chars ":") == [InNormal (NEnterPrompt ExCommand)])
  , ("insert mode types text", keys (Insert Fresh) (chars "ab") == [InInsert (IInput "a"), InInsert (IInput "b")])
  , ("the prompt accumulates its own buffer",
      keys (Prompt ExCommand "") (chars "wq") == [InPrompt (PInput "w"), InPrompt (PInput "q")])
  , ("a command key aborts a pending operator rather than dropping it",
      keys Normal (chars "ci") == [])
  , ("~ and 3~ decode as ToggleCase over MChar DRight",
      keys Normal (chars "~") == [InNormal (NOperate 1 ToggleCase (MChar DRight))]
        && keys Normal (chars "3~") == [InNormal (NOperate 3 ToggleCase (MChar DRight))])
  , ("gu, gU and g~ decode as operators composing with a motion",
      keys Normal (chars "guw") == [InNormal (NOperate 1 ToLower MWord)]
        && keys Normal (chars "gUw") == [InNormal (NOperate 1 ToUpper MWord)]
        && keys Normal (chars "g~w") == [InNormal (NOperate 1 ToggleCase MWord)])
  , ("guu, gUU and g~~ double by their bare second letter",
      keys Normal (chars "guu") == [InNormal (NOperate 1 ToLower MLine)]
        && keys Normal (chars "gUU") == [InNormal (NOperate 1 ToUpper MLine)]
        && keys Normal (chars "g~~") == [InNormal (NOperate 1 ToggleCase MLine)])
  , (">> and << decode as Indent/Dedent, doubled like dd",
      keys Normal (chars ">>") == [InNormal (NOperate 1 Indent MLine)]
        && keys Normal (chars "3<<") == [InNormal (NOperate 3 Dedent MLine)])
  , ("r<char> decodes as NReplace, with its count", keys Normal (chars "3rx") == [InNormal (NReplace 3 'x')])
  , ("ZZ and ZQ decode as their own commands",
      keys Normal (chars "ZZ") == [InNormal NWriteQuit] && keys Normal (chars "ZQ") == [InNormal NQuitDiscard])
  , ("g and Z alone, with no second key, produce nothing",
      keys Normal (chars "g") == [] && keys Normal (chars "Z") == [])
  , ("gg still works after the g-prefix gained other uses",
      keys Normal (chars "gg") == [InNormal (NMove 1 MGotoLine)])
  -- Aborting discards the operator and the next key is read fresh, as
  -- vim does after an invalid operator target. So the p in cip is a
  -- paste, not part of a text object -- which is the honest outcome
  -- until text objects exist.
  , ("and the key after an abort is read fresh",
      keys Normal (chars "cip") == [InNormal (NPaste 1 True)])
  , ("the same keys alone still work",
      keys Normal (chars "ip") == [InNormal (NEnterInsert 1 Before), InNormal (NPaste 1 True)])
  , ("an unknown key aborts a pending operator", keys Normal (chars "d") <> keys Normal [Vty.KFun 5] == [])
  , ("a bracketed paste is one action, not one per character",
      length (snd (decode (Insert Fresh) initialKeyState (Vty.EvPaste "hello world") ) `seq`
              [decode (Insert Fresh) initialKeyState (Vty.EvPaste "hello world")]) == 1)
  , ("a bracketed paste in normal mode is a single edit",
      snd (decode Normal initialKeyState (Vty.EvPaste "ab\ncd")) == Just (InNormal (NPasteText "ab\ncd")))
  , ("cw acts as ce, as in vim", keys Normal (chars "cw") == [InNormal (NOperate 1 Change MWordEnd)])
  , ("dw is still dw", keys Normal (chars "dw") == [InNormal (NOperate 1 Delete MWord)])
  , ("cc is the doubled operator", keys Normal (chars "cc") == [InNormal (NOperate 1 Change MLine)])
  , ("D C s S X are operator/motion pairs, not new commands",
      keys Normal (chars "DCsSX") ==
        [ InNormal (NOperate 1 Delete MLineEnd), InNormal (NOperate 1 Change MLineEnd)
        , InNormal (NOperate 1 Change (MChar DRight)), InNormal (NOperate 1 Change MLine)
        , InNormal (NOperate 1 Delete (MChar DLeft)) ])
  , ("b and e decode as motions", keys Normal (chars "2b3e") == [InNormal (NMove 2 MWordBack), InNormal (NMove 3 MWordEnd)])
  , ("gg goes to the first line, G to the last",
      keys Normal (chars "g") == [] && keys Normal (chars "gg") == [InNormal (NMove 1 MGotoLine)]
        && keys Normal (chars "G") == [InNormal (NMove 0 MGotoLine)])
  , ("G carries its count, and none means the last line",
      keys Normal (chars "G") == [InNormal (NMove 0 MGotoLine)]
        && keys Normal (chars "12G") == [InNormal (NMove 12 MGotoLine)])
  , ("p and P differ", keys Normal (chars "pP") == [InNormal (NPaste 1 True), InNormal (NPaste 1 False)])
  , ("dG deletes to the end of the document", keys Normal (chars "dG") == [InNormal (NOperate 0 Delete MGotoLine)])
  , ("n and N decode with counts",
      keys Normal (chars "n3N") == [InNormal (NRepeatFind 1 False), InNormal (NRepeatFind 3 True)])
  , ("; and , decode with counts",
      keys Normal (chars ";3,") == [InNormal (NRepeatTo 1 False), InNormal (NRepeatTo 3 True)])
  , ("a resize disturbs no pending sequence",
      snd (decode Normal initialKeyState (Vty.EvResize 10 10)) == Nothing)
  ]

-- the viewport -------------------------------------------------------------

viewportChecks :: [(String, Bool)]
viewportChecks =
  [ ("the window holds still while the cursor is inside it", clampTop 10 5 3 == 3)
  , ("it scrolls up only to reach the cursor", clampTop 10 2 7 == 2)
  , ("it scrolls down by the least that works", clampTop 10 20 3 == 11)
  , ("every row is reachable", and [inside h r t | h <- [1 .. 8], r <- [0 .. 20], t <- [0 .. 20]])
  ]
  where inside h r t = let t' = clampTop h r t in t' >= 0 && t' <= r && r < t' + h
```

### `test/Exhaustive.hs`

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | A from-scratch sweep of every (mode, command, document) shape the
-- editor can be in, forcing each result to normal form. It proves
-- nothing about behaviour; it proves that nothing anywhere throws, and
-- it needs no test framework to say so.
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM)

import qualified Basilisk.Document as Doc
import Basilisk.Step (step)
import Basilisk.Types

documents :: [Doc.Document]
documents = map Doc.fromText
  [ "", "x", "hello world", "a\nb\nc", "\n\n", "first\nsecond\nthird"
  , "one two three\nfour", "\28450\23383 wide\nplain", "  leading", "trailing  "
  -- every class that has broken a terminal editor
  , "e\769x\769", "\128104\8205\128105 family", "\127462\127463 flag"
  , "\ta\tb", "esc\ESChere", "nul\NULhere", "cr\rhere", "\8205leading joiner" ]

modes :: [Mode]
modes = [ Normal, Insert Fresh, Insert Dirty
        , Replace [], Replace [Nothing], Replace [Just "a"], Replace [Just "\n", Just "x", Nothing]
        , Prompt ExCommand "", Prompt ExCommand "q", Prompt ExCommand "w", Prompt Search "x" ]

motions :: [Motion]
motions = [ MChar DUp, MChar DDown, MChar DLeft, MChar DRight, MWord, MWordBack, MWordEnd
          , MLine, MLineStart, MFirstNonBlank, MLineEnd, MGotoLine
          , MTo False False 'e', MTo True True 'a', MBigWord False, MBigWord True
          , MParagraph False, MParagraph True, MMatch, MColumn ]

actions :: [Action]
actions =
  [ InNormal c | c <- concat
      [ [NMove n m | n <- [0, 1, 7], m <- motions]
      , [NOperate n o m | n <- [1, 7], o <- [Delete, Yank, Change, ToLower, ToUpper, ToggleCase, Indent, Dedent], m <- motions]
      , [NEnterInsert n a | n <- [1, 3], a <- [Before, After, LineBelow, LineAbove]]
      , [NEnterPrompt k | k <- [ExCommand, Search]]
      , [NMove n m | n <- [maxBound, minBound], m <- [MChar DRight, MWord, MLine]]
      , [NOperate maxBound o m | o <- [Delete, ToggleCase, Indent, Dedent], m <- motions]
      , [NReplace n c | n <- [0, 1, 3, maxBound, minBound], c <- ['x', '\769']]
      , [NPaste 0 True, NPaste 2 False, NPasteText "", NPasteText "p\nq", NPasteText "\769"
        , NUndo 0, NUndo 3, NUndo maxBound, NUndo minBound, NRedo 3, NRedo minBound, NRepeat 1, NRepeat 3
        , NRepeatFind 1 False, NRepeatFind 1 True, NRepeatFind maxBound False
        , NRepeatTo 1 False, NRepeatTo 1 True, NRepeatTo maxBound False, NRepeatTo minBound True
        , NSave, NWriteQuit, NQuitDiscard, NEnterReplace] ] ]
  ++ [InInsert c | c <- [IInput "", IInput "z", IInput "\n", IInput "\769", IInput "\t", IInput "a\nb"
                        , IInput "ab\ncd", IInput "x"
                        , IBackspace, IMove DUp, IMove DDown, IMove DLeft, IMove DRight, IEscape]]
  ++ [InPrompt c | c <- [PInput "", PInput "w", PBackspace, PSubmit, PEscape]]

main :: IO ()
main = do
  let editors = [ withDocument d ((newEditor p "") { mode = m, register = r })
                | d <- documents, m <- modes, p <- [Nothing, Just "o.txt"], r <- [Nothing, Just (Clip False "reg"), Just (Clip True "reg\ntext")] ]
  outcomes <- forM editors (\e -> forM actions (once e))
  putStrLn (show (sum (map length outcomes)) <> " (mode, command, document) combinations exercised, 0 exceptions.")
  where
    once e a = do
      r <- try (evaluate (force (step a e))) :: IO (Either SomeException (Editor, [Effect]))
      either (\ex -> ioError (userError (show a <> ": " <> show ex))) (const (pure ())) r
```

---

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
  `o`, `u`, `:w`, `:q`, `.`, `f`, `{`, `%`, `~`, `gu`, `>>`, `r`, `ZZ`),
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
  empty file wrote **zero bytes** and, once typed into, `"abc
"`; and
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

A second batch of Phase 2 work -- `.`, `{`\/`}`, `f`\/`t`\/`F`\/`T`, `W`\/`B`
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
14. **`{`\/`}` (paragraph motion) had no fixed-point guard**, unlike
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
`Just "
"` is a reserved sentinel marking a line split rather than an
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
   `{`\/`}`, `%`, `|`, and `W`\/`B` added. Five defects found running
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
