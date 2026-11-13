# Session Project Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Add the approved Files/Specs panel to each session and update all three device builds.

**Architecture:** A bounded, pane-routed host reader returns a manifest and scoped UTF-8 documents. A native Flutter workspace owns panel state, permanent list tabs and opened viewers beside the existing Terminal/Chat widget. Persist preferences only; use the existing delivery boundaries unchanged.

**Tech Stack:** Flutter/FVM, existing Markdown renderer, webview_flutter, Python standard-library bridge, Swift envelope validation.

**Spec:** `docs/superpowers/specs/2026-11-13-session-project-panel-design.md`

## Global Constraints

- Branch `codex/session-project-panel`, based on merged Chat `885864a`; push feature branch only.
- Read-only exact-pane routing; no client paths, shell execution, task mutations or test input to real agents.
- 128 documents, 64 features, 2048 folder entries, depth three, four-second discovery, 256 KiB UTF-8 file, 1 MiB reply.
- Eight opened documents, 2 MiB content per panel; persist preferences, never document contents.
- HTML JavaScript/navigation/network disabled; Markdown images do not load automatically.
- Visible polling five seconds, first-discovery polling ten seconds, no polling after explicit close or in background.

## Review Focus

- Same pane IDs on different computers must never share document reads.
- Cwd changes, root replacement, symlinks and stale manifests reject old reads.
- Polling/navigation cannot steal terminal focus or accept obsolete results.
- Hostile HTML cannot execute scripts, navigate or fetch resources.
- Many documents, long names and narrow/short windows retain accessible pinned list tabs and close actions.

### Task 1: Host reader and protocol

**Files:** Create `scripts/bridge/project_files.py`, `scripts/test_project_files.py`; modify worker/gateway/protocol/bootstrap, Swift BridgeJob and tests, gateway tests, bridge artifacts.

**Interfaces:** `ProjectFiles(api).listing(route)` returns `{scope,folder,files,limited}`; each file `{id,name,path,kind,section,feature,revision}`. `read(route,{scope,file})` returns `{scope,file,revision,text}`. `files.list` payload `{}`; `files.read` payload `{scope:64hex,file:64hex}`. Strict payload validation is shared at each boundary.

- [x] Write and run failing synthetic tests for discovery separation, peer identity, scoped reads, symlinks/traversal, changed cwd/root, size and UTF-8 limits.
- [x] Implement bounded reader, exact routing, validators and package module; regenerate artifacts.
- [x] Run full bridge Python and native Swift suites; commit.

### Task 2: Flutter model, backend and persisted panel state

**Files:** Create `lib/src/project_files.dart`, `test/project_files_test.dart`; modify network backend, persistent bridge, controller, storage and Demo backend.

**Interfaces:** `ProjectFilesBackend.listProjectFiles(SessionInfo)` → `ProjectManifest`; `readProjectFile(SessionInfo,String scope,String file)` → `ProjectDocument`. Controller equivalents validate current pane/connection before and after. `ProjectPanelLayout` serializes visible/width/scope/opened/active only; `WorkspaceLayout.projectPanels` holds up to 128 scoped session preferences.

- [x] Write and run failing strict-page, stale-target and preference-roundtrip tests.
- [x] Implement models, routed read-only backend/controller and Demo Markdown/HTML/Kiro fixtures.
- [x] Run affected controller/bridge/storage checks; commit.

### Task 3: Panel, viewers and session integration

**Files:** Create `lib/src/project_workspace.dart`, `lib/src/project_file_viewer.dart`, `test/project_workspace_test.dart`; modify terminal pane, pubspec/lock, README.

**Interfaces:** `ProjectWorkspace(app,session,active,builder)` wraps existing content; builder receives toggle, visible and covered booleans. Persistent Files/Specs list tabs and up to eight scoped document tabs; HTML viewer accepts a `ProjectDocument`, with CSP preparation exposed as a pure function for tests.

- [x] Write and run failing widget tests for separate lists, deduplicated tabs, close/reopen, saved visibility, polling, stale response rejection, focus and narrow/light/dark layouts; test restrictive HTML preparation.
- [x] Implement panel layout/resizing, background-aware refresh and viewers; integrate Files icon without adding a header row.
- [x] Run full Flutter suite and analysis; commit.

### Task 4: Review, build and devices

- [x] Obtain one independent whole-branch review; resolve important findings in one tested fix pass.
- [x] Run final Python/Swift/Flutter checks and regenerate artifacts if changed.
- [ ] Sync intentional files to private feature branch preserving signing; build release 43, inspect Demo/disposable UI, install/launch on reachable devices and verify versions.
- [ ] Commit matching private sources, push public feature branch and report exact outcomes/limits.

## Release verification

Final checks: Flutter 393 passed, 38 skipped; analysis clean; Python 144 tests, one skipped; Swift 25 passed. Independent review findings resolved in one tested pass. Release 43 builds and Mac signature verification succeeded. Mac installed and launched; iPhone installed, launched and queried as build 43. The native panel walkthrough remains pending because desktop interaction repeatedly timed out and active user navigation prevented a controlled Demo check. iPad remains unavailable to Xcode; installation is pending a connection. No input was sent to real agents.
