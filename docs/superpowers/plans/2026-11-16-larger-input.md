# Larger input implementation

Spec: `docs/superpowers/specs/2026-11-16-larger-input-design.md`. Native execution; no additional planning questions.

- [x] Inspect exact upstream/installed Herdr; prove 256 KiB raw delivery and over-1-MiB rejection with isolated server/collector (`scripts/test_herdr_large_input.py`).
- [x] RED: add Dart model/queue/composer, Python worker and Swift payload boundary tests.
- [x] GREEN: raise all decoded-text validators to 256 KiB, queue 320 KiB, preserve typing merge 16 KiB; old restricted SSH preflight 16 KiB.
- [x] Update obsolete size tests and documentation; regenerate bridge package; test large ordinary SSH and selected-peer routing without extra Enter/replay.
- [x] Run full suites, one independent review, resolve actionable findings once with regressions.
- [ ] Mirror source preserving signing; build/sign52, native disposable input check, commit/public push and local private mirror; install Mac/iPhone and report actual launch state. Defer iPad.

Review focus: byte/character confusion; pending queue hidden 64-KiB cap; serialized JSON bound; legacy gate command length; input uncertainty/retry; paste vs Send Enter semantics.

## Verification

- Flutter: 446 passed, 41 optional checks skipped; analyzer clean.
- Disposable password/restricted SSH: 19 passed, including maximum paste/Send and legacy rejection before any remote request.
- Selected-peer gateway maximum paste/Send: passed; neither gateway nor other peer received input.
- Python: 178 tests, 4 optional checks skipped; all passed.
- Installed Herdr 0.9.3 isolated tests: 3 passed, including direct socket, AgentSpace worker and over-1-MiB rejection.
- Swift helper: 28 passed. Independent review: no actionable findings.
- Native signed Mac build 52: a 262144-byte UTF-8 clipboard paste arrived as exactly 262156 bytes including one bracketed-paste wrapper, no Enter. A paste one byte over the limit delivered nothing; the next Left key arrived once. Normal connection and previous session restored; disposable server stopped.
- Both release builds completed; Mac 52 installed, signature verified and launched. iPhone installation pending device connectivity.
