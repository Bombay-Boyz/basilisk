# Seby: Pending Work for a World-Class Haskell Modal Editor

**Purpose:** the prioritized product and engineering roadmap for Basilisk/Seby.

**Snapshot:** reviewed from `main` at `555d198` on 2026-11-21. External-change fingerprints and cooperating-writer locks were added in `e396c9d`; conservative live Haskell indentation was added in `68bc901`; project/XDG Fourmolu config support was added in `033b389`; explicit CLI option handling was added in `f0fede5`. Subsequent formatter milestones validated malformed literate layouts (`bc5b064`), bounded formatter diagnostics (`f6d4a21`), added compiler-backed semantic-preservation and idempotence checks (`31910ee`, `d11b470`), and tested CPP branch preservation, including conditional imports and declarations (`cc9e8a5`, `555d198`). The full check, including CLI/PTY cases, passed locally on macOS arm64 with GHC 9.10.3 at `555d198`. GitHub Actions run `44923039398` passed all four configured GHC jobs on Ubuntu 24.04 at the earlier `b1837f2` baseline; that run predates these formatter changes. The smoke suite reports 230 checks and the exhaustive transition sweep exercises 629,640 combinations. Save-time Fourmolu formatting is implemented for `.hs` and `.lhs`; project and XDG `fourmolu.yaml` settings are loaded. Markdown and plain text are saved unchanged and do not get live indentation.

This is a work plan, not a claim that the items below already exist. Mark an item done only after its acceptance criteria pass and the architecture handoff is updated.

## Product bar

Seby should make common editing tasks fast and predictable while protecting user data. Every feature should have an explicit behavior model, total edge-case handling, focused tests, and an end-to-end terminal check where terminal behavior is involved. Haskell support should use project settings and compiler semantics instead of approximating them with token heuristics.

Keep the editor modal and Haskell-first. Do not add a plugin framework or require users to install a plugin or run a formatter command for ordinary save behavior. Prefer well-supported Haskell libraries as in-process dependencies. Keep IO at the shell boundary, keep semantic state out of the core `Editor`, and preserve the existing file-safety guarantees. Where behavior depends on project or compiler semantics, prefer those sources over token heuristics; document the limits of intentionally conservative heuristic features.

## Priority summary

| Priority | Milestone | Outcome |
|---|---|---|
| P0 | Release confidence | Verified compiler matrix, reproducible builds, terminal regression coverage, and stable formatter behavior |
| P1 | Editing completeness | Text objects, visual selection, marks/registers, reliable command-line editing, and live-indentation follow-up |
| P2 | Haskell intelligence | Incremental parsing, useful diagnostics, and version-safe Haskell Language Server integration |
| P3 | Workspace productivity | Multiple buffers, project navigation, user settings, and recoverable sessions |
| P4 | Scale and distribution | Responsive large-file behavior, portability decisions, packaging, and release operations |

Work in this order unless a measured user problem justifies reordering. P0 work reduces the risk of building later features on unverified assumptions.

## P0 — Release confidence and reliability

### P0.1 Verify the advertised compiler and dependency support

**Status:** CI matrix configured and all four jobs passed on commit `b1837f2` (run `44923039398`). The full local `scripts/check.sh` passed on GHC 9.10.3/macOS arm64.

- The full check script passes across the configured GHC 9.10, 9.12, 9.14 and `latest` jobs on Ubuntu 24.04; rerun the matrix as supported compiler/dependency bounds change.
- The conditional Fourmolu dependency branches and `Ormolu.Config.FourmoluConfig` API used for YAML loading pass in that matrix; the top-level `Ormolu` module remains Fourmolu's stable API.
- The `allow-newer: ghc-lib-parser:hpc` workaround is limited to GHC 9.14+ for the bundled hpc metadata mismatch and is covered by the passing matrix.
- `.github/workflows/ci.yml` invokes `scripts/check.sh` for build, test suites, benchmarks, the partial-function sweep, PTY tests, and generated-document consistency.
- Make the declared support range match what CI actually verifies. Do not imply Windows support while the executable imports the Unix Vty backend.

**Acceptance:** a fresh checkout builds without undocumented local packages or commands on every advertised compiler; CI exercises the same checks maintainers rely on locally.

### P0.2 Harden save-time formatting as a data-integrity boundary

