# Basilisk forensic quality audit and pending work

**Audit date:** 2026-11-21
**Audited checkout baseline:** `main`, commit `7cb187c` (`Test stale-file write and force override`); this update reconciles formatter status and current verification evidence.
**Scope:** repository contents, architecture, file safety, CLI behavior, build and verification controls, test evidence, and user-facing documentation. This is a source-level and local verification audit, not a security certification or a full interactive terminal acceptance test.

## Executive assessment

Basilisk has a coherent pure-core/IO-shell design and substantial pure-state coverage. Recent milestones hardened external-change detection, added conservative live Haskell indentation, enabled project/XDG Fourmolu configuration, validated literate layout, bounded formatter diagnostics, and added compiler-backed checks for formatting idempotence and a custom fixity. The save path detects content and identity changes, serializes cooperating Basilisk writers, and has targeted tests for several replacement and sync-failure cases. PTY tests cover basic save/quit, formatter failure, resize, and terminal restoration.

The repository is **not yet at editor-grade completion**. Project and user XDG Fourmolu configuration are loaded on save, and the literate-Haskell fixture set now covers the identified Bird/LaTeX layout and malformed-marker cases. Cross-version formatter API coverage remains open. Other gaps include filesystem failure coverage beyond injected cases and validated compiler/platform support. The partial-function scan is lexical rather than a proof. POSIX rename still cannot close the race with unrelated writers that ignore Basilisk's advisory locks.

This audit was refreshed after the formatter reliability milestones through `d11b470`. The separate product roadmap is maintained in `seby_pending_work.md`.

## Verification evidence

`./scripts/check.sh` passed on macOS arm64 with GHC 9.10.3 at `7cb187c`. It includes build, all four test suites, the
partial-function sweep, line-count ceiling, benchmarks, CLI/PTY checks and
generated-document consistency. The completed GitHub Actions run for commit
`b1837f2` also passed all four configured GHC jobs; the run is linked from
`INSTALL.md`.

| Check | Result |
|---|---:|
| Build all components, tests and benchmarks | Passed; zero warnings in check-script build |
| Haskell LOC ceiling (same lexical count as `scripts/check.sh`) | 2,479 / 3,000 |
| Hedgehog laws | 39 passed |
| Smoke checks | 230 passed |
| Exhaustive mode/command/document combinations | 629,640, zero exceptions |
| Save-time formatter, compiler-backed preservation, and file-write integration | Passed |
| Complexity benchmarks | Passed |
| PTY terminal regressions | Passed, including terminal attribute restoration |
| Generated `Basilisk.md` consistency | Passed |
| Full `scripts/check.sh` | **ALL CHECKS PASSED** |

The observed local toolchain is **GHC 9.10.3 on macOS arm64**. The full local check passed on that combination at `7cb187c`. GitHub Actions run `44923039398` passed the configured Ubuntu 24.04 jobs for GHC 9.10, 9.12, 9.14 and `latest` at commit `b1837f2`, including the scoped `hpc` workaround. That remote result predates the latest formatter test additions and is not evidence that `7cb187c` passed the compiler matrix.

## Findings and remediation plan

Severity: **P0** means release-blocking data loss/security risk; **P1** means a core reliability or compatibility risk; **P2** means a meaningful usability, quality-control, or documentation gap; **P3** means polish or longer-term capability. Confidence distinguishes a directly demonstrated repository fact from a plausible risk requiring additional reproduction.

### QF-01 — External-change detection and cooperating-writer races — addressed

**Status:** Addressed in commit `e396c9d`.
**Evidence:** `src/Basilisk/Types.hs` records device, inode, high-resolution modification/change times, size, and SHA-256 content digest. `src/Basilisk/File.hs` serializes Basilisk writers with per-user advisory byte-range locks keyed by path and inode, then rechecks the fingerprint after writing the temporary file and before replacement. Hardlink aliases share the inode lock. `test/Formatter.hs` covers same-size content changes with preserved mtime, path replacement, an external edit during temporary-file preparation, and post-rename sync failure.

