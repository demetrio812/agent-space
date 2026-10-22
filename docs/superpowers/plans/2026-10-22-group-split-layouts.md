# Group split layouts implementation

Approved design: ../specs/2026-10-22-group-split-layouts-design.md. Native implementation and independent final review; no further approval rounds requested. All commits stay on codex/group-split-layouts.

1. Add backward-compatible per-group preset, assignments, active panel and ratios; test round trips and invalid/legacy data.
2. Add group controller operations and explicit visible-panel stream/viewport ownership, retaining selected-only input; test assignments, cleanup and independent streams.
3. Build the responsive board, layout selector, shared session strip, panel picker, accessible dividers and maximise/restore. Reuse terminal UI with active-panel autofocus and no duplicated tabs.
4. Test focus/input, resizing, persistence and fallbacks. Run Flutter analysis, regressions and native Mac checks, then independent review and repairs.
5. Build and verify releases using FVM, push only the feature branch, and update Mac, iPhone and iPad. Keep private history separate.

Inspection note: main.dart does not currently wire openWindow or construct secondary app windows. Do not introduce a detached-window feature. Exclude externally watched sessions from board geometry ownership if that existing integration is invoked, avoiding competing resize sources.
