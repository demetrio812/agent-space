# Local Herdr integration

AgentSpace embeds an on-demand XPC service for local Herdr operations. The Flutter UI keeps App Sandbox enabled. The service runs with the current user’s ordinary permissions outside App Sandbox; it needs no administrator rights or system daemon installation. Apple documents this directly distributed-app architecture: https://developer.apple.com/forums/thread/776609. It is not a fully sandboxed Mac App Store architecture.

The installed Herdr CLI handles its observer protocol. AgentSpace validates bounded catalogs and ANSI frames, queries native geometry for previews and uses a bounded viewport controller for the selected terminal when zoom or available space changes. The helper forwards only typed resize records on that controller; keyboard/composer input retains its separate delivery safeguards. Settings support custom executable and socket paths; initial discovery checks ~/.local/bin/herdr, /opt/homebrew/bin/herdr and /usr/local/bin/herdr. Herdr must already be running. Arbitrary future Herdr versions are not guaranteed compatible; unsupported responses produce connection errors.

The app-private interface exposes only discovery, socket identity, allowlisted CLI operations, output reads and cancellation. No general shell, PTY, forwarding, server-start or arbitrary file-read endpoint exists. Input is bounded literal text plus one Enter, with membership/generation preflight, persistent uncertain-delivery warnings and no automatic replay. Pending requests are checked for cancellation before actual process launch. Closing a connection terminates only helper-owned CLI clients.

Both ends enforce the exact embedded peer binary’s signing identifier and code hash on XPC messages. macOS 13+ is required for this runtime authentication API. Ad-hoc development signatures are supported and tested; Developer ID builds require production signing and notarization. The helper is signed separately so UI sandbox entitlements never propagate to it.

Remote phones/tablets use SSH with pinned host identity and the persistent bridge or optional restricted gate. Windows/Linux and optional independent windows remain later scope.