**Concurrency contract:** Basilisk instances serialize writes to the same path or inode. Changes visible at the final fingerprint check are refused unless `:w!` is used. POSIX rename has no portable compare-and-swap operation, and advisory locks do not constrain unrelated programs, so a non-cooperating writer can still race the final check-to-commit interval. This limit is stated in `README.md` and the generated `Basilisk.md`.

### QF-02 — CLI silently accepts unknown options — addressed

**Severity:** P2
**Confidence:** Confirmed from implementation and executable-level tests.
**Status:** `app/Main.hs` now parses `-h`/`--help` and `-v`/`--version` as standalone options, rejects unknown options with a nonzero exit and clear diagnostic, accepts one path, and supports `--` for a leading-dash filename. `test/Terminal.py` exercises these cases, multiple paths, no-argument startup, and ordinary one-file open/save.

**Impact:** Mistyped safety or behavior flags can go unnoticed; command-line behavior is surprising and difficult to script reliably.

**Evidence:** `./scripts/check.sh` runs the CLI checks with the real executable in addition to the existing PTY terminal scenarios.

**Acceptance:** Met locally; remote compiler-matrix CI remains unverified.

### QF-03 — Installation and verification claims need a single current source — addressed

**Severity:** P2
**Confidence:** Confirmed against package bounds, the checked-in CI workflow, local checks, and a completed remote CI run.
**Status:** README, INSTALL and the generated handoff distinguish the GHC 9.10 minimum from compiler lines selected by CI and the exact local verification. Ubuntu instructions use GHCup to meet the compiler floor. Test-suite commands use `cabal test`. The `allow-newer: ghc-lib-parser:hpc` workaround is scoped to that package and GHC 9.14+, matching the bundled hpc metadata issue.
**Evidence:** Local GHC 9.10.3/macOS arm64 `./scripts/check.sh` passes, and the scoped hpc configuration resolves locally. GitHub Actions run `44923039398` passed GHC 9.10, 9.12, 9.14 and `latest` on Ubuntu 24.04 at commit `b1837f2`.

**Impact:** Contributors can select a toolchain that has not been verified and receive misleading expectations about test coverage.

**Work:** Keep the scoped hpc workaround and compiler matrix under review as GHC/Fourmolu bounds change. Record new matrix outcomes with their commit and run link; do not claim an unobserved result.

**Acceptance:** Met for the current compiler/platform support record and installation instructions. Recheck the matrix as compiler and dependency bounds change.

### QF-04 — Formatter configuration is supported; literate-Haskell layout is reconstructed and validated

**Severity:** P1
**Confidence:** Confirmed implementation boundaries; impact depends on user files and expected policy.
**Status:** Fourmolu configuration discovery and error handling are implemented. `src/Basilisk/Loop.hs` uses Fourmolu's config search and YAML parser; project ancestor files take precedence over the XDG user config. Printer options, fixity overrides and re-exports are passed into the formatter. Tests cover nested project precedence, XDG fallback, a custom indentation option, malformed YAML, and refusal to write on config failure. A rank-2 source without a LANGUAGE pragma is formatted using its Cabal component's `RankNTypes` default extension, and compiles/runs with matching behavior before and after formatting. Literate fixtures cover blank Bird code lines, CRLF and missing-final-newline input, mixed line endings, prose and marker-like text, multiple LaTeX code regions, empty `.lhs` files, and malformed/nested/unmatched LaTeX markers. A compiler-backed CPP fixture includes conditional imports and declarations; both configurations compile and preserve their runtime results before and after formatting. Formatter and validation failures preserve existing bytes and prevent quit-after-save. An experiment with Fourmolu 0.17.0.0 confirmed its in-process API parses supplied source as ordinary Haskell without the literate preprocessor; the implementation therefore shields prose and restores the literate layout around formatting.
**Compatibility note:** The implementation decodes Fourmolu's exposed `Ormolu.Config.FourmoluConfig` type. Fourmolu identifies its top-level `Ormolu` module as the stable API; the configured GHC/Fourmolu matrix must catch changes to this config API.
**Remaining evidence:** `src/Basilisk/Loop.hs` still recognizes Bird files by lines starting with `>` and LaTeX files by code-block markers, then reconstructs prose with generated marker lines. Fixtures cover marker-like and indented prose, blank code lines, mixed endings, missing final newline, parse/config failures, complete output, and undo state. Formatter diagnostics are normalized to one line, include the source path, and are capped at 512 detail characters. Compiler-backed fixtures check a Cabal-provided extension, conditional imports and declarations in both CPP branches, and a right-associative custom operator before and after formatting; repeated formatting is byte-idempotent and does not change the buffer version or undo result. Cross-version validation remains dependent on the configured CI matrix; unusual legal layouts and the custom reconstruction strategy still merit review.

