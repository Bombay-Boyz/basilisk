# Basilisk forensic quality audit and pending work

**Audit date:** 2026-11-20
**Audited checkout:** `main`, commit `7810478` (`Format Haskell files automatically on save`)
**Scope:** repository contents, architecture, file safety, CLI behavior, build and verification controls, test evidence, and user-facing documentation. This is a source-level and local verification audit, not a security certification or a full interactive terminal acceptance test.

## Executive assessment

Basilisk has a coherent pure-core/IO-shell design and unusually strong pure-state and filesystem test coverage for a small editor. The current verification script passes in the audited environment. The editor is usable, and the save path has meaningful safeguards for interrupted writes, symlinks, hardlinks, permissions, line endings, stale files, and Haskell formatting failures.

The repository is **not yet at world-class/editor-grade completion**. The highest-priority gaps are trustworthy external-change detection under timestamp collisions and races, a parser-faithful and user-configurable formatting policy, a broader compiler/OS compatibility matrix, and more realistic terminal and filesystem fault-injection tests. The current check suite is a valuable regression gate, but its partial-function scan is lexical rather than a proof, and it does not exercise important interactive and concurrent-file behaviors.

No source code was changed during this audit. The only file created is this pending-work report. The pre-existing untracked `seby_pending_work.md` was left untouched.

## Verification evidence

Ran `./scripts/check.sh` at the audited commit. It completed with **ALL CHECKS PASSED**:

| Check | Result |
|---|---:|
| Build all components | Zero warnings |
| Partial-function source scan | Passed |
| Haskell LOC ceiling | 1,941 / 3,000 |
| Hedgehog laws | 39 passed |
| Smoke checks | 201 passed |
| Exhaustive mode/command/document combinations | 628,452, zero exceptions |
| Save-time formatter integration | Passed |
| Complexity benchmarks | No scaling regression detected |
| Generated `Basilisk.md` consistency | In sync |

The observed toolchain was **GHC 9.14.1**. The run does not establish compatibility with GHC 9.10/9.12, macOS, or other Unix environments. CI is configured in `.github/workflows/ci.yml` to run the same check script on Ubuntu 24.04, but this local audit did not inspect a remote CI run.

## Findings and remediation plan

Severity: **P0** means release-blocking data loss/security risk; **P1** means a core reliability or compatibility risk; **P2** means a meaningful usability, quality-control, or documentation gap; **P3** means polish or longer-term capability. Confidence distinguishes a directly demonstrated repository fact from a plausible risk requiring additional reproduction.

### QF-01 — External-change detection and cooperating-writer races — addressed

**Status:** Addressed in the current source tree.
**Evidence:** `src/Basilisk/Types.hs` records device, inode, high-resolution modification/change times, size, and SHA-256 content digest. `src/Basilisk/File.hs` serializes Basilisk writers with per-user advisory byte-range locks keyed by path and inode, then rechecks the fingerprint after writing the temporary file and before replacement. Hardlink aliases share the inode lock. `test/Formatter.hs` covers same-size content changes with preserved mtime, path replacement, an external edit during temporary-file preparation, and post-rename sync failure.

**Concurrency contract:** Basilisk instances serialize writes to the same path or inode. Changes visible at the final fingerprint check are refused unless `:w!` is used. POSIX rename has no portable compare-and-swap operation, and advisory locks do not constrain unrelated programs, so a non-cooperating writer can still race the final check-to-commit interval. This limit is stated in `README.md` and the generated `Basilisk.md`.

### QF-02 — CLI silently accepts unknown options

**Severity:** P2
**Confidence:** Confirmed from implementation.
**Evidence:** `app/Main.hs:18-28` filters every argument beginning with `-` without validating it. For example, an unrecognized `--typo` is silently ignored, and `basilisk --typo file.hs` opens the file as if the option had been accepted.

**Impact:** Mistyped safety or behavior flags can go unnoticed; command-line behavior is surprising and difficult to script reliably.

