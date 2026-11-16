# Larger message and paste input

User requested verifying Herdr's actual limit, increasing AgentSpace's limit, committing/pushing and updating Mac/iPhone. Preserve Native execution and the prior opt-out from further planning questions; stay on the current feature branch, leave iPad unchanged.

## Evidence and decision

Installed Herdr is 0.9.3. Official tag v0.9.3, commit `7b116c05bfda646af39d2524c54e70c751f57ee8`, `src/api/server.rs:33` bounds an encoded request line to 1 MiB. `src/app/api/panes.rs` enqueues send_input as one encoded text/key operation. An isolated installed-binary test with a raw collector verified exact 256 KiB UTF-8 emoji input, including one bracketed-paste wrapper and no Enter, in 0.199 seconds. A request over 1 MiB was rejected without delivering bytes. Test servers never use real sockets, sessions or agents.

Raise decoded UTF-8 text to 256 KiB (16×). Python's worst allowed JSON Unicode escaping is at most three times the text bytes, so 768 KiB plus a small pane/id envelope remains below Herdr's 1 MiB request bound. Keep the bridge's 2 MiB envelope limit. Do not split/retry large pastes: one request/ack retains ordering, bracketed paste and existing delivery-uncertainty rules. Paste appends no Enter; reviewed Send appends one Enter. Do not change Herdr, terminal modes or host permissions.

Update Dart models/messages, Python gate and Swift helper allowlists together. Increase the pending keyboard queue to 256 KiB plus the existing 64 KiB headroom, retain the 128-item bound and 16 KiB normal-keystroke coalescing size. Oversize input is rejected before queueing, preserves clipboard/draft and does not mark delivery uncertain. Existing control-character and Unicode rules stay intact. Legacy restricted SSH gates with unknown old capabilities keep a clear 16 KiB preflight limit; ordinary SSH and the bundled Mac helper use the new limit.

Test exact-byte UTF-8 boundaries, single-paste ordering with subsequent keys, max-size reviewed Send, Python/Swift bounds, legacy definite rejection and ordinary SSH/peer input forwarding. Run full Flutter/Python/Swift suites and one independent review. Build 52, verify native Mac maximum-paste capture using a disposable collector, install Mac/iPhone and verify installed versions separately from launch.