**Impact:** Fourmolu's in-process API behavior may change across supported versions, and unusual legal literate constructs outside the fixture matrix may still not round-trip as intended. Since formatting is automatic on save, policy surprises are particularly costly.

**Work:** Verify the exposed config API on every configured Fourmolu/compiler branch. Continue checking complete output, buffer/undo state, and unusual literate constructs as supported Haskell syntax evolves.

**Acceptance:** Project and XDG config lookup works across supported compiler branches; supported literate forms preserve prose and file conventions in a golden fixture suite; invalid source/config never writes partially formatted output, marks the buffer clean, or exits after a failed write.

### QF-05 — Terminal and filesystem failure coverage is useful but incomplete

**Severity:** P1
**Confidence:** Confirmed coverage gap from test inventory; latent defects are not asserted.
**Evidence:** `test/Terminal.py` is a real PTY harness and `scripts/check.sh` runs it. It checks successful `:w`, `:wq`, and `ZZ` saves; formatter failure followed by force-quit through both quit-on-save commands; stale-file refusal through `:w`; deliberate override through `:w!`; read-only refusal; and forced overwrite while preserving permissions. It also checks resize and terminal restoration for those flows. The `:w` test confirms the editor remains available for further edits after writing. The harness reads terminal state from the PTY master on Darwin after the child session detaches. It does not cover exceptional process exits or a broad key/terminal escape-sequence matrix. `test/Formatter.hs` injects a pre-commit external edit and a post-rename directory-sync failure; it also checks timestamp-collision and path-replacement detection. The file layer additionally handles symlinks, hardlinks, fsync and rename, but remaining IO failure paths do not all have dedicated failure-injection tests. The exhaustive Haskell suite is a pure transition sweep, not terminal IO coverage.

**Impact:** Terminal restoration, bottom-anchored status placement, resize handling, key decoding under terminal escape sequences, and failures during write/flush/rename/fsync can regress without the current checks noticing.

**Work:** Extend the existing PTY harness to cover exceptional exits and more key/status flows. Add deterministic tests for permission-denied destinations, failed writes and cleanup, symlink/hardlink behavior, metadata preservation, and each injectable atomic-write failure phase. Keep platform-dependent assertions isolated.

**Acceptance:** CI exercises critical terminal flows and the persistence invariants claimed by the product; injected failures leave a defined status, preserve the old file before commit, and do not falsely report success after commit.

### QF-06 — Partial-function check is a heuristic, not a sound guarantee

**Severity:** P2
**Confidence:** Confirmed by inspection.
**Evidence:** `scripts/check.sh` removes string literals and trailing comments with two `sed` substitutions and searches for a fixed set of names/operators. It is not Haskell-aware, can mis-handle escaped quotes and nested/block comments, and does not detect every partial API or partial pattern.

**Impact:** The “no partial functions” gate can pass code containing partial behavior or fail on harmless syntax. Its status is stronger than the check can establish.

**Work:** Replace the textual sweep with compiler warnings and a Haskell-aware lint/policy check, or narrow the claim to the exact banned tokens and document the heuristic. Add a self-test corpus for false positives and false negatives. Review pattern matches and external library calls through code review/static analysis.

**Acceptance:** CI check has a clearly defined scope, is tested against representative Haskell syntax, and reports no stronger assurance than it provides.

### QF-07 — Compatibility claims exceed the demonstrated platform matrix

**Severity:** P1
**Confidence:** Confirmed gap between platform-specific code and observed validation.
**Evidence:** `src/Basilisk/Loop.hs` imports `Graphics.Vty.Platform.Unix.mkVty`; `src/Basilisk/File.hs` uses POSIX file descriptors and `fileSynchronise`. CI targets Ubuntu 24.04 and four GHC selectors. A local macOS arm64 GHC 9.10.3 full `scripts/check.sh` run passed; GitHub Actions run `44923039398` passed all four configured compiler jobs at commit `b1837f2`.