**Status:** Core behavior, project/XDG config loading, and the identified literate-layout cases are tested; cross-version formatter API coverage and unusual legal constructs remain open. `test/Formatter.hs` covers Cabal extensions, custom printer indentation, nearest project config precedence, XDG fallback, malformed config refusal, Bird and LaTeX literate formatting, prose and marker-like text, multiple code regions, blank rows, mixed/CRLF endings, missing final newline, malformed/nested/unmatched LaTeX markers, conditional CPP imports and declarations in both compile-and-run branches, Markdown passthrough, parse failure, bounded path-prefixed diagnostics, post-format undo, stale fingerprints, path replacement, a pre-commit external edit, and post-rename sync failure. Representative executable fixtures preserve a custom right-associative operator and comments before and after formatting; repeated save confirms byte idempotence and unchanged undo history. Invalid literate source preserves existing bytes and prevents quit-after-save. Fourmolu's in-process API currently receives plain Haskell source, so Basilisk shields prose and reconstructs literate layout itself.

- Test saves through `:w`, `:w!`, `:wq`, and `ZZ`, including success, parse failure, stale-file refusal, read-only files, and write failure.
- Verify that formatter failure never changes disk contents, never marks the buffer clean, and never quits after `:wq` or `ZZ`.
- Verify that a successful format updates the in-memory document, preserves the final-newline choice and line-ending policy, keeps the cursor on a sensible nearby location, creates one undoable change, and makes the resulting buffer clean only after the write succeeds.
- Continue expanding `.hs`, Bird `.lhs`, and LaTeX `.lhs` fixtures for nested or interacting CPP conditions and unusual legal layout. Current CPP coverage checks conditional imports and declarations in both configurations. Preserve literate prose byte-for-byte where feasible; explicitly reject unsupported constructs without writing.
- Honor Cabal component language extensions and dependencies. Project ancestor and XDG `fourmolu.yaml` files are loaded through Fourmolu's config API; verify the exposed config type across every supported Fourmolu branch and document that precedence.
- Extend semantic-preservation checks with broader compiler-backed fixtures for project configuration and Haskell constructs beyond the tested CPP conditional imports/declarations and right-associative operator. Current compile-and-run coverage is targeted evidence, not a general proof of semantic preservation.

**Acceptance:** failures before replacement leave the original file intact; failures after replacement report that the new file was committed and state any durability warning accurately. The user can understand why saving failed or completed with a warning. Repeated saves of an already formatted file produce no content or history change.

### P0.3 Build a terminal-driven regression harness — complete

**Completed:** `test/Terminal.py`, run by `scripts/check.sh` in CI, covers PTY startup, insert and save, quit, bottom-row mode placement, formatter failure, resize, alternate-screen cleanup, and terminal attribute restoration. Broader terminal-size, platform, and Unicode rendering cases remain part of release hardening.

### P0.4 Define behavior and safety guarantees for the first release

- Document the supported subset of Vim-like behavior precisely, including known differences in counts, motions, repeat, Replace mode, search, and ex commands.
- Add recovery guidance and an explicit policy for unsupported binary files, invalid UTF-8, external modifications, symlinks, hardlinks, permissions, and formatter errors.
- Audit status messages for clipping, ambiguous success/failure wording, and stale messages that remain after the next action.
- Review atomic-write behavior on the filesystems and Unix platforms the project claims to support.

**Acceptance:** users can predict what each supported command does, how errors behave, and how the editor avoids overwriting unrelated work.

## P1 — Editing completeness and daily usability

### P1.1 Add text objects — complete

**Completed:** inner and around word, quote, and balanced delimiter objects use explicit spans and compose with delete, change, and yank. Counts, unmatched pairs, nested delimiters, closing-bracket lookup, and combining graphemes have focused tests. Randomized span laws remain a follow-up under the cross-cutting test requirements.

### P1.2 Add Visual mode

- Add characterwise and linewise selection with a distinct mode state and anchor.
- Reuse the existing range algebra for operators, yank, delete, change, and register updates.
- Render the selection with correct wide-character, tab, horizontal-scroll, and viewport behavior.
- Define cancellation, cursor movement, mode transitions, and empty-document behavior before implementation.