**Work:** Parse the supported help/version options explicitly; reject unknown options with a concise diagnostic and nonzero exit status; define how a filename beginning with `-` is passed (for example, `--`). Add executable-level argument tests for no args, one path, multiple paths, supported flags, unknown flags, and option-like filenames.

**Acceptance:** Every unrecognized option fails clearly, help/version behavior is deterministic, and a leading-dash path has a documented invocation.

### QF-03 — Installation guide has stale toolchain and test-count claims

**Severity:** P2
**Confidence:** Confirmed documentation drift.
**Evidence:** `INSTALL.md:5-26` previously stated a compiler baseline below the project's intended support range. The audited build used GHC 9.14.1, and `Basilisk.cabal` contains version-dependent Fourmolu bounds. `INSTALL.md:75-77` lists 34 properties and 136 smoke examples, while the current run reports 39 and 201. `README.md` repeated the outdated installation assumption.

**Impact:** Contributors can select a toolchain that has not been verified and receive misleading expectations about test coverage.

**Work:** Establish the supported compiler range from actual builds; state a minimum, CI compiler(s), and tested platforms. Update stale counts or replace counts with stable suite descriptions and link exact current results. Reconcile README, INSTALL, Cabal constraints, CI, and architecture notes.

**Acceptance:** One source of truth describes supported GHC versions/platforms; installation instructions work on the declared baseline; no stale test count remains.

### QF-04 — Formatter policy and literate-Haskell handling need a compatibility contract

**Severity:** P1
**Confidence:** Confirmed implementation boundaries; impact depends on user files and expected policy.
**Evidence:** `src/Basilisk/Loop.hs:142-150` builds configuration from Fourmolu defaults and Cabal information, with no project formatter configuration passed. `src/Basilisk/Loop.hs:152-192` identifies Bird files by any line starting with `>` and LaTeX files by code-block markers, then reconstructs prose using generated marker lines. Existing `test/Formatter.hs` covers one basic Bird file, one basic LaTeX file, Cabal extensions, ordinary Haskell, Markdown, and parse failure, but not diverse literate layouts or formatter configuration discovery.

**Impact:** Save can reformat a file according to a policy different from the repository's expected policy. Unusual or malformed literate files may be misclassified, lose layout, or receive formatting that does not preserve intended structure. Since formatting is automatic on save, policy surprises are particularly costly.

**Work:** Specify default and project-level policy (including whether Fourmolu configuration is honored); test configuration lookup and precedence. Build a fixture matrix for Bird/LaTeX prose, blank and indented lines, multiple code regions, marker-like source text, empty files, missing final newline, CRLF/mixed endings, and parse/config failures. Compare complete byte output and buffer/undo state. Consider using the formatter's supported literate input path rather than custom marker reconstruction if available.

**Acceptance:** Supported literate forms and configuration precedence are explicit; formatting preserves prose and file conventions in a golden fixture suite; invalid source never writes partially formatted output or marks the buffer clean.

### QF-05 — Automated checks do not cover terminal behavior and important IO failures

**Severity:** P1
**Confidence:** Confirmed coverage gap from test inventory; latent defects are not asserted.
**Evidence:** `test/Formatter.hs`, `test/Smoke.hs`, `test/Laws.hs`, and `test/Exhaustive.hs` provide strong pure and formatter coverage. The exhaustive suite exercises pure mode/command/document combinations, not a real terminal. `src/Basilisk/File.hs` implements permissions, symlink/hardlink, fsync, rename, and error handling, while the main check reports no dedicated filesystem fault-injection or PTY suite.

**Impact:** Terminal restoration, bottom-anchored status placement, resize handling, key decoding under terminal escape sequences, and failures during write/flush/rename/fsync can regress without the current checks noticing.

**Work:** Add a PTY-based acceptance harness for startup, mode/status placement, quit/write flows, resize, and terminal restoration after normal and exceptional exits. Add filesystem tests around permission denial, full/failed writes, temp cleanup, symlink targets, hardlink preservation, metadata preservation, and failures at each atomic-write phase. Keep tests deterministic and isolate platform-dependent cases.

