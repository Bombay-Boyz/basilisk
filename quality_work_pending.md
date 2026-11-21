# Basilisk forensic quality audit and pending work

**Audit date:** 2026-11-21
**Audited checkout:** `main`, commit `68bc901` (`Add conservative Haskell live indentation`)
**Scope:** repository contents, architecture, file safety, CLI behavior, build and verification controls, test evidence, and user-facing documentation. This is a source-level and local verification audit, not a security certification or a full interactive terminal acceptance test.

## Executive assessment

Basilisk has a coherent pure-core/IO-shell design and substantial pure-state coverage. Two recent milestones hardened external-change detection and added conservative live Haskell indentation. The save path detects content and identity changes, serializes cooperating Basilisk writers, and has targeted tests for several replacement and sync-failure cases. Existing PTY tests cover basic save/quit, formatter failure, resize, and terminal restoration.

The repository is **not yet at editor-grade completion**. The most important remaining gaps are a documented and configurable formatter policy, broader formatter fixtures for literate Haskell, unknown CLI option handling, filesystem failure coverage beyond the injected cases, and validated compiler/platform support. The partial-function scan is lexical rather than a proof. POSIX rename still cannot close the race with unrelated writers that ignore Basilisk's advisory locks.

This update records repository state after commits `e396c9d` and `68bc901`. No source code is changed by this report update. The separate `seby_pending_work.md` is outside this audit update.

## Verification evidence

At this checkout, `cabal build all --enable-tests --enable-benchmarks` and
`cabal test all --test-show-details=direct` passed on macOS arm64 with GHC
9.10.3. The build emitted linker search-path warnings for ICU locations not
present on this machine; no Haskell compiler warnings were reported. The
script `./scripts/check.sh` was not run for this update, so its benchmarks,
PTY stage, partial-function sweep, and generated-document check are not
claimed as verified here.

| Check | Result |
|---|---:|
| Build all components, tests and benchmarks | Passed; linker warnings noted above |
| Haskell LOC ceiling (same lexical count as `scripts/check.sh`) | 2,402 / 3,000 |
| Hedgehog laws | 39 passed |
| Smoke checks | 230 passed |
| Exhaustive mode/command/document combinations | 629,640, zero exceptions |
| Save-time formatter and file-write integration | Passed |
| `git diff --check` | Passed for the implementation commits |
| Full `scripts/check.sh`, including benchmarks and PTY | Not run at this checkout |

The observed local toolchain is **GHC 9.10.3 on macOS arm64**. This verifies a build and Cabal tests on that combination, but not the full PTY/check script there. `.github/workflows/ci.yml` configures Ubuntu 24.04 jobs for GHC 9.10, 9.12, 9.14 and `latest`; this report does not claim those remote jobs passed.

## Findings and remediation plan

Severity: **P0** means release-blocking data loss/security risk; **P1** means a core reliability or compatibility risk; **P2** means a meaningful usability, quality-control, or documentation gap; **P3** means polish or longer-term capability. Confidence distinguishes a directly demonstrated repository fact from a plausible risk requiring additional reproduction.

### QF-01 — External-change detection and cooperating-writer races — addressed

**Status:** Addressed in commit `e396c9d`.
**Evidence:** `src/Basilisk/Types.hs` records device, inode, high-resolution modification/change times, size, and SHA-256 content digest. `src/Basilisk/File.hs` serializes Basilisk writers with per-user advisory byte-range locks keyed by path and inode, then rechecks the fingerprint after writing the temporary file and before replacement. Hardlink aliases share the inode lock. `test/Formatter.hs` covers same-size content changes with preserved mtime, path replacement, an external edit during temporary-file preparation, and post-rename sync failure.

**Concurrency contract:** Basilisk instances serialize writes to the same path or inode. Changes visible at the final fingerprint check are refused unless `:w!` is used. POSIX rename has no portable compare-and-swap operation, and advisory locks do not constrain unrelated programs, so a non-cooperating writer can still race the final check-to-commit interval. This limit is stated in `README.md` and the generated `Basilisk.md`.

### QF-02 — CLI silently accepts unknown options

**Severity:** P2
**Confidence:** Confirmed from implementation.
**Evidence:** `app/Main.hs:18-28` filters every argument beginning with `-` without validating it. For example, an unrecognized `--typo` is silently ignored, and `basilisk --typo file.hs` opens the file as if the option had been accepted.

**Impact:** Mistyped safety or behavior flags can go unnoticed; command-line behavior is surprising and difficult to script reliably.

**Work:** Parse the supported help/version options explicitly; reject unknown options with a concise diagnostic and nonzero exit status; define how a filename beginning with `-` is passed (for example, `--`). Add executable-level argument tests for no args, one path, multiple paths, supported flags, unknown flags, and option-like filenames.

**Acceptance:** Every unrecognized option fails clearly, help/version behavior is deterministic, and a leading-dash path has a documented invocation.

### QF-03 — Installation and verification claims need a single current source

**Severity:** P2
**Confidence:** Confirmed documentation drift.
**Evidence:** `INSTALL.md` says macOS is untested, but the current source has now built and passed all Cabal test suites locally on macOS arm64 with GHC 9.10.3. That did not include the full PTY/check script. `.github/workflows/ci.yml` configures GHC 9.10, 9.12, 9.14 and `latest` on Ubuntu 24.04. `INSTALL.md` still lists 34 properties and 136 smoke examples; the latest local run reports 39 and 230. `Basilisk.md`/`docgen.py` still name a Linux GHC 9.14.1 verification environment and contain prior verification claims that have not been rerun at this checkout.

