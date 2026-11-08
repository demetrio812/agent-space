# Native Claude Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Try a native Claude conversation view on its own discardable branch.

**Architecture:** The existing bundled bridge reads an exactly bound Claude transcript on the selected computer and returns bounded message pages. Flutter renders native Chat and sends only explicit reviewed messages through the existing delivery state machine, retaining Terminal fallback.

**Tech Stack:** Flutter/FVM, flutter_markdown_plus, Python standard library bridge, existing Swift XPC validator.

**Spec:** `docs/superpowers/specs/2026-11-08-native-claude-chat-design.md`

## Global Constraints

- Branch `codex/native-claude-chat`; no automatic merge to main or the parent branch.
- Exact native Claude session UUID only; no title/cwd guessing, client paths, automatic input or agent launches.
- Pages <=60 messages/1 MiB JSON; files <=256 MiB, records <=8 MiB, parse deadline 4 seconds.
- Preserve terminal/delivery behavior and rollback compatibility; no transcript persistence or real-agent test input.

## Review Focus

- Two panes sharing a directory never share a guessed transcript.
- Session changes during a read or before Send preserve drafts and reject stale results.
- Forked/compacted JSONL and streamed assistant blocks neither duplicate answers nor show sidechains.
- Reading earlier messages remains stable while polling; background panes stop polling.
- Blocked/unknown agents, oversized text and transport failure cannot become silent success or retried input.

### Task 1: Host transcript adapter and routed protocol

**Files:** Create `scripts/bridge/conversation.py`, `scripts/test_bridge_conversation.py`; modify bridge worker/gateway/protocol/bootstrap and Swift BridgeJob/Tests.

**Interfaces:** `ConversationReader(api).read(route,payload)` returns `{session,messages,before,hasEarlier,status}`; `send(route,payload,cancelled)` checks binding and delegates reviewed dispatch. Operations `chat.read` discovery payload `{session,before}` and `chat.send` input payload `{session,text}`. Each message `{id,role,text,tools,truncated}`.

- [x] Write failing synthetic tests for exact routing/UUID matching, canonical branch, mixed blocks, incomplete lines, no symlinks, bounded pages and pre-dispatch binding change.
- [x] Implement adapter with bounded cache and explicit unavailable statuses; route operations through gateway, validate all boundaries, add package module.
- [x] Run full Python bridge tests and native Swift tests, fix failures and commit this deliverable.

### Task 2: Flutter bridge/controller integration

**Files:** Create `lib/src/conversation.dart`; modify network backend, persistent bridge and controller; create `test/conversation_test.dart` and extend bridge tests.

**Interfaces:** `ConversationBackend.readConversation(SessionInfo,{String session='',String before=''})`; `sendConversation(SessionInfo,String session,String text)`; controller fetch and guarded `sendDraft(...conversationSession:)` reuse the existing pending/uncertain marker.

- [x] Write failing page validation/stale-target/delivery tests.
- [x] Implement strict page parsing, routed backend support and session-bound reviewed Send with no retries.
- [x] Run relevant Flutter/bridge tests and commit.

### Task 3: Native Chat view

**Files:** Create `lib/src/conversation_view.dart`, `test/conversation_view_test.dart`; modify terminal pane, Demo backend, pubspec/lock and README.

- [x] Write failing widget tests proving full off-screen message Copy, older-page loading, stable polling/navigation, preserved draft on rejected Send and narrow/light/dark layouts.
- [x] Implement opt-in header toggle; native messages, Markdown/code, Copy, earlier pages, new-message indicator and composer; preserve Terminal fallback and existing draft/delivery states.
- [x] Poll only while active/foreground; reject obsolete responses. Disable slash/bang commands and unsupported states with an explanation.
- [x] Run full Flutter tests and analysis; commit.

### Task 4: Review and devices

- [x] Rebuild bridge artifacts and run full Python, Flutter and Swift suites.
- [x] Obtain one independent final review, fix actionable findings and rerun affected checks.
- [x] Copy intentional changes to private branch preserving signing configuration, build release 42 for Mac/iOS, inspect native rendering read-only and install where reachable.
- [x] Push only the public experimental branch; report exact verification, installation results and remaining experiment limits.

## Completion evidence

- Full Flutter suite: 376 passed, 38 skipped; analysis clean.
- Bridge Python suite: 82 passed. Native Swift helper: 24 passed.
- Independent review findings resolved in a consolidated fix pass; no findings deferred. Additional global Send bypass reproduced and fixed.
- Build 42 signed and installed on Mac, iPhone and iPad. Mac native Chat rendered an existing remote conversation without sending input. Both mobile devices report version 42; their lock screens blocked automatic launch. Physical mobile Chat interaction remains a user check.
- Public experiment pushed on `codex/native-claude-chat`; no merges. The private signing/build repository stays private.