**Acceptance:** CI exercises critical user-visible terminal flows and each promised persistence invariant; injected IO failures leave a defined status and do not falsely report success.

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
**Evidence:** `src/Basilisk/Loop.hs:23` imports `Graphics.Vty.Platform.Unix.mkVty`; `src/Basilisk/File.hs` uses POSIX file descriptors and `fileSynchronise`. `INSTALL.md:13-17` labels macOS untested. CI uses Ubuntu 24.04 only. The audit verified one GHC version and one Linux environment.

**Impact:** Compiler API, dependency, terminal, or filesystem differences can break a release on an advertised or assumed platform.

**Work:** Declare Linux-only support explicitly until tested; if macOS is a goal, add macOS CI and verify terminal setup, directory syncing, rename semantics, permissions, and hardlink behavior there. Build at the oldest supported GHC and current CI GHC. Track dependency bounds against that matrix.

**Acceptance:** Every claimed platform/compiler has a repeatable CI job, or public docs clearly mark it unsupported/untested.

### QF-08 — Save-path and effect documentation has drifted from behavior

**Severity:** P3
**Confidence:** Confirmed source documentation inconsistency.
**Evidence:** `src/Basilisk/File.hs:151-154` says bytes arrive already line-ending encoded from `Basilisk.Step`; however, Haskell save formatting occurs in `src/Basilisk/Loop.hs:75-102` and the final text is serialized there before `File.writeDocument`. `perform` only installs the prepared formatted buffer after a successful write, so failure-state behavior is also an important contract to keep explicit.

**Impact:** Future changes can rely on an incorrect layer boundary or misunderstand whether formatting is part of the pure step/effect interpreter contract.

**Work:** Update Haddock to describe the actual sequence and ownership of serialization/formatting. Document and test the editor-state behavior on format failure, stale-write failure, and IO failure, especially when formatting changed the in-memory document.

**Acceptance:** Module comments match call flow, and failure-state tests define whether formatted buffer contents are retained or rolled back.

## Architecture and product work that remains

The feature roadmap in `seby_pending_work.md` and the limitations in `Basilisk.md` identify substantial product scope beyond the findings above. Prioritize these as separate, reviewable milestones rather than treating the passing checks as feature completion:

1. **Reliability foundation:** resolve QF-01 and QF-05; formalize save/quit and undo invariants; add property tests for document edits, history, and mixed-EOL round trips.
2. **Editor interaction:** add user-requested missing modal behavior with explicit keymap contracts, PTY acceptance, and accessibility for status/error feedback. Revisit Replace-mode edge cases and count semantics.
3. **Language experience:** define formatter configuration, then add parser-backed diagnostics and incremental parsing only after the core interaction and performance contracts are settled.
4. **World-class editing:** evaluate visual selections, text objects, marks/registers, macros, substitutions/ranges, multi-buffer navigation, splits, and configuration against a coherent command model and undo history.
5. **Performance and scale:** retain benchmark baselines, profile long-line and large-file behavior, and set explicit latency/memory budgets before optimizing.
6. **Release engineering:** align README, INSTALL, generated architecture record, CI matrix, versioning, and release checklist; state unsupported platform and file-format boundaries plainly.

## Audit boundaries and next gate

This report does not claim a complete formal audit of every key binding or every branch in the 1,941 non-comment Haskell LOC. The full automated check passed, but it does not establish correctness for all terminal emulators, filesystems, compiler versions, race schedules, Unicode/grapheme clusters, or malformed inputs. A deeper follow-up should turn each P1 item above into a bounded engineering milestone with regression tests and a measured acceptance result.

**Recommended next gate:** close QF-01 and QF-05 first, since they protect user data and test the core claims the editor makes about safe saving and reliable interaction. Then resolve the formatter contract (QF-04) before expanding language tooling.