**Acceptance:** visual operations agree with equivalent operator motions wherever their semantics overlap; selection rendering remains correct after terminal resize and Unicode movement.

### P1.3 Add marks, registers, and macros in a bounded design

- Add local marks first, with clear invalidation or clamping rules when lines are deleted or the document changes.
- Add named and numbered registers with explicit linewise/charwise metadata and documented overwrite/yank rotation behavior.
- Add record/replay macros only after action replay has a safe, bounded representation. Prevent recursive or unbounded macro expansion and define how prompts, failures, and counts interact.
- Keep state in the narrowest scope that owns it; avoid turning `Editor` into a bag of unrelated global fields.

**Acceptance:** marks and register contents survive the documented edits; macro playback is bounded, deterministic, and undo behavior is defined and tested.

### P1.4 Complete command-line editing and ex ranges

- Replace ad hoc command string matching with a small total parser for supported ex syntax.
- Add line ranges, address forms, and substitution only with precise rules for empty matches, captures, flags, multiline text, and undo grouping.
- Add command-line completion only after command names, filenames, and ranges have a stable grammar.
- Ensure `:wq` and other compound commands preserve the rule that quit follows successful writes only.

**Acceptance:** malformed commands return actionable errors rather than exceptions or partial edits; each compound edit is one sensible undo transaction.

### P1.5 Implement live indentation and comment helpers

**Status:** Conservative Haskell Enter indentation is implemented in `68bc901`. It applies to `.hs` and Bird-style `.lhs`, uses two-space continuation after common layout cues, preserves Bird markers, indents empty delimiter pairs, and leaves Markdown/plain text and pasted newlines unchanged. It is lexical and fixed-width; it does not implement comment continuation or configurable indentation.

- Keep live indentation separate from whole-file formatting on save. Improve context detection beyond the current conservative lexical cues where reliable syntax information is available.
- Decide whether Markdown should receive any live behavior; current behavior intentionally leaves Markdown and plain text unchanged.
- Extend the behavior table for tabs versus spaces, blank lines, guards, closers, `do`/`where`/`let`, and Bird prefixes. Current Enter, smart Backspace, empty-pair and paste behavior have focused smoke checks.
- Add comment-line insertion/continuation only when it can respect Haskell line, nested block, and literate syntax.
- Add a user setting for indentation width/style before claiming configurable indentation, then decide whether indentation operators should share it.

**Acceptance:** the supported fixed-width behavior is documented and predictable on incomplete Haskell; it never corrupts text on paste or Backspace. Configurable width/style and comment continuation remain separate acceptance work.

### P1.6 Improve search and navigation

- Specify whether current search is literal-only and add regex search only with a safe engine and clear invalid-pattern behavior.
- Define forward/backward wrap, case sensitivity, empty pattern, Unicode matching, and operator-pending search behavior.
- Add jump history only if it has well-defined interaction with marks and undo.
- Keep count processing bounded and preserve the existing closed-form motion model.

**Acceptance:** search behavior is documented and deterministic for all directions, counts, and failures; no malformed pattern crashes the editor.

### P1.7 Close existing Replace-mode edge cases

- Add counts to `R` with one overwrite-based repeat model, including count exhaustion and undo behavior.
- Keep the overwrite history bounded and ensure counted replacement cannot create unbounded state.

**Acceptance:** counted replacement handles count exhaustion deterministically and remains one coherent, bounded undo unit.

## P2 — Haskell intelligence

### P2.1 Introduce a versioned semantic snapshot outside `Editor`

- Define a semantic snapshot keyed by document version and file identity. It must never become a second mutable source of document truth.
- Parse asynchronously or incrementally without blocking keystrokes. Discard results whose source version no longer matches the buffer.
- Represent parse errors, warnings, source spans, and stale/unavailable states explicitly.
- Add cancellation and resource limits for large files and rapid edits.

**Acceptance:** stale parse results cannot render against newer text; parser failure is recoverable; editing remains responsive while analysis runs.

### P2.2 Add syntax-aware highlighting and diagnostics

- Replace or augment the current line-local lexical highlighter with parser-backed syntax tokens while retaining a fast lexical fallback for incomplete code.
- Carry multiline comment/string state correctly across visible rows.
- Show diagnostics with a concise location, severity, and navigable list; do not overload the status line with full diagnostics.
- Support Haskell modules and literate Haskell explicitly. Define behavior for CPP and unsupported extensions.

