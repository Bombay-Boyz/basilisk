# Running Basilisk

## 1. Toolchain

Basilisk targets **GHC 9.4.7** and needs the ICU library.

**Debian / Ubuntu**
```sh
sudo apt-get update
sudo apt-get install -y ghc cabal-install libicu-dev
```

**macOS** (untested — Basilisk is Unix-only but has only been run on Linux)
```sh
brew install ghc cabal-install icu4c pkg-config
export PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig"
```

**ghcup**, if you'd rather not use the distribution packages:
```sh
ghcup install ghc 9.4.7 && ghcup set ghc 9.4.7
ghcup install cabal
# still install libicu-dev / icu4c from your package manager
```

Check: `ghc --version` should say 9.4.7.

## 2. Build

```sh
cd basilisk
cabal update      # first time only; fetches the package index
cabal build
```

The first build compiles `text-icu`, `vty`, `hedgehog` and their
dependencies, so expect several minutes. Later builds are seconds.

## 3. Run

```sh
cabal run Basilisk -- yourfile.hs
```

Or install the binary onto your PATH:

```sh
cabal install --overwrite-policy=always
basilisk yourfile.hs
```

`basilisk --help` lists every key that works today. In short:
`h j k l w b e 0 ^ $ gg G` to move, `d y c` as operators (doubled for a
whole line), `x X D C s S J p P u Ctrl-R` to edit, `i a o O` to insert,
`/ n N` to search, and `:w :q :q! :wq` to leave.

**To quit:** `:q`, or `:q!` if you have unsaved changes you want to
discard. Ctrl-C is deliberately not bound.

## 4. Check everything

```sh
./scripts/check.sh
```

This is exactly what CI runs: a zero-warning build, a partial-function
sweep, the 3,000-line ceiling, three test suites, the complexity
benchmarks, and a check that `Basilisk.md` still matches the sources.
Run it before and after any change.

Individually, if you want them:

```sh
cabal test                      # all three suites
cabal run Basilisk-laws         # 34 Hedgehog properties
cabal run Basilisk-smoke        # 136 worked examples
cabal run Basilisk-exhaustive   # every (mode, command, document) shape
cabal bench                     # scaling benchmarks
```

## 5. The document

`Basilisk.md` is the architecture and verification record. Its code
sections are **spliced from the real source files** by `docgen.py`, so
the document cannot describe code that does not exist.

```sh
python3 docgen.py   # regenerate Basilisk.md
```

Prose lives in `docgen.py`; code lives in the `.hs` files;
`Basilisk.md` is output. Editing it directly will be overwritten, and
`check.sh` fails if you forget to regenerate.

## If the build fails

- **`Missing (or bad) C library: icuuc`** — install `libicu-dev`
  (Debian/Ubuntu) or `icu4c` plus `PKG_CONFIG_PATH` (macOS).
- **`cabal: Could not resolve dependencies`** — run `cabal update`.
- **Compile errors in `Graphics.Vty.Platform.Unix`** — you are on
  Windows. Basilisk is Unix-only; see the pending list in `Basilisk.md`.
- **`Basilisk.md is stale`** from `check.sh` — run `python3 docgen.py`.
