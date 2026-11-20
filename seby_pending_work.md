# Seby: Pending Work for a World-Class Haskell Modal Editor

**Purpose:** the prioritized product and engineering roadmap for Basilisk/Seby.

**Snapshot:** roadmap last reviewed against the repository at commit `7810478` (`Format Haskell files automatically on save`); the compiler support statement was updated for the current GHC 9.10-and-newer policy. The built-in Fourmolu save path is implemented for `.hs` and `.lhs`; Markdown and plain text are saved unchanged. The project check script passed on GHC 9.14.1. The full supported compiler matrix is verified by CI.

This is a work plan, not a claim that the items below already exist. Mark an item done only after its acceptance criteria pass and the architecture handoff is updated.

## Product bar

Seby should make common editing tasks fast and predictable while protecting user data. Every feature should have an explicit behavior model, total edge-case handling, focused tests, and an end-to-end terminal check where terminal behavior is involved. Haskell support should use project settings and compiler semantics instead of approximating them with token heuristics.

Keep the editor modal and Haskell-first. Do not add a plugin framework or require users to install a plugin or run a formatter command for ordinary save behavior. Prefer well-supported Haskell libraries as in-process dependencies. Keep IO at the shell boundary, keep semantic state out of the core `Editor`, and preserve the existing file-safety guarantees.

## Priority summary

| Priority | Milestone | Outcome |
|---|---|---|
| P0 | Release confidence | Supported compiler matrix, reproducible builds, terminal regression coverage, and stable formatter behavior |
| P1 | Editing completeness | Text objects, visual selection, marks/registers, reliable command-line editing, and live indentation |
| P2 | Haskell intelligence | Incremental parsing, useful diagnostics, and version-safe Haskell Language Server integration |
| P3 | Workspace productivity | Multiple buffers, project navigation, user settings, and recoverable sessions |
| P4 | Scale and distribution | Responsive large-file behavior, portability decisions, packaging, and release operations |

Work in this order unless a measured user problem justifies reordering. P0 work reduces the risk of building later features on unverified assumptions.

## P0 — Release confidence and reliability

### P0.1 Verify the advertised compiler and dependency support

- Build and run the full check script across every supported GHC release line starting at 9.10.
- Verify both conditional Fourmolu dependency branches and their public `Ormolu` API usage.
- Review the `allow-newer: hpc` workaround in `cabal.project`. Keep it only if the GHC 9.14 package metadata mismatch still requires it; scope it to the narrowest supported condition and document why.
- Add a CI matrix for supported compiler lines, with a clean package cache at least in one job. Make the job run build, test suites, benchmarks, the partial-function sweep, and the generated-document check.
- Make the declared support range match what CI actually verifies. Do not imply Windows support while the executable imports the Unix Vty backend.

**Acceptance:** a fresh checkout builds without undocumented local packages or commands on every advertised compiler; CI exercises the same checks maintainers rely on locally.

### P0.2 Harden save-time formatting as a data-integrity boundary

- Test saves through `:w`, `:w!`, `:wq`, and `ZZ`, including success, parse failure, stale-file refusal, read-only files, and write failure.
- Verify that formatter failure never changes disk contents, never marks the buffer clean, and never quits after `:wq` or `ZZ`.
- Verify that a successful format updates the in-memory document, preserves the final-newline choice and line-ending policy, keeps the cursor on a sensible nearby location, creates one undoable change, and makes the resulting buffer clean only after the write succeeds.
- Exercise `.hs`, bird-style `.lhs`, and LaTeX-style `.lhs` files with prose, comments, language pragmas, CPP, and malformed input. Preserve literate prose byte-for-byte where feasible; explicitly reject unsupported constructs without writing.
- Honor Cabal component language extensions and dependencies. Decide whether `fourmolu.yaml` is an intentionally unsupported project setting or should be loaded through a stable public API. Do not silently claim compatibility with settings the formatter ignores.
- Improve formatter diagnostics shown in the status line: retain source path and location, avoid dumping unbounded multi-line exception text into the single-line UI, and keep enough detail available for review.
- Test formatter idempotence and semantic preservation against representative project fixtures, including custom fixities and comments around imports and declarations.

**Acceptance:** every failure mode leaves the original file intact and the user can understand why saving failed. Repeated saves of an already formatted file produce no content or history change.

### P0.3 Build a terminal-driven regression harness

- Add scripted PTY scenarios for startup, insert/edit, save, quit, resize, and error display.
- Assert the status and mode indicators remain anchored at the bottom row at small, normal, and resized terminal dimensions.
- Check that the terminal is restored after normal quit, save failure, formatter exceptions, and unexpected synchronous IO failures.
- Cover zero-size and narrow terminals, Unicode grapheme movement, wide glyphs, tabs, CR/LF variants, ANSI-like file contents, and terminal capability differences.
- Keep pure state-machine tests and terminal integration tests separate so failures identify the responsible layer.