**Acceptance:** highlighting remains stable during incomplete edits; diagnostics map to the correct source version and cursor location.

### P2.3 Integrate Haskell Language Server as a built-in service

- Decide whether HLS is a bundled optional process dependency or whether a smaller in-process service is the first milestone. The editor should still start and edit files when HLS is unavailable.
- Keep JSON-RPC, process management, capability negotiation, diagnostics, hover, completion, and code actions behind a dedicated adapter module.
- Handle server startup failure, timeout, restart, document synchronization, URI encoding, workspace roots, and shutdown without compromising the terminal loop.
- Make save formatting ownership unambiguous: Basilisk’s built-in save formatter remains authoritative unless a deliberate policy gives HLS ownership. Prevent double-formatting.

**Acceptance:** HLS unavailability is a visible nonfatal state; stale responses are discarded; formatting runs once; LSP features have protocol-level tests and end-to-end PTY coverage.

### P2.4 Evolve the formatter intentionally

- Choose and publish the no-config Fourmolu style, including indentation width and line width.
- Verify project and XDG config loading across supported Fourmolu branches. The current code uses the exposed `Ormolu.Config.FourmoluConfig` parser type; ensure the compiler matrix catches API changes. Keep malformed config failures safe and visible. Current literate fixtures cover Bird and LaTeX basics, blank Bird code lines, CRLF without a final newline, multiple LaTeX code blocks, and empty `.lhs` files; extend with mixed endings, marker-like code/prose, indented prose, and buffer/undo assertions.
- Add fixtures for package-level extensions, custom fixities, local modules, imports, CPP limitations, literate code, comments, and syntax errors.
- Keep formatting failure-safe and measure latency on large modules. If formatting is too slow for the interactive save path, show progress or provide cancellation without writing unformatted bytes silently.

**Acceptance:** formatting is deterministic for a given source and project configuration, safe against semantic changes, and has documented limitations.

## P3 — Workspace productivity

### P3.1 Add a real buffer model

- Implement buffer creation, switching, listing, closing, and per-buffer path, modified state, history, and file stamp.
- Define the global-versus-buffer-local ownership of search state, registers, options, and cursor history.
- Refuse buffer close when it would discard unsaved work unless an explicit force action is used.
- Ensure writes and formatter results are bound to the buffer that initiated them; never apply an asynchronous result to the newly focused buffer by accident.

**Acceptance:** several files can be edited in one session without state leakage or silent data loss.

### P3.2 Add project navigation and workspace awareness

- Establish a workspace root from Cabal project/package files, Git root, or an explicit user choice, with deterministic precedence.
- Add file finding and buffer switching without making Git a runtime requirement.
- Keep package discovery aligned with the Cabal component used by the formatter and future HLS integration.
- Bound file scans, exclude build outputs, and report inaccessible paths.

**Acceptance:** project discovery is fast on large repositories, works outside Git, and resolves the same package context as the language tools.

### P3.3 Add a small, validated settings system

- Support only settings with clear user value initially: tab stop, shift width, indent style, line width, search behavior, and color theme.
- Define defaults, precedence, validation, and per-project versus per-user scope.
- Avoid executable configuration and a plugin surface. Invalid settings should report an error and retain safe defaults.
- Ensure settings that affect formatter behavior are shared with the save path or explicitly separated.

**Acceptance:** settings are discoverable, validated, tested, and do not create hidden per-buffer inconsistencies.

### P3.4 Add recovery and session persistence

- Design crash recovery around atomic snapshots and explicit ownership of recovery files.
- Save buffer identity, modified content, cursor, and viewport only after deciding how to protect sensitive text and avoid stale recovery.
- Provide a clear recovery prompt and cleanup policy; never restore over a newer on-disk file without detecting the conflict.

**Acceptance:** forced termination can recover recent work without corrupting the original file or silently restoring stale state.

## P4 — Scale, portability, and release quality

### P4.1 Fix measured long-line costs

- Profile the current O(line) path: grapheme segmentation in `hop`, `clampGap`, and `alignCursor`, plus `currentLine` copying.
- Add benchmarks for cursor movement, insertion, viewport rendering, search, and formatting across line lengths and Unicode compositions.
- Introduce bounded-window or cached grapheme segmentation only after the benchmark identifies the dominant cost. Cache keys must include the text version and invalidate safely.
- Keep complexity tests tied to user-visible operations, not implementation details that prevent useful refactoring.