**Impact:** Contributors can select a toolchain that has not been verified and receive misleading expectations about test coverage.

**Work:** Separate declared support from combinations actually verified. Update stale test counts or replace them with stable suite descriptions. Reconcile README, INSTALL, Cabal constraints, CI, and generated architecture notes without claiming unobserved CI results.

**Acceptance:** One source of truth describes supported GHC versions/platforms; installation instructions work on the declared baseline; no stale test count remains.

### QF-04 — Formatter policy and literate-Haskell handling need a compatibility contract

**Severity:** P1
**Confidence:** Confirmed implementation boundaries; impact depends on user files and expected policy.
**Evidence:** `src/Basilisk/Loop.hs:142-150` builds configuration from Fourmolu defaults and Cabal information, with no project formatter configuration passed. `src/Basilisk/Loop.hs:152-192` identifies Bird files by any line starting with `>` and LaTeX files by code-block markers, then reconstructs prose using generated marker lines. Existing `test/Formatter.hs` covers one basic Bird file, one basic LaTeX file, Cabal extensions, ordinary Haskell, Markdown, and parse failure, but not diverse literate layouts or formatter configuration discovery.

**Impact:** Save can reformat a file according to a policy different from the repository's expected policy. Unusual or malformed literate files may be misclassified, lose layout, or receive formatting that does not preserve intended structure. Since formatting is automatic on save, policy surprises are particularly costly.

**Work:** Specify default and project-level policy (including whether Fourmolu configuration is honored); test configuration lookup and precedence. Build a fixture matrix for Bird/LaTeX prose, blank and indented lines, multiple code regions, marker-like source text, empty files, missing final newline, CRLF/mixed endings, and parse/config failures. Compare complete byte output and buffer/undo state. Consider using the formatter's supported literate input path rather than custom marker reconstruction if available.

**Acceptance:** Supported literate forms and configuration precedence are explicit; formatting preserves prose and file conventions in a golden fixture suite; invalid source never writes partially formatted output or marks the buffer clean.

### QF-05 — Terminal and filesystem failure coverage is useful but incomplete

**Severity:** P1
**Confidence:** Confirmed coverage gap from test inventory; latent defects are not asserted.
**Evidence:** `test/Terminal.py` is a real PTY harness and `scripts/check.sh` runs it. It checks write/quit, formatter failure followed by force-quit, resize, and terminal restoration for those flows. It does not cover exceptional process exits or a broad key/terminal escape-sequence matrix. `test/Formatter.hs` injects a pre-commit external edit and a post-rename directory-sync failure; it also checks timestamp-collision and path-replacement detection. The file layer additionally handles permissions, symlinks, hardlinks, fsync and rename, but these behaviors do not all have dedicated failure-injection tests. The exhaustive Haskell suite is a pure transition sweep, not terminal IO coverage.

**Impact:** Terminal restoration, bottom-anchored status placement, resize handling, key decoding under terminal escape sequences, and failures during write/flush/rename/fsync can regress without the current checks noticing.

**Work:** Extend the existing PTY harness to cover exceptional exits and more key/status flows. Add deterministic tests for permission denial, failed writes and cleanup, symlink/hardlink behavior, metadata preservation, and each injectable atomic-write failure phase. Keep platform-dependent assertions isolated.

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
**Evidence:** `src/Basilisk/Loop.hs` imports `Graphics.Vty.Platform.Unix.mkVty`; `src/Basilisk/File.hs` uses POSIX file descriptors and `fileSynchronise`. CI is configured for Ubuntu 24.04 and four GHC selectors. A local macOS arm64 GHC 9.10.3 build and all Cabal suites passed, but the full PTY/check script was not verified there, and this report has no result for the configured remote matrix.

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
3. **Language experience:** close QF-04 by defining formatter configuration and literate-Haskell behavior, then add parser-backed diagnostics only after the core interaction and performance contracts are settled. Conservative live Haskell indentation was added in commit `68bc901`; it is rule-based, not parser-backed.
4. **World-class editing:** evaluate visual selections, text objects, marks/registers, macros, substitutions/ranges, multi-buffer navigation, splits, and configuration against a coherent command model and undo history.
5. **Performance and scale:** retain benchmark baselines, profile long-line and large-file behavior, and set explicit latency/memory budgets before optimizing.
6. **Release engineering:** align README, INSTALL, generated architecture record, CI matrix, versioning, and release checklist; state unsupported platform and file-format boundaries plainly.

## Audit boundaries and next gate

This report does not claim a complete formal audit of every key binding or every branch in the 2,402-line lexical count used by `scripts/check.sh`. The Cabal build and test suites passed locally; the complete automated script and remote CI matrix are not claimed as passing for this checkout. These checks do not establish correctness for all terminal emulators, filesystems, compiler versions, race schedules, Unicode/grapheme clusters, or malformed inputs. A deeper follow-up should turn each P1 item above into a bounded engineering milestone with regression tests and measured acceptance.

**Recommended next gate:** resolve the formatter contract (QF-04): decide project configuration precedence, then add golden fixtures for literate forms and failure-state behavior. QF-01 is closed. Continue QF-05's remaining filesystem and exceptional-terminal cases before release; the basic PTY harness and selected write-race/failure tests already exist.