**Acceptance:** key user-visible behaviors are reproduced automatically in a PTY; terminal regressions do not depend on a maintainer manually noticing a misplaced status line.

### P0.4 Define behavior and safety guarantees for the first release

- Document the supported subset of Vim-like behavior precisely, including known differences in counts, motions, repeat, Replace mode, search, and ex commands.
- Add recovery guidance and an explicit policy for unsupported binary files, invalid UTF-8, external modifications, symlinks, hardlinks, permissions, and formatter errors.
- Audit status messages for clipping, ambiguous success/failure wording, and stale messages that remain after the next action.
- Review atomic-write behavior on the filesystems and Unix platforms the project claims to support.

**Acceptance:** users can predict what each supported command does, how errors behave, and how the editor avoids overwriting unrelated work.

## P1 — Editing completeness and daily usability

### P1.1 Add text objects

- Implement inner and around objects for words, quoted strings, and balanced delimiters (`iw`/`aw`, `i"`/`a"`, `i(`/`a(`, plus bracket aliases where appropriate).
- Represent the selected range through the existing reach/operation algebra so delete, change, and yank share one selection definition.
- Specify behavior at empty lines, unmatched delimiters, nested delimiters, cursor-on-delimiter positions, counts, and Unicode grapheme boundaries.

**Acceptance:** each object works with `d`, `c`, and `y`; randomized laws cover range bounds and no-op behavior; examples match the documented Vim subset.

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

- Keep live indentation separate from whole-file formatting on save. Determine indentation from the preceding syntactic context, not only leading whitespace.
- Use the active file language: Haskell indentation for `.hs`/`.lhs`, conservative Markdown behavior, and no automatic rewriting for plain text.
- Define Enter behavior in insert mode, Backspace across indentation, paste behavior, tabs versus spaces, blank lines, closing delimiters, guards, `do`/`where`/`let`, and literate Haskell prefixes.
- Add comment-line insertion/continuation only when it can respect Haskell line, nested block, and literate syntax.
- Share a `shiftwidth`/indent policy with indentation operators so `>>` and live indentation do not disagree.

**Acceptance:** indentation is predictable on incomplete code, never corrupts text on paste or Backspace, respects configured width, and has a dedicated behavior table with tests.

### P1.6 Improve search and navigation

- Specify whether current search is literal-only and add regex search only with a safe engine and clear invalid-pattern behavior.
- Define forward/backward wrap, case sensitivity, empty pattern, Unicode matching, and operator-pending search behavior.
- Add jump history only if it has well-defined interaction with marks and undo.
- Keep count processing bounded and preserve the existing closed-form motion model.

**Acceptance:** search behavior is documented and deterministic for all directions, counts, and failures; no malformed pattern crashes the editor.

### P1.7 Close existing Replace-mode edge cases

- Add counts to `R` with one overwrite-based repeat model, including count exhaustion and undo behavior.
- When Backspace crosses a newline entered in Replace mode, restore the first grapheme of the following line as Vim does; retain correct restoration for empty lines and combining sequences.
- Keep the restore tape bounded and make it impossible to confuse inserted newlines with overwritten characters.

**Acceptance:** counted replacement is one coherent undo unit, and crossing a replaced newline in either direction restores the exact prior document.

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

- Choose and publish one default Fourmolu style, including indentation width and line width.
- Decide whether project `.fourmolu.yaml` options are supported. If supported, load them through a stable API and test malformed, missing, and inherited configuration. If not, clearly state that formatting uses Seby’s fixed built-in profile.
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

1. Verify every supported GHC release line from 9.10 onward in CI; settle the Hackage `hpc` bound workaround.
2. Add PTY regression coverage for save/quit/error/resize and bottom-anchored status rendering.
3. Finish formatter failure, literate-source, idempotence, cursor, newline, Cabal, and configuration policy tests.
4. Implement text objects against the existing reach algebra.
5. Implement Visual mode and reuse the same span semantics.
6. Add live indentation after the settings and Haskell syntax context needed to make it reliable.
7. Build versioned semantic snapshots, diagnostics, then HLS integration.
8. Reassess the 3,000-line ceiling and workspace/session scope before buffer management or LSP growth.

## Completion standard

Seby is world-class when common editing is dependable without setup friction; saves cannot silently lose or misformat work; Haskell behavior follows the active project configuration; Unicode and terminal behavior are consistent; large files remain responsive; and every advertised feature is documented, tested, and recoverable when its dependencies fail. A long feature list without these guarantees does not meet the bar.
