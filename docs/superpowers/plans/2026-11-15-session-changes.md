# Session Changes Implementation Plan

> Execute natively in this chat; preserve the user's opt-out from further planning questions. One independent final review.

**Goal:** Read-only staged/unstaged/untracked Git changes and diffs in the session side panel.
**Architecture:** Host-local bounded Git reader, two typed discovery operations, optional Dart backend interface and independently scoped panel widget.
**Tech Stack:** Existing Python bridge, Dart/Flutter, Swift helper validation; no new dependencies.
**Spec:** `docs/superpowers/specs/2026-11-15-session-changes-design.md`

## Global constraints
Exact pane/computer routing; no shell/network/input/Git mutations; list 500 entries, subprocess output 512 KiB, preview 256 KiB, commands four seconds; show all failures/limits explicitly. Build 48 for Mac/iPhone, defer iPad. Keep current feature branch.

## Review focus
Git configuration must not execute textconv/external diff/fsmonitor. Literal hostile filenames must not become pathspecs. Late reads must not replace another session's diff. Symlinks/untracked oversized data must not escape bounds. Existing panel polling/focus must remain independent.

### Task 1: Typed host Git reads
- [x] Write/run failing real-repository tests in `scripts/test_git_changes.py`: staged+unstaged, untracked, rename/delete, unborn/detached/worktree, literal names, binary/size/symlink, stale cwd/content and exact payloads.
- [x] Implement `GitChanges.listing(route)` and `.read(route,payload)` in `scripts/bridge/git_changes.py`; wire worker/gateway/protocol/package and Swift envelope validation.
- [x] Run Python/Swift tests, including cross-peer dispatch and malformed operation/lane tests.

### Task 2: Models, transport and panel
- [x] Write/run failing tests for validated response models and Changes panel list→diff→back, refresh/stale/background and no-input behaviour.
- [x] Add `GitChangesBackend`, models and payload validation; implement Network/Demo and controller current-target checks.
- [x] Add `SessionChanges` widget to ProjectWorkspace, persist Changes tab selection; selectable coloured unified diff, filter/status groups/empty/error states and active-only polling.
- [x] Run full Flutter tests and analyzer; update protocol/README.

### Task 3: Review and release
- [x] Independent review of this feature's diff; one consolidated correction pass with regression tests where needed.
- [x] Build bridge, mirror source preserving private signing, build/sign Mac and iOS release48.
- [x] Commit/push public feature branch, commit private mirror only; install/relaunch Mac and install/launch correct iPhone when reachable. Verify native Changes using disposable/demo data, restore normal user view. Report any unavailable device accurately.

## Verification ledger

Base: dd515c2. Real-Git RED observed before implementation; initial 10 Python, 4 widget/model tests passed. Cross-peer tests and Swift envelope tests passed. Integration tests exposed deferred async loading and newly offscreen tabs; fixed test synchronization/scroll navigation. Full first run: Python172 passed/1skip, Swift27 passed; Flutter433 passed/38skip with two integration failures, now resolved in focused23-test run. Independent reviewer found false binary detection and staged previews gated on working-file size; both reproduced RED and fixed GREEN in12 real-Git tests. Removed unrelated automated vendor lint changes. Final suites/build/native evidence follows.

Final verification: Flutter435 passed/38 skipped; Python174 passed/1 skipped; Swift27 passed; analyzer clean and diff whitespace check clean. Bridge SHA-256 `105773981498dba55897745a3a9f4d4e05a292533644fb306d89bc84d72df1ff`. Mac and signed iPhone release48 built; Mac installed, signature verified and launched. Native Mac test proved separate staged/unstaged/untracked lists, selectable original→staged and staged→working diffs, automatic refresh after a synthetic file edit, and new-file diff. Restored the original view and removed only the disposable test workspace. iPhone installation and device-reported bundleVersion48 verified; launch blocked by device lock screen. iPad deferred. Public feature branch only; private history stays local.

## Folder-tree refinement verification

The user requested folders after release48. Changes now groups each Git section into compact folder trees, folders first with counts and full-path tooltips. Collapse state is independent for filtered/unfiltered views. Added native-width regression tests for collapse, refresh, filter expansion and diff navigation. An independent review found collapsed ancestors could reopen when compact paths changed after refresh; reproduced RED and fixed GREEN with a targeted regression. Final Flutter437 passed/38 skipped; analyzer clean. Mac/iPhone release49 built, signed and installed; native Mac verified nested src/api and src/widgets groups, counts, collapse, filter reveal and clear restoring collapse. Restored the original session and removed the disposable workspace. Bridge/Python/Swift behavior unchanged from verified release48.
Both installed build49 apps launched successfully; iPad remains deferred.