**Acceptance:** ordinary navigation latency stays responsive on large generated lines; benchmarks show scaling and protect against regressions.

### P4.2 Decide the source-size and module-boundary policy

- The current 3,000-line ceiling is a hard project rule, while parser, LSP, registers, visual mode, and workspace support add substantial code. Estimate the remaining scope before starting those milestones.
- Keep third-party formatter/parser/LSP implementations as dependencies rather than copying them into the repository.
- If the planned product cannot fit the ceiling without damaging separation of concerns, make an explicit architecture decision to revise the ceiling or split packages. Do not hide required code in generated files or compress logic to game the count.

**Acceptance:** the size rule measures maintainability rather than blocking the intended product or incentivizing unreadable code.

### P4.3 Portability and terminal compatibility

- Decide whether Seby is intentionally Unix-only. If so, state that clearly and test supported Unix terminals. If cross-platform support is a goal, isolate terminal backends and replace Unix-only imports behind a small interface.
- Test Vty behavior across terminal sizes, Unicode widths, color capabilities, alternate screens, and terminal restoration.
- Keep platform-specific newline handling and filesystem guarantees covered by platform tests before claiming support.

**Acceptance:** every advertised platform has a tested terminal backend and file-safety story.

### P4.4 Ship a dependable release

- Add versioned release artifacts, checksums, changelog, upgrade notes, and a reproducible build process.
- Verify the executable’s startup help, unknown arguments, missing files, new files, and permission errors.
- Document minimum compiler, ICU, Cabal, and runtime requirements, including what Cabal downloads automatically.
- Measure startup time, formatter latency, memory use, and large-file behavior on representative Haskell packages.

**Acceptance:** a new user can install, start, edit, save, and recover from a failure by following the published instructions alone.

## Cross-cutting engineering requirements

- Every command has explicit semantics, including empty buffers, end-of-file, Unicode grapheme boundaries, counts, and failure cases.
- Every buffer mutation has a documented version, undo, redo, and saved-state effect.
- Every filesystem mutation preserves the existing atomicity, permissions, symlink/hardlink, staleness, encoding, and newline guarantees unless a reviewed design changes them.
- Every async subsystem tags results with buffer identity and document version, supports cancellation, and discards stale results.
- Avoid partial functions and unbounded work in the event loop. Keep CPU-heavy parsing, formatting, and project scans off the keystroke path where possible.
- Add property tests for algebraic invariants, focused tests for edge cases, and PTY integration tests for visible behavior. Keep benchmarks for measured performance claims.
- Update `Basilisk.md`, `README.md`, `INSTALL.md`, and this roadmap when scope or verified support changes. Generated architecture sections must continue to match the source tree.

## Suggested first sequence

1. Continue the literate-Haskell golden fixture matrix with unusual legal constructs and formatter API compatibility cases; tests cover config precedence, parse/config failure safety, Bird and LaTeX regions, mixed line endings, missing final newline, empty files, malformed LaTeX markers, undo behavior, and compile/run semantic preservation plus idempotence for a custom fixity fixture. Verify project/XDG config behavior across supported Fourmolu versions.
2. Keep the configured GHC CI matrix green as compiler versions advance; reconcile compiler/platform claims in README, INSTALL and `Basilisk.md` when bounds change.
3. Fill the remaining deterministic filesystem failure and exceptional-terminal cases under P0.2/P0.4.
4. Implement Visual mode and reuse the existing span semantics.
5. Add configurable indentation and comment continuation only after the Haskell behavior and settings model are clear; retain the current conservative Enter rules as the baseline.
6. Build versioned semantic snapshots, diagnostics, then HLS integration. Reassess the 3,000-line ceiling and workspace/session scope before buffer management or LSP growth.

## Completion standard

Seby is world-class when common editing is dependable without setup friction; saves cannot silently lose or misformat work; Haskell behavior follows the active project configuration; Unicode and terminal behavior are consistent; large files remain responsive; and every advertised feature is documented, tested, and recoverable when its dependencies fail. A long feature list without these guarantees does not meet the bar.
