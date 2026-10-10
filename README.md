# Basilisk

A modal terminal text editor for Haskell, written in Haskell, under a
hard ceiling of 3,000 lines of code.

**Status: usable, not finished.** It will not lose your file — that
much is tested against a real filesystem. It does not yet do anything
Haskell-specific, which is the point of the project and the largest
outstanding gap. See [Basilisk.md](Basilisk.md) for the architecture,
what has been verified, and how.

## Build

See [INSTALL.md](INSTALL.md) for the full instructions and
troubleshooting. The short version, on Debian or Ubuntu:

```sh
sudo apt-get install -y ghc cabal-install libicu-dev   # GHC 9.4.7
cabal update
cabal build
cabal run Basilisk -- yourfile.hs
```

To leave the editor: `:q`, or `:q!` to discard unsaved changes.

`./scripts/check.sh` runs everything CI runs: the build with zero
warnings, a partial-function sweep, the line-count ceiling, three test
suites, the complexity benchmarks, and a check that the handoff
document still matches the sources.

## Keys

| | |
|---|---|
| motions | `h j k l`, `w b e`, `W B`, `0 ^ $`, `gg G` |
| find-char | `f t F T <char>`, `;` to repeat, `,` to reverse |
| other | `{` `}` (paragraph), `%` (matching bracket), `\|` (column) |
| search | `/` then Enter, `n` to repeat, `N` to reverse |
| operators | `d y c`, doubled for a line (`dd yy cc`) |
| edits | `x X D C s S`, `J`, `p P`, `u`, `Ctrl-R`, `.` (repeat last change) |
| insert | `i a o O`, `Escape` to leave |
| ex | `:w :w! :q :q! :wq` |

Counts prefix a command and multiply: `3dw`, `5j`, `2d3w`.

## What it will not do to your files

- `:q` refuses to discard unsaved changes; `:q!` overrides.
- Writes are atomic — a crash or a full disk leaves the old file or the
  new one, never half of either.
- Writing over a file that changed on disk is refused; `:w!` overrides.
- Symlinks are followed rather than replaced, hardlinks keep their
  links, and file modes survive a save.
- Line endings (LF, CRLF, CR) and a missing final newline round-trip
  byte for byte.
- No control character from a file is ever written to the terminal, so
  a file full of escape sequences is displayed, not obeyed.

## What it does not do yet

No syntax highlighting, auto-indent or LSP. No visual mode, text
objects, marks, or named registers. Search does not compose with
operators (`d/pattern`). No macros. Multiple buffers exist as a data
split but nothing yet switches between them; no
splits, no config file, no horizontal scrolling. Unix only.

Horizontal motion on a very long line is O(line): around 8ms per
keypress at 36k characters. Fine for source, poor for minified files.

The full ordered list is at the end of `Basilisk.md`.

## Design in one paragraph

`Event -> decode -> Action -> step -> Editor -> render -> Frame`, where
`decode`, `step` and `render` are pure and only the shell performs IO.
The document is a zipper of lines whose cursor position is derived, not
stored. Motions compile to a signed `Reach` that two eliminators
consume — one moves, one cuts — so a new motion is one equation and
becomes available to every operator at once. Counts are closed forms
inside that algebra rather than an interpreter loop, which is why `3dw`
is one edit and one undo entry.
