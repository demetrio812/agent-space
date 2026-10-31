# Persistent Herdr bridge

AgentSpace connects to one gateway, then reads the enabled computers saved in that gateway's Herdr. Discovery is one hop: peers are destinations, never additional gateways. OpenSSH on the gateway uses its existing aliases, account keys and known hosts. Peer authentication is noninteractive and host-key checking is strict. AgentSpace does not change SSH configuration, copy peer credentials to the client, scan the LAN, or start/stop/upgrade Herdr.

## Requirements and cache

Servers need macOS or Linux, a working Python 3.9-or-newer interpreter, OpenSSH and a running Herdr with the public JSON API and terminal `observe`/`control` commands. Before ordinary SSH bootstrap, a fixed shared shell launcher probes Python with stdin redirected away from protocol input. It tries PATH, `~/.local/bin/python3`, `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, `/opt/local/bin/python3` and `/usr/bin/python3`, using the first interpreter that runs and supports Python 3.9 plus the required standard library. It then execs the bootstrap exactly once; bootstrap or delivery failure never tries another interpreter. Restricted gates retain their fixed command and do not run this discovery. A bounded help probe checks the Herdr terminal commands once per worker. Windows server transport is deferred. Missing prerequisites, host verification and authentication failures appear on the affected computer; healthy computers remain usable.

Ordinary SSH installs a fixed standard-library ZIP under `~/.cache/agentspace/bridges/<SHA-256>/bridge.pyz`. The directories are account-owned and private. Installation rejects symlinks and unsafe ancestor ownership/modes, bounds the package to 512 KiB, verifies its digest and fixed uncompressed module allowlist, and publishes atomically. Cache hits are verified before execution through an inherited open descriptor. Updates create a new digest directory; old versions are retained. Workers stop when their connection closes; the cache remains.

The directly distributed Mac app uses the same signed bundled ZIP through its authenticated XPC helper. The main app stays sandboxed; the helper uses ordinary account permissions. Native callers cannot select Python, source or a package path. Custom Herdr executable/socket locations remain supported.

## Negotiation and framing

The existing `agentspace-catalog-v1` probe remains first. Only an exact command-not-found result permits ordinary-shell bootstrap. A restricted gate rejection is terminal: no upload, fallback shell or input retry follows it. Legacy v1 gates keep their advertised local capabilities. Network v2 is used only when explicitly advertised by a restricted gate. The supplied pairing gate is v1; it does not implicitly gain network access.

A fixed bootstrap exchanges a digest/cache-needed record and, only on a cache miss, the base64 ZIP. A verified hello identifies `agentspace-bridge-v2`, the exact package digest, lane, random 32-hex nonce, generation and capabilities. Configuration travels as encoded data, never interpolated commands.

Each lane uses bounded newline-delimited JSON: at most 2 MiB per record, duplicate fields rejected, exact typed operations, monotonic decimal request IDs and matching nonce/lane/id acknowledgements. Discovery, input, terminal streams and lazy image transfers have separate workers and SSH channels. Their errors and deadlines are independent.

Operations are catalog, machines, health, literal input, reviewed text plus Enter, observe, resize, scroll, click, cancel and the fixed rename/close/create session actions. There is no shell operation. Existing key validation, including Command-modified Backspace/arrows and Ctrl+Enter, is shared with the legacy gate. Preview uses observation; selected terminal resizing uses control without takeover. If Herdr reports an existing attached client, the app offers an explicit, confirmed Take control action. Only that one viewport request carries takeover:true; the worker validates the boolean, requires viewport/input permission and adds the fixed --takeover flag. Reconnects, retries, previews and resizes never inherit takeover. The native Mac envelope validator accepts the same optional boolean for gateway and peer routes; numeric/string flags, extra fields and preview takeover are rejected before worker dispatch.

## Routing and delivery

A peer route binds gateway profile, saved machine ID, selected named Herdr session, target hash, destination generation, terminal and pane. Saved labels are display-only. Before input forwarding, the gateway freshly checks the public saved-machine list; after worker acquisition it checks again. The destination checks socket generation and current terminal/pane membership immediately before dispatch. Literal input uses the UNIX JSON API, with one socket per API request and no Herdr CLI process per key. Public route checks still cost a CLI invocation; this is included in the peer latency measurement.

Gateway session identities retain the previous native/SSH generation formats and saved keys. Peer keys also include the machine/session/target hash. Computer and workspace filters use bounded SHA-256 scope IDs. A changed target or server does not silently rebind an old favourite or draft.

Only a positive, correctly correlated `sent: true` reply confirms delivery. Once submitted, a lost, malformed, mismatched or timed-out acknowledgement becomes **delivery uncertain**. The app persists this state before submission, blocks subsequent input, and never replays it. The owner checks the terminal and chooses **I've checked** to resume. A definite pre-dispatch rejection does not claim delivery.

## Bounds and lifecycle

The bridge bounds saved computers to 64, concurrent peer starts to four, peer workers per lane to 16 and combined local/peer live streams to 16. Active requests and streams are protected from idle LRU retirement. An acquisition lease protects workers during route checks. Stream queues and error output are bounded; cancelling a pending observation prevents launch or cancels its eventual subscription. EOF/background/source changes close owned workers, observer process groups and SSH channels, without stopping Herdr or unrelated agents.

## Reproducing verification

Set `AGENTSPACE_TEST_PYTHON` to a disposable Python environment with `test/requirements.txt`, then run `scripts/flutterw test` and the Python test suite. `test/fixtures/network_ssh_fixture.py` creates a synthetic gateway and two peers, generated account keys and known-host entries under a disposable HOME. A fixture-only SSH wrapper selects that generated config; production uses ordinary OpenSSH. Its control endpoint can replace sockets, change routes, deny authentication, corrupt fixture host trust, stall/flood output and drop an acknowledgement. Teardown closes transports, waits for owned children and removes only this fixture's directory.

`scripts/benchmark-bridge --mode baseline|persistent --samples 100 --output <file>` compares against an exported copy of commit `6def612`. It never resets the active checkout. The previous build had no peer aggregation: its gateway catalog completion is compared to the new gateway-first availability, and new full-network completion is reported separately. These loopback measurements exclude real VPN latency and rendering.

`scripts/read-only-network --gateway <existing-ssh-target> --seconds 5 --output <file>` is an opt-in live discovery/preview check using existing OpenSSH access. It installs the approved versioned cache but submits no terminal input and reports counts/geometry without terminal contents.

## Session actions

Management requires explicit `allowManagement:true` and `allowInput:true`. Native and ordinary SSH launches set this permission; restricted and legacy gates do not inherit it. Each destination advertises `sessionManagementEnabled` only after bounded `pane rename --help`, `pane close --help` and `tab create --help` probes. Gateways clamp peer capability to their own permission. Workspace IDs/labels come from that computer’s catalog; the catalog has no general folder default.

The input lane accepts exactly `rename` with `{title}`, `close` with `{}`, and `create` with `{workspace,title,cwd}`. The worker constructs `pane.rename`, `pane.close` or `tab.create` arguments itself; callers cannot supply an RPC method, environment or startup command. Names are limited to 128 UTF-8 bytes and folders to 4096, without control characters. Explicit folders must be absolute or start `~/`; account-relative expansion happens only at the destination. Creation always passes `focus:false` and uses the returned root pane/tab identity, verified against a fresh catalog. Ordinary shell terminals with null agent metadata remain selectable.

Rename and close use the complete captured machine/session/target/generation/terminal/pane route. Create uses exactly machine/session/target/generation plus the selected existing workspace in its payload. The gateway revalidates the saved computer before and after worker acquisition. Peer workers are bound to their machine/session/target at launch; destination generation and pane/workspace membership are freshly checked before a single API submission. Success requires a correlated acknowledgement and `applied:true`; any failure or malformed data after possible submission is uncertain, with no replay.

The app journals a bounded per-computer action record before calling the backend, then removes it on definite rejection or confirmed completion. An interrupted app can therefore require an unnecessary inspection when submission had not started. Uncertain records survive relaunch and block management only for that computer, independently of keyboard delivery markers. A user must inspect refreshed sessions and explicitly acknowledge the action before another management operation. Confirmed rename retains terminal identity and favourite order; confirmed close retires only the closed view. Discovery cancellation completes before shutdown closes the bridge.

## Attached terminal scrolling

The streams lane accepts `scroll` only for a live viewport-control subscription, with exactly `subscription`, `direction` (`up`/`down`) and integer `steps` (1–40). For each step the owning worker writes one fixed `terminal.scroll` command with `lines: 3` and `source: wheel` (Herdr’s mouse-report mode consumes one wheel tick per command regardless of its line count) to that subscription’s control stdin. Preview streams and input-disabled workers reject it. Gateways translate the same subscription handle used for resize/cancel, preserving the peer attachment. No `pane.scroll` API call, terminal text, raw escape bytes or synthetic arrow-key fallback is used.

The UI forwards vertical wheel, trackpad pan and touch motion without requiring keyboard focus. It coalesces pending movement, allows one request at a time, and discards queued movement when the selected terminal changes or control becomes unavailable. Cancelled/replaced views reject immediately before submission. Scrolling follows Herdr’s attached-terminal behaviour; history availability and alternate-screen application handling are controlled by Herdr and the pane application.


## Attached clicks and Finder image transfers

The streams lane accepts `click` with exactly `subscription`, zero-based `column` and `row`, bounded by that owned live viewport. The worker emits a left-button down/up pair to its control stdin. Clicks use the same durable, no-replay input gate as keys; a lost acknowledgement requires terminal inspection. Short unmodified primary taps forward; selection drags and modifier clicks stay local. Brief frame bursts may drain for up to 250 ms before sustained backpressure retires that subscription.

`transfer` accepts only health and image.begin/chunk/finish/cancel. Every image request has the exact full terminal route. Input permission plus separately opted-in `allowImages` are required; the catalog advertises `imageTransferEnabled`. Ordinary SSH and the native broker opt in; restricted/legacy transports stay unavailable.

- begin `{extension,size,sha256}` → `{token,offset:0}`. Supported extensions png/jpg/jpeg/gif/webp/bmp; 1–16 MiB.
- chunk `{token,offset,bytes}` → `{offset}`. Canonical base64, at most 256 KiB decoded; exact sequential offset.
- finish `{token}` → `{path,size,sha256}`. Checks size, SHA-256, signature, live generation/membership, then atomically publishes an exclusive generated path.
- cancel `{token}` → `{cancelled:true}`. Idempotent for absent tokens; existing tokens remain bound to their original route.

The private destination cache is `~/.cache/agentspace/attachments` (0700 directory, 0600 files). No client path is accepted. Random `ag-image-<32hex>.part` files become randomly named completed images through atomic no-replace publication. Directory traversal uses no-follow descriptors, and publication verifies inode identity. At most four active uploads/64 MiB are reserved per worker, shared by local and routed uploads. Tokens expire after five idle minutes. Feature-owned regular completed files expire after 24 hours; reaping runs on operations and every 30 seconds. Worker shutdown cancels pending files; abrupt process/machine termination may leave partial files until a later worker reaps them.

Gateway public tokens bind the peer token, route and worker. A pool lease lasts for the token lifetime, preventing eviction between chunks. Registry validation brackets peer acquisition and responses. Cancellation can reach the original worker after a retarget, and runs concurrently with a held chunk. Background shutdown gives pending cancellation requests a bounded chance to finish before closing the bridge.

The UI validates the entire batch (four images maximum), holds Finder security-scoped access only while reading, then uploads in order. A completed absolute path is inserted through the persisted input queue using Herdr’s bracketed-paste handling, with no Enter. Source/selection/background changes cancel the captured operation. Invalid receipts or changed destinations never become input. Final-input uncertainty preserves the inspection gate across restart and never replays; completed files remain inspectable until expiry.

On iPhone and iPad, the terminal attachment button opens the system Photos or Files picker. Photos requests selected images without full-library metadata access; Files filters to the supported image types. Reads enforce the same 16 MiB limit before and during streaming. The selected terminal, connection generation, pane and route are captured before opening the picker and checked again before starting the shared transfer pipeline. Picker cancellation produces no upload or terminal input. Progress, cancellation and retry overlay the terminal without resizing it.

### Image paste correction — 16 October 2026

An `input` payload containing exactly `paste` with a bounded single-line string sends Herdr `pane.send_input` with that text and an empty `keys` list. Herdr applies its negotiated bracketed-paste mode; no Enter is appended. Image insertion uses the validated destination path without shell quoting or a trailing separator, matching Herdr clipboard-image paste behavior. Ordinary typing still uses `pane.send_text`. Paste entries never coalesce with adjacent typing; they retain the same per-input receipts and durable uncertainty gate. Restricted and nonpersistent transports reject this paste form before dispatch. On macOS, unmodified Command+Backspace is translated to Ctrl+U at the terminal keyboard boundary because Herdr 0.9.3 legacy non-character encoding otherwise drops Command and emits DEL. Option+Backspace and plain Backspace retain their distinct key forms.
