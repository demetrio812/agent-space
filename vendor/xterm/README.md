# Vendored xterm 4.0.0

Source: https://github.com/TerminalStudio/xterm.dart (pub.dev xterm 4.0.0). Original MIT license retained.

AgentSpace patch: `lib/src/ui/custom_text_edit.dart` opts into Flutter’s delta input protocol so queued iOS/Android updates send each inserted character exactly once. Composition is committed as one edit, deletion counts graphemes, and lost input connections discard pending composition. The existing snapshot callback remains for fallback clients. Rendering and terminal emulation are unchanged.

App regressions: `test/mobile_terminal_ime_test.dart` and `test/terminal_input_test.dart`.

Selection gestures explicitly focus the terminal, including fast mouse drags that bypass tap-down and taps that clear an existing selection. Covered by `test/terminal_focus_test.dart`.

Block cursors redraw the covered glyph in black or white for contrast, without mutating the terminal cell or hiding dimmed/inverse text. Pixel regressions: `test/terminal_cursor_test.dart`.
