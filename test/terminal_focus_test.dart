import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:agentspace/src/models.dart';

void main() {
  testWidgets(
    'opening a paused terminal focuses it without later stealing editor focus',
    (tester) async {
      final terminal = Terminal()..write('Connecting');
      final controller = TerminalController();
      final received = <TerminalInput>[];
      final ready = ValueNotifier(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: ready,
              builder: (context, enabled, _) => Column(
                children: [
                  const TextField(),
                  Expanded(
                    child: TerminalSurface(
                      terminal: terminal,
                      controller: controller,
                      zoom: 1,
                      inputId: 'fixture',
                      autofocus: true,
                      copy: () async {},
                      sendInput: enabled ? received.add : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final focus = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode!;
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(received, isEmpty);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      ready.value = true;
      await tester.pump();
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.enterText(find.byType(TextField), 'search');
      expect(received, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      ready.dispose();
    },
  );

  for (final change in ['input', 'scroll']) {
    testWidgets('$change availability updates preserve focus and selection', (
      tester,
    ) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('COPY THIS');
      final controller = TerminalController();
      final received = <TerminalInput>[];
      String? copied;
      Future<void> mount(bool ready) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS),
            home: Scaffold(
              body: Column(
                children: [
                  const TextField(),
                  Expanded(
                    child: TerminalSurface(
                      terminal: terminal,
                      controller: controller,
                      zoom: 1,
                      inputId: 'fixture',
                      autofocus: true,
                      copy: () async {
                        copied = terminal.buffer.getText(controller.selection!);
                      },
                      sendInput: change == 'input' && !ready
                          ? null
                          : received.add,
                      onScroll: change == 'scroll' && !ready
                          ? null
                          : (_) async {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await mount(true);
      final focus = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode!;
      expect(focus.hasFocus, isTrue);
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(9, 0),
      );
      await mount(false);
      await tester.pump(const Duration(seconds: 1));
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(copied, 'COPY THIS');
      if (change == 'input') {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        expect(received, isEmpty);
      }
      await mount(true);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(received.last.toJson(), {
        'keys': ['down'],
      });
      // Background updates must respect an intentional move to another editor.
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await mount(false);
      await mount(true);
      expect(focus.hasFocus, isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  for (final action in ['drag', 'clear selection']) {
    testWidgets('$action in terminal takes focus from another editor', (
      tester,
    ) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('COPY THIS');
      final controller = TerminalController();
      String? copied;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: Column(
              children: [
                const TextField(),
                Expanded(
                  child: TerminalSurface(
                    terminal: terminal,
                    controller: controller,
                    zoom: 1,
                    inputId: 'fixture',
                    autofocus: true,
                    sendInput: (_) {},
                    copy: () async {
                      copied = terminal.buffer.getText(controller.selection!);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final view = tester.state<TerminalViewState>(find.byType(TerminalView));
      final render = view.renderTerminal;
      final start = render.localToGlobal(const Offset(1, 8));
      if (action == 'drag') {
        // A fast mouse drag can win the arena before tap-down is delivered.
        final mouse = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(start + Offset(render.cellSize.width * 9, 0));
        await mouse.up();
        await tester.pump();
        expect(controller.selection, isNotNull);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        expect(copied?.trim(), 'COPY THIS');
      } else {
        controller.setSelection(
          terminal.buffer.createAnchor(0, 0),
          terminal.buffer.createAnchor(9, 0),
        );
        await tester.tapAt(start);
        await tester.pump();
        expect(controller.selection, isNull);
      }
      expect(view.widget.focusNode!.hasFocus, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
