# Vendored xterm 4.0.0

Source: https://github.com/TerminalStudio/xterm.dart (pub.dev xterm 4.0.0). Original MIT license retained.

AgentSpace patch: `lib/src/ui/custom_text_edit.dart` opts into Flutter’s delta input protocol so queued iOS/Android updates send each inserted character exactly once. Composition is committed as one edit, deletion counts graphemes, and lost input connections discard pending composition. The existing snapshot callback remains for fallback clients. Rendering and terminal emulation are unchanged.

App regressions: `test/mobile_terminal_ime_test.dart` and `test/terminal_input_test.dart`.
