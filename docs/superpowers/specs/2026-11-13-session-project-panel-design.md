# Session project panel

The user approved the interactive mockup, including a separate permanent Specs tab, and requested implementation on a new branch after merging native Chat into main. Preserve the Native workflow and skip further planning approval rounds.

## Experience

Each session can show a closable right panel on wide windows, or a full-size overlay with Back to session on narrow windows. A Files button in the existing session header opens or closes it. Files and Specs are permanent tabs; individual documents open in closable, deduplicated tabs. Closing a document returns to its originating list. Keep per-document scroll position. The desktop divider can resize the panel.

Files lists Markdown and HTML documents. Specs exclusively lists Kiro feature folders, with requirements.md, design.md, tasks.md and bugfix.md documents grouped beneath them. Recognise `.kiro/specs/` and standalone `.specs/`. Show task checkbox progress without changing files or running tasks. The first version is read-only, including task checkboxes.

Show the panel on the first discovery of supported content, then remember an explicit close per session and connection. Store visibility, width, scope, open IDs and selected tab; never store file contents. Poll visible panels every five seconds, pause while backgrounded/inactive, and retain the last readable version with a clear stale warning on refresh failure. Until first discovery, probe every ten seconds; explicit closure stops probes. Reopening refreshes. Changing the current folder replaces the scoped document list and discards obsolete in-memory content.

## Host discovery and routing

Use the selected pane's `foreground_cwd` or `cwd` from Herdr, never the helper process's folder or a client path. Find the nearest ancestor with a `.git` marker as project root. Discover direct Markdown/HTML files in the current folder and project root, plus a `docs/` subtree to depth three and Kiro spec documents one feature directory below the two recognised spec roots. These bounded discovery locations are builder choices; arbitrary filesystem browsing is out of scope.

Read through the existing bundled helper on the pane's actual computer, including gateway peers. Add discovery-only `files.list` with empty payload and `files.read` with opaque scope and file hashes. Both require the exact pane route and generation, with checks before and after reads. No client-supplied paths, shell execution, input or writes. Each read rediscovers its allowed files; a changed cwd/project scope rejects an old request.

Use descriptor-relative directory traversal and no-follow opens. Skip symlinked documents/directories, nonregular files and non-account-owned resources. Bounds: 128 documents, 64 feature folders, 2048 entries per scanned folder, depth three, four-second discovery budget, 256 KiB per UTF-8 document, 1 MiB encoded reply. Oversized or invalid-UTF-8 documents show an explicit error, never an apparently complete truncation. A limited catalog is labelled. Scope hashes include the current folder and opened root identities; file hashes identify only allowed scoped relative entries. Revalidate scope and file identity after reading.

## Rendering

Reuse native Flutter Markdown rendering and selection. No automatic local or remote Markdown image loads; relative document links may open an already-discovered document, and explicit HTTP(S) links may open externally. File text is content, never instructions to the app.

Render HTML using the system WebView through Flutter's maintained webview_flutter package on Mac/iOS/Android. Disable JavaScript, block navigation, and prepend a restrictive Content Security Policy before any untrusted markup: no network, scripts, forms, frames or base URLs; allow inline styles and embedded data images/fonts. Explain preview restrictions in the HTML toolbar. Do not add a JavaScript bridge. Unsupported platforms retain source text. Refreshing the same document must not needlessly recreate the preview.

## Focus and isolation

Opening or interacting with the panel must not send terminal input or trigger global Send/dictation shortcuts. Narrow overlays prevent the obscured terminal receiving focus. Desktop terminal and panel can each be focused deliberately. Late responses after switching pane, connection, cwd or background state cannot replace current content. Bound memory to eight opened documents and 2 MiB of document content per panel. Keep status/error messages within the existing panel rather than moving the terminal on every poll.

## Delivery and verification

Work on `codex/session-project-panel`, based on merged Chat `885864a`. Commit and push this new branch without merging it into main. Mirror source changes to the private build checkout, preserving signing configuration, and build release 43 for Mac, iPhone and iPad. Synthetic fixtures cover host isolation, traversal/symlinks, bounds, Unicode, changed folders and peer routing. Widget/controller tests cover Files/Specs separation, tab reuse/close, persistence, stale results, background polling, focus and narrow/light/dark layouts. Use Demo/disposable sessions for input checks; live sessions remain read-only. Run full Flutter/Python/Swift checks and one independent final review, resolve important findings, then verify installed versions separately from successful launches.
