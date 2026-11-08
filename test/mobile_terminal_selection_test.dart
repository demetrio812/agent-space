import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/terminal_pane.dart';

void main() {
  testWidgets(
    'phone selection stays stable, copies exactly and pastes without Enter',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final terminal = Terminal()
        ..resize(40, 20)
        ..write('alpha bravo charlie');
      final controller = TerminalController();
      final received = <TerminalInput>[];
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: TerminalSurface(
              terminal: terminal,
              controller: controller,
              zoom: 1,
              inputId: 'phone',
              autofocus: true,
              showMobileControls: true,
              sendInput: received.add,
              copy: () async {},
            ),
          ),
        ),
      );
      await tester.pump();
      final focus = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .focusNode!;
      await tester.tap(find.byTooltip('Select terminal text'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('terminal-selectable-text'));
      expect(field, findsOneWidget);
      final input = tester.widget<TextField>(field);
      expect(input.readOnly, isTrue);
      terminal.write(' NEW OUTPUT');
      await tester.pump();
      expect(input.controller!.text, 'alpha bravo charlie');
      final editable = tester.state<EditableTextState>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      final render = editable.renderEditable;
      final caret = render.getLocalRectForCaret(const TextPosition(offset: 8));
      await tester.longPressAt(render.localToGlobal(caret.center));
      await tester.pumpAndSettle();
      expect(
        input.controller!.selection.textInside(input.controller!.text),
        'bravo',
      );
      await tester.tap(find.byTooltip('Copy selected text'));
      await tester.pumpAndSettle();
      expect(clipboard, 'bravo');
      expect(received, isEmpty);
      await tester.tap(find.byTooltip('Paste selection into terminal'));
      await tester.pumpAndSettle();
      expect(received, hasLength(1));
      expect(received.single.isPaste, isTrue);
      expect(received.single.textValue, 'bravo');
      expect(field, findsNothing);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'selection can copy while input is unavailable and never follows another session',
    (tester) async {
      final terminal = Terminal()..write('original');
      final controller = TerminalController();
      final received = <TerminalInput>[];
      final id = ValueNotifier('a');
      final enabled = ValueNotifier(false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: Listenable.merge([id, enabled]),
              builder: (_, _) => TerminalSurface(
                terminal: terminal,
                controller: controller,
                zoom: 1,
                inputId: id.value,
                showMobileControls: true,
                copy: () async {},
                sendInput: enabled.value ? received.add : null,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Select terminal text'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.content_copy),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Paste selection'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Close text selection'));
      await tester.pumpAndSettle();
      enabled.value = true;
      await tester.pump();
      await tester.tap(find.byTooltip('Select terminal text'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      id.value = 'b';
      await tester.pump();
      id.value = 'a';
      await tester.pump();
      await tester.tap(find.byTooltip('Paste selection into terminal'));
      await tester.pumpAndSettle();
      expect(received, isEmpty);
      expect(
        find.text('The session changed. Selection was not pasted.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      id.dispose();
      enabled.dispose();
    },
  );
}
