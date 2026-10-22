# Saved split layouts for groups

## Intent and approved scope

Make it possible to follow and interact with several running sessions together in AgentSpace. The user approved Tabs (the existing single-session view), Two columns, Two rows, and a Four-panel grid, with layouts saved per group. Mac and iPad display splits; iPhone displays one panel at a time with quick switching. Panels may contain sessions from different connected computers. Clicking a panel makes it the only typing/dictation target; its border identifies the active panel. Dividers are draggable, and a panel can be temporarily maximised.

All work, commits and publication belong to `codex/group-split-layouts`. Do not merge or push changes to `main`. After implementation and verification, update the Mac, iPhone and iPad builds. The existing main-branch build remains the rollback source.

This is an AgentSpace presentation feature. It does not move, split, close or recreate Herdr terminals or workspaces. Group membership remains device-local and scoped to the existing connection source; this feature does not introduce synchronisation across devices.

## Product behaviour

Add a labelled Layout selector to group views, including the group overview and an opened group session. Existing groups default to Tabs. Selecting a split preset opens the board. Revisiting a group with a saved split preset opens its board directly. All sessions, Favourites, Recent and computer/workspace views retain their current behaviour.

The following are implementation choices made to complete the approved behaviour:

- The board has two or four fixed slots, in reading order. On first use, fill them from the group's existing session order, including the current session where possible. Empty slots offer a session picker limited to this group. Users can add sessions to the group through the existing menus.
- Each panel header shows the session name, computer and workspace, with session actions, a replacement picker and a maximise/restore control. A single shared strip allows quick access to all group sessions, including groups larger than four. Choosing a session already displayed focuses its panel; choosing another session replaces the focused slot. If no slot is focused, use the first slot. Selecting an already assigned session through a panel picker swaps the two assignments, so a terminal never appears twice on the same board.
- Keep saved assignments independent of the group's list ordering. Reordering group tabs or changing grid sorting must not silently rearrange the board. Changing between two and four panels preserves the four saved slots and restores hidden assignments when returning to four panels. Tabs and split modes preserve the selected session where possible.
- Save the preset, up to four session IDs, the active slot and divider proportions per group using the existing layout store. Tabs remains the backward-compatible default for old or unknown data. Reject invalid IDs, duplicates, non-group assignments and non-finite ratios; clamp divider ratios to usable limits. Do not discard assignments merely because a computer is temporarily offline.
- Removing a session from a group clears its slot. Deleting a group removes its layout with the group, without closing terminals. An unavailable assigned session stays in place with its existing unavailable/reconnect state rather than causing other panels to shift.
- Two columns and Two rows each have one divider. The four-panel grid has one shared column divider and one shared row divider. Start at equal sizes; constrain proportions to 20–80% and also enforce the minimum useful panel dimensions. Provide a reset-to-equal-size action and keyboard/accessibility adjustment for dividers.
- Maximising is temporary view state, not a saved layout change. Restore returns to the existing assignments and proportions. Focus remains on that panel. Changing group/source exits maximised mode.

## Small screens, keyboard and themes

On iPhone, display only the active assigned session with the shared group switching strip. Expose all group sessions through the same selection mechanism; the user must not be limited to the first two/four. Preserve the group's chosen split preset and assignments so returning to a larger viewport restores them.

On iPad and Mac, fall back to one panel if available content dimensions cannot provide at least 280 logical pixels of width and 200 logical pixels of height per panel. This also covers narrow windows, multitasking, large text and the software keyboard. Fallback does not rewrite the saved preset or proportions. The builder may tune these thresholds after testing, provided that readable terminals and reachable controls take priority over squeezing in splits.

Only one mobile terminal control bar is shown, for the active panel. Do not duplicate global connection bars or the group switching strip inside every panel. Panel status and delivery uncertainty remain local and visible. Existing light/dark colours, terminal selection contrast, scrolling, image drops and the centred mobile overflow/directional controls must continue to work.

## Focus and input safety

The controller retains one active input destination, even when several terminals are live. Pointer/touch activation of a panel establishes its identity before terminal input, paste, dictation or image-drop actions proceed. Only the active panel may autofocus; mounting other panels, receiving output, refreshing the catalogue or reconnecting a different panel must not steal focus.

The Message field remains independent for each session. Paste goes there only when it is open and focused. Otherwise terminal paste uses the active terminal's existing path. Keep per-session drafts and selections stable when changing focus and avoid remounting unaffected panels.

Input, transfer and dictation operations capture their session and connection generation. A layout/focus change must never redirect an in-flight operation to a different session. Retain the existing cancellation, delivery-uncertainty and no-automatic-resend protections. Never broadcast input to multiple panels. Tests and native verification use Demo or disposable terminals only; do not send test input to real agents.

## Terminal streams and size ownership

Currently `_syncStreams`, viewport control and autofocus assume one selected terminal. Extend this explicitly rather than treating non-active panels as static previews.

The board reports a deduplicated set of visible terminal IDs. Every visible split panel gets its own live stream and independently measured rows/columns, using the existing viewport protocol. Focus changes between already visible panels must not stop and restart their streams. Resize/zoom changes are debounced and coalesced per terminal, and use each panel's available content rectangle.

Prioritise the active terminal, other visible board terminals, detached-window targets and ordinary previews in that order within the existing 16-stream cap. Hidden slots in two-panel or phone fallback mode need not retain live streams. Temporary maximise may retain the board's existing subscriptions to avoid reconnect churn, but hidden panels must not send zero-size or stale viewport measurements.

For a session also open in a detached window, use one explicit size owner through the existing desktop coordination: only the focused presentation may publish geometry for that same session. Other presentations continue observing and fitting their display without competing resize requests. Focus changes hand over ownership; they must not create duplicated input or unbounded subscriptions. The detailed mechanism is left to the implementation plan after inspecting the existing window protocol.

Leaving the group, changing connection source, deleting the group and disposing the board release its stream/geometry registrations. Existing background/resume policy and terminal caches remain in force. A failed pane reconnect must not tear down healthy panes.

## Persistence and rollback

Extend each `TabGroup` with optional layout data; avoid an incompatible top-level store version bump. Existing builds can still load groups and sessions while ignoring new fields. Restoring a main-branch build must keep group membership, favourites and drafts usable. Older builds may omit the new optional fields when saving; losing split preferences on rollback is acceptable, losing existing user data is not.

Use stable session keys throughout; never persist catalogue indexes or viewport-specific fallback choices. Keep public sources free of private machine names, credentials, device identifiers and test logs. Maintain the private development copy on the matching feature branch.

## Verification and delivery

Test persistence round trips, legacy/invalid data, group removal and session reassignment; rendering all four modes; group switching and phone fallback without overwriting saved layouts; unequal divider persistence and reset; maximise/restore; and more group sessions than visible slots.

Controller and widget regression tests must prove that typing/paste/dictation target only the active session, output/reconnects do not steal focus, active Message fields keep their paste behaviour, pending operations cannot migrate to another destination, and switching focus between visible terminals keeps their streams and sizes stable. Include duplicate assignment prevention, stale/unavailable sessions, cleanup and detached-window size ownership.

Run the relevant Flutter checks with FVM, static analysis and existing native Mac startup/keyboard regressions. Review the implementation independently. Use Demo for native Mac/iPhone/iPad layout and keyboard checks, including portrait/landscape, software keyboard, small windows, light/dark appearance and drag resizing. Install release builds on all three devices; if a device is unavailable, report that installation as pending rather than complete.

Commit and push the feature branch only. Report the branch, commit and actual device installation results. No merge to main is authorised.