**Impact:** Compiler API, dependency, terminal, or filesystem differences can break a release on an advertised or assumed platform.

**Work:** Decide whether macOS is supported. If it is, add macOS CI and exercise terminal setup, directory syncing, rename semantics, permissions, and hardlink behavior. Capture results from each configured GHC matrix job and track dependency bounds against those results. Keep Windows explicitly unsupported while the implementation depends on Unix APIs.

**Acceptance:** Every claimed platform/compiler has a repeatable CI job, or public docs clearly mark it unsupported/untested.

### QF-08 — Save-path and effect documentation has drifted from behavior

**Severity:** P3
**Confidence:** Confirmed source documentation inconsistency.
**Evidence:** `src/Basilisk/File.hs` describes its `Text` input as already line-ending encoded by `Basilisk.Step`. For Haskell saves, `src/Basilisk/Loop.hs` formats the document and serializes the prepared editor before calling `File.writeDocument`; ordinary saves receive the serialized text from the `WriteFile` effect in `Step`. `performWith` installs formatted contents and marks the buffer clean only after the writer succeeds. Existing formatter tests cover parse failure and successful post-format undo, but not a writer failure after formatting has changed the prepared buffer.

**Impact:** Future changes can rely on an incorrect layer boundary or misunderstand whether formatting is part of the pure step/effect interpreter contract.

**Work:** Clarify that `File` receives serialized `Text` (not bytes) and that Haskell formatting/re-serialization is owned by `Loop`. Add state assertions for format, stale-write, and IO failures when formatting changed the prepared buffer.

**Acceptance:** Module comments match call flow, and failure-state tests define whether formatted buffer contents are retained or rolled back.

## Architecture and product work that remains

The feature roadmap in `seby_pending_work.md` and the limitations in `Basilisk.md` identify substantial product scope beyond the findings above. Prioritize these as separate, reviewable milestones rather than treating the passing checks as feature completion:

1. **Reliability foundation:** QF-01 is closed. Complete the remaining QF-05 IO/PTY cases; retain the current save/quit, undo and mixed-EOL invariants.
2. **Editor interaction:** add user-requested missing modal behavior with explicit keymap contracts, PTY acceptance, and accessibility for status/error feedback. Revisit Replace-mode edge cases and count semantics.
3. **Language experience:** complete the literate-Haskell fixture matrix under QF-04, then add parser-backed diagnostics only after the core interaction and performance contracts are settled. Conservative live Haskell indentation was added in commit `68bc901`; it is rule-based, not parser-backed.
4. **World-class editing:** evaluate visual selections, text objects, marks/registers, macros, substitutions/ranges, multi-buffer navigation, splits, and configuration against a coherent command model and undo history.
5. **Performance and scale:** retain benchmark baselines, profile long-line and large-file behavior, and set explicit latency/memory budgets before optimizing.
6. **Release engineering:** align README, INSTALL, generated architecture record, CI matrix, versioning, and release checklist; state unsupported platform and file-format boundaries plainly.

## Audit boundaries and next gate

This report does not claim a complete formal audit of every key binding or every branch in the 2,479-line lexical count used by `scripts/check.sh`. The complete local `./scripts/check.sh` passed at `7cb187c` on macOS arm64 with GHC 9.10.3; GitHub Actions run `44923039398` passed the configured GHC matrix at the earlier `b1837f2` baseline. These checks do not establish correctness for all terminal emulators, filesystems, compiler versions, race schedules, Unicode/grapheme clusters, or malformed inputs. A deeper follow-up should turn each P1 item above into a bounded engineering milestone with regression tests and measured acceptance.

**Recommended next gate:** verify the Fourmolu config API across the configured compiler branches and continue checking unusual literate-Haskell constructs. QF-01 is closed and config lookup/error behavior has focused coverage. Continue QF-05's remaining filesystem and exceptional-terminal cases before release; the basic PTY harness and selected write-race/failure tests already exist.
