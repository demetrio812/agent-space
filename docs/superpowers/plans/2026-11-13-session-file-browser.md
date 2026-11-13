# Session file browser implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans task-by-task. Preserve the selected Native workflow.

**Goal:** Documents/Specs/Files with unrestricted account-permitted browsing and selected-folder uploads; release on Mac/iPhone.
**Architecture:** Pane-routed filesystem reader and atomic chunk uploader through existing discovery/transfer workers. A separate Flutter browser widget fits the current stable session panel.
**Tech Stack:** Flutter/FVM, file_selector, desktop_drop, Python descriptors/hashlib, Swift typed validation.
**Spec:** docs/superpowers/specs/2026-11-13-session-file-browser-design.md

## Global Constraints

- Existing codex/session-project-panel branch; no main merge; iPad later.
- 32 MiB/file; four uploads/64 MiB pending; 256 KiB chunks; five-minute TTL; 20 selected files sequentially.
- 4096 scanned/1000 returned entries, 512 KiB list, 4096-byte absolute path, 255-byte upload name, 256 KiB UTF-8 preview.
- No overwrite, deletion, execution, recursive upload, terminal input or persisted content; exact pane and computer routing.

## Review Focus

- Folder/route replacement while an upload or read is pending must not redirect it.
- Lost finish acknowledgement must not silently retry or attach anything to prompts.
- Directory entries must be regular/folder/link metadata without blocking on devices or pipes.
- Browser changes/background/close must reject late results and cancel partial uploads.
- Narrow panels retain all three pinned tabs, focus and session/Chat state.

### Task 1: Host filesystem and typed routing

**Files:** Create scripts/bridge/file_browser.py, scripts/bridge/peer_file_transfers.py, scripts/test_file_browser.py; update worker/gateway/protocol/bootstrap, Swift BridgeJob/tests, package artifacts and gateway tests.
**Interfaces:** FileBrowser(api).operation(op,route,payload) returns list page {path,home,scope,entries,limited}, read {file,document} or upload token/offset/completion; close cleans partials. PeerFileTransfers(gateway) pins transfer leases and maps opaque tokens.

- [x] Write failing synthetic browse/read/upload/routing tests and observe failures.
- [x] Implement bounded directory reader, descriptor-held upload lifecycle and exact routing/validators.
- [x] Run host/Swift suites, regenerate artifacts and commit.

### Task 2: Flutter client and panel

**Files:** Create lib/src/file_browser.dart, lib/src/session_file_browser.dart and tests; update controller/network/Demo/persistent_bridge, ProjectWorkspace/preferences, README.
**Interfaces:** FileBrowserBackend.fileBrowserRequest(SessionInfo,String,Map) returns typed-validated map. BrowserPage/BrowserEntry strict models; BrowserUpload executes acknowledged sequential chunks with cancellation/progress. SessionFileBrowser(app,session,active) owns memory-only browser state.

- [x] Write failing model/controller/widget tests for strict payloads, rename, navigation, focus, bounds, stale results and upload cancellation.
- [x] Implement client, Demo, browser picker/drop/progress/preview; Documents naming and scrollable tabs.
- [x] Run Flutter full suite/analyzer and commit.

### Task 3: Review and release

- [x] One independent final review; resolve important findings with red/green regressions in one pass.
- [x] Run final host/Swift/Flutter verification, mirror intentional sources preserving private signing, build/sign release 44.
- [ ] Install/launch Mac and iPhone, verify versions; native checks only Demo/disposable input.
- [x] Commit private mirror, push public feature branch and report exact outcomes and limits.

## Release 44 verification

Final Flutter suite: 412 passed, 38 skipped; analysis clean. Python:155 tests, one skipped. Swift:26 passed. The independent final review’s nine finding categories were fixed in one regression-tested pass. Mac and iOS release44 builds succeeded, and the installed Mac app signature and bundled bridge digests match the reviewed source. Mac installation succeeded; launch and the native walkthrough are blocked by the Mac lock screen. Xcode still reports the iPhone unavailable, so its build is prepared but not installed. User was asked to unlock/reconnect; iPad is explicitly deferred. Code is committed and pushed on codex/session-project-panel; main remains885864a.
