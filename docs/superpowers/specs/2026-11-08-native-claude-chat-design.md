# Native Claude Chat experiment

The user approved trying a native conversation interface on a new branch, retaining Terminal as fallback. Work stays on `codex/native-claude-chat`, based on `daa1cb6`; never merge either experimental branch into main automatically. Native execution and the earlier instruction to skip further planning questions remain in effect.

## Experience

A Chat/Terminal control in the existing two-line session header opts Claude panes into Chat. Terminal remains the initial view and one tap away. Chat renders the selected Claude conversation as native Flutter messages with selectable Markdown, code blocks and per-message Copy. Load earlier pages without losing the reading position; new messages do not pull a person away from older content. A composer reuses the session draft and delivery safeguards, with explicit Send text + Enter and no automatic retries. Permissions, menus, images and unsupported agents use Terminal in this first experiment. No agent is started or resumed merely by opening Chat.

## Binding and transport

Use Herdr's exact `agent_session` reference for the selected terminal/pane, requiring agent Claude, kind id, and a session UUID. Never infer from title, cwd, most recent file or another pane. The bundled helper reads that exact transcript on the hosting computer, using the existing native/SSH gateway routing and generation checks. Accept no client-provided filesystem paths. Read only normal account-owned files beneath the configured Claude projects directory; reject project/file symlinks, ambiguous matches and missing references. Revalidate the same reference after reading and immediately before dispatching a reviewed message. An unavailable or changed binding disables Send and explains how to open Terminal. Keep the original UUID pinned across unavailable pages and background/resume until an explicit Reload; never bind a retained draft automatically to a successor conversation.

Claude transcript JSONL is an internal versioned format. This experiment uses a bounded standard-library adapter, tested against synthetic fixtures and the field structure of the installed version. Fail closed on unsupported structure and retain Terminal. Follow the active parent chain, join assistant blocks, omit sidechains/internal/tool-result payloads, and expose tool names in compact summaries. Read forked history already present in the exact file. Ignore an unfinished trailing JSONL record while an agent writes it. No transcript contents are stored in app preferences, fixtures or logs.

Pages contain at most 60 messages and 1 MiB of encoded JSON. Reads cap files at 256 MiB and records at 8 MiB, with a 4-second parser deadline and bounded cache. Oversized messages are explicitly marked truncated, never silently presented as complete. Chat polls only while visible/active, pauses in the background and rejects stale results after navigation or connection changes. Exact expected session UUID accompanies pagination and send.

## Delivery

Opening Chat never sends terminal input or takes control. Existing Herdr processes and authentication remain in use. Native Send requires a verified unchanged Claude binding and idle/done agent status; blocked/working/unknown states direct the user to Terminal. Send uses the existing reviewed-input path, serialized with all other terminal input, persists the existing delivery-uncertain marker, and is never retried. This is an experimental convenience, not an atomic agent-level protocol: Herdr can change prompt state between the check and input admission; the UI labels Send text + Enter and keeps Terminal accessible. App-wide unbound draft delivery is blocked while Chat owns the composer; keyboard Send routes through its pinned UUID, and the built-in dictation shortcut is unavailable in Chat. Leading slash/bang commands are handled in Terminal, not guessed at by Chat. The composer retains its draft on rejection or uncertain delivery.

## Rendering

Use the maintained BSD Flutter Markdown renderer. Markdown images never fetch remote URLs or local files automatically; show attachment labels. Open only explicit user-tapped http/https links without embedded credentials. Keep content width readable on desktop and full-width on mobile, with minimum 44-point actions and light/dark themes. Full-response Copy copies source text, independent of viewport height.

## Verification and rollback

Synthetic tests cover identity collisions, forks/compaction/streamed blocks, incomplete records, malicious paths, bounded pages, stale polls/sends, offline/blocked states, copy of off-screen text, scrolling and phone layouts. Test the complete Flutter, bridge Python and native Swift suites; one independent final review. Manual native checks use Demo/disposable sessions; live sessions are read-only. Commit/push the new branch, build release 42 and update the existing Mac/iPhone/iPad apps where reachable. Rollback is rebuilding the previous branch at `daa1cb6`; device preferences and Herdr sessions remain compatible.
