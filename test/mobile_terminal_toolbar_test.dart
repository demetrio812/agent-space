import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:agentspace/src/models.dart';

import 'terminal_input_test.dart' show InputFixture, WidgetStore;

void main() {
  for (final size in [
    const Size(320, 740),
    const Size(390, 844),
    const Size(844, 390),
    const Size(1024, 768),
  ]) {
    testWidgets(
      'mobile terminal keys retain focus and do not resize on expansion at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final backend = InputFixture();
        final app = AppController(
          snapshot: AppSnapshot(),
          store: WidgetStore(),
          backendFactory: (_) => backend,
        );
        try {
          await app.start(polling: false);
          app.select(backend.session.key.id);
          app.updateDraft(backend.session.key.id, 'keep draft');
          await tester.pumpWidget(
            AgentSpaceApp(controller: app, desktop: false),
          );
          await tester.pump(const Duration(milliseconds: 800));
          final view = tester.widget<TerminalView>(find.byType(TerminalView));
          expect(view.focusNode!.hasFocus, isTrue);
          final before = tester.getSize(find.byType(TerminalView));
          await tester.tap(find.byTooltip('Arrow keys'));
          await tester.pump();
          expect(tester.getSize(find.byType(TerminalView)), before);
          for (final tip in [
            'Arrow down',
            'Arrow up',
            'Arrow left',
            'Arrow right',
            'Enter',
            'Escape',
            'Tab',
            'Backspace',
          ]) {
            await tester.tap(find.byTooltip(tip));
            await tester.pump(const Duration(milliseconds: 60));
            expect(view.focusNode!.hasFocus, isTrue);
          }
          await tester.tap(find.byTooltip('Control next key'));
          await tester.pump();
          await tester.tap(find.byTooltip('Enter'));
          await tester.pump(const Duration(milliseconds: 60));
          await tester.tap(find.byTooltip('Enter'));
          await tester.pump(const Duration(milliseconds: 60));
          expect(backend.input.expand((e) => e.keyNames ?? <String>[]), [
            'down',
            'up',
            'left',
            'right',
            'enter',
            'esc',
            'tab',
            'backspace',
            'ctrl+enter',
            'enter',
          ]);
          expect(backend.composedCalls, 0);
          expect(app.layout.drafts[backend.session.key.id], 'keep draft');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
        }
      },
    );
  }
  testWidgets(
    'Control modifies one software key and explicit paste stays in the terminal',
    (tester) async {
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byTooltip('Control next key'));
        await tester.pump();
        tester.testTextInput.enterText('  c');
        await tester.pump(const Duration(milliseconds: 60));
        tester.testTextInput.enterText('  x');
        await tester.pump(const Duration(milliseconds: 60));
        expect(backend.input.first.keyNames, ['ctrl+c']);
        expect(backend.input.last.textValue, 'x');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': 'line one\nline two'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byTooltip('Paste into terminal'));
        await tester.pump(const Duration(milliseconds: 100));
        expect(backend.input.last.isPaste, isTrue);
        expect(backend.input.last.textValue, 'line one\nline two');
        expect(backend.composedCalls, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  testWidgets('keyboard controls, small landscape and session guards', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(568, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final terminal = Terminal();
    final controller = TerminalController();
    final received = <TerminalInput>[];
    Future<void> mount({
      double inset = 0,
      bool enabled = true,
      String id = 'a',
      bool visible = true,
    }) async {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
            child: Scaffold(
              body: TerminalSurface(
                terminal: terminal,
                controller: controller,
                zoom: 1,
                inputId: id,
                copy: () async {},
                sendInput: enabled ? received.add : null,
                autofocus: true,
                showMobileControls: visible,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await mount();
    await tester.tap(find.byTooltip('Show keyboard'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await mount(inset: 216);
    await tester.tap(find.byTooltip('Arrow keys'));
    await tester.pump();
    await tester.tap(find.byTooltip('Arrow down'));
    await tester.pump();
    expect(received.single.keyNames, ['down']);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Hide keyboard'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    await mount();
    await tester.tap(find.byTooltip('Control next key'));
    await tester.pump();
    await mount(id: 'b');
    expect(find.byTooltip('Arrow down'), findsNothing);
    await tester.tap(find.byTooltip('Escape'));
    await tester.pump();
    expect(received.last.keyNames, ['esc']);
    await mount(id: 'b', enabled: false);
    await tester.tap(find.byTooltip('Escape'));
    await tester.tap(find.byTooltip('Paste into terminal'));
    await tester.pump();
    expect(received, hasLength(2));
    await mount(visible: false);
    expect(find.byTooltip('Arrow keys'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'mobile status is in overflow without rows and warnings remain accessible',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        final id = backend.session.key.id;
        app.select(id);
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.textContaining('Click terminal to type'), findsNothing);
        expect(find.text('1/16 live'), findsNothing);
        final before = tester.getSize(find.byType(TerminalView));
        await tester.tap(find.byTooltip('Terminal status & more'));
        await tester.pumpAndSettle();
        expect(find.text('1/16 live'), findsOneWidget);
        expect(find.text('100 × 26'), findsOneWidget);
        expect(find.text('Reconnect terminal'), findsOneWidget);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TerminalView>(find.byType(TerminalView))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        app.sendStates[id] = SendState()..message = 'Unsupported terminal key.';
        app.setAppearance('dark');
        await tester.pump();
        expect(tester.getSize(find.byType(TerminalView)), before);
        await tester.tap(find.byTooltip('Terminal status & more'));
        await tester.pumpAndSettle();
        expect(find.text('Unsupported terminal key.'), findsOneWidget);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        app.sendStates[id] = SendState()
          ..message = 'Terminal input delivery is uncertain.'
          ..uncertain = true;
        app.setAppearance('light');
        await tester.pump();
        expect(find.text('I’ve checked'), findsOneWidget);
        expect(
          find.text('Terminal input delivery is uncertain.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('status overlay stays centred above the keyboard at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(
        bottom: size.height > 500 ? 300 : 190,
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        final keyboardVisible = tester.testTextInput.isVisible;
        await tester.tap(find.byTooltip('Terminal status & more'));
        await tester.pumpAndSettle();
        final rect = tester.getRect(
          find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byWidgetPredicate(
                  (w) => w is Material && w.type == MaterialType.card,
                ),
              )
              .first,
        );
        final available = size.height - tester.view.viewInsets.bottom;
        expect(rect.bottom, lessThanOrEqualTo(available));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.center.dx, closeTo(size.width / 2, 1));
        expect(rect.center.dy, closeTo(available / 2, 1));
        expect(tester.testTextInput.isVisible, keyboardVisible);
        expect(find.text('Reconnect terminal'), findsOneWidget);
        // The whole details section remains reachable in short landscape space.
        await tester.ensureVisible(find.text('1/16 live'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Close terminal status'));
        await tester.tap(find.byTooltip('Close terminal status'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(
          tester
              .widget<TerminalView>(find.byType(TerminalView))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        expect(backend.input, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    });
  }
}
