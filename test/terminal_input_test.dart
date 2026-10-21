import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:xterm/xterm.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';

class InputFixture implements SessionBackend, TerminalInputBackend {
  @override
  String get sourceId => 'demo';
  final input = <TerminalInput>[];
  Completer<void>? hold;
  bool uncertain = false;
  bool allowComposed = false;
  int composedCalls = 0;
  Object? catalogError;
  final session = SessionInfo(
    key: const SessionKey('demo', 'demo', 'server', 't1'),
    paneId: 'p1',
    title: 'Keyboard fixture',
    project: 'fixture',
    agent: 'fixture',
    status: SessionStatus.idle,
    inputEnabled: true,
    terminalInputEnabled: true,
  );
  @override
  Future<List<SessionInfo>> listSessions() async {
    if (catalogError != null) throw catalogError!;
    return [session];
  }

  @override
  Stream<ObserveEvent> observe(SessionInfo s) {
    late StreamController<ObserveEvent> stream;
    stream = StreamController<ObserveEvent>(
      onListen: () {
        stream.add(
          TerminalFrame(
            100,
            26,
            0,
            true,
            Uint8List.fromList('fixture'.codeUnits),
          ),
        );
      },
      onCancel: () {
        unawaited(stream.close());
      },
    );
    return stream.stream;
  }

  @override
  Future<void> sendText(SessionInfo s, String t) async {
    composedCalls++;
    if (allowComposed) {
      await hold?.future;
      if (uncertain) throw DeliveryUncertain();
      return;
    }
    throw StateError('Keyboard input must not use composed text + Enter.');
  }

  @override
  Future<void> sendTerminalInput(SessionInfo s, TerminalInput event) async {
    input.add(event);
    await hold?.future;
    if (uncertain) throw DeliveryUncertain();
  }

  @override
  Future<void> close() async {}
}

class WidgetStore extends LayoutStore {
  WidgetStore() : super('unused');
  @override
  Future<void> save(AppSnapshot value) async {}
}

void main() {
  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    testWidgets('opening and switching sessions focuses typing on $platform', (
      tester,
    ) async {
      final first = Terminal()..write('First');
      final second = Terminal()..write('Second');
      final received = <String>[];
      Future<void> mount(
        String id,
        Terminal terminal, {
        bool ready = true,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: Column(
                children: [
                  const TextField(),
                  Expanded(
                    child: TerminalSurface(
                      terminal: terminal,
                      controller: TerminalController(),
                      zoom: 1,
                      inputId: id,
                      copy: () async {},
                      autofocus: true,
                      sendInput: ready ? (_) => received.add(id) : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await mount('first', first);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(received, ['first']);
      await mount('second', second, ready: false);
      await mount('second', second);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(received, ['first', 'second']);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await mount('second', second);
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .focusNode!
            .hasFocus,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final viaMenu in [true, false]) {
    testWidgets(
      'Mac ${viaMenu ? 'native Paste command' : 'Cmd+V'} inserts once without Enter',
      (tester) async {
        final received = <TerminalInput>[];
        final terminal = Terminal()..write('Disposable clipboard fixture');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': 'paste café'}
              : null,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalSurface(
                  terminal: terminal,
                  controller: TerminalController(),
                  zoom: 1,
                  inputId: 'clipboard-fixture',
                  copy: () async {},
                  sendInput: received.add,
                ),
              ),
            ),
          );
          await tester.tap(find.byType(TerminalView));
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          if (viaMenu) {
            tester
                .state<CustomTextEditState>(find.byType(CustomTextEdit))
                .performSelector('paste:');
          } else {
            await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          }
          await tester.pump();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          expect(received.map((input) => input.textValue), ['paste café']);
          expect(received.single.keyNames, isNull);
        } finally {
          await tester.pump(const Duration(milliseconds: 350));
          await tester.pumpWidget(const SizedBox());
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'delivery uncertainty fits landscape with keyboard and composer open',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.viewInsets = FakeViewPadding(
        bottom: 180 * tester.view.devicePixelRatio,
      );
      addTearDown(tester.view.resetViewInsets);
      final backend = InputFixture()..uncertain = true;
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
        await tester.tap(find.byKey(const ValueKey('toggle-composer')));
        await tester.pump();
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['up']),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('Terminal input delivery is uncertain'),
          findsOneWidget,
        );
        expect(find.text('I’ve checked').hitTestable(), findsOneWidget);
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
  testWidgets(
    'Mac Command Backspace clears to line start while Option and plain deletion stay distinct',
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
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.macOS),
            home: TerminalSurface(
              terminal: Terminal(),
              controller: TerminalController(),
              inputId: 'mac-keys',
              zoom: 1,
              copy: () async {},
              sendInput: (input) =>
                  app.sendTerminalInput(backend.session.key.id, input),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byType(TerminalView));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump(const Duration(milliseconds: 100));
        expect(backend.input.expand((e) => e.keyNames ?? []), [
          'ctrl+u',
          'alt+backspace',
          'backspace',
        ]);
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  testWidgets(
    'Command editing keys reach Herdr unchanged and app navigation remains available',
    (tester) async {
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.toggleFavourite(backend.session);
        app.select(backend.session.key.id);
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(backend.input.expand((event) => event.keyNames ?? []), [
          'cmd+backspace',
          'shift+cmd+left',
        ]);
        expect(app.sendStates[backend.session.key.id]?.message, isNull);
        expect(
          tester
              .widget<TerminalView>(find.byType(TerminalView))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(app.layout.filter, 'favourites');
        expect(backend.input.expand((event) => event.keyNames ?? []), [
          'cmd+backspace',
          'shift+cmd+left',
        ]);
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
  for (final size in [const Size(1024, 768), const Size(844, 390)]) {
    for (final composerOpen in [false, true]) {
      testWidgets(
        'unsupported keys show once without moving the terminal at $size, composer $composerOpen',
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
            await tester.pumpWidget(
              AgentSpaceApp(controller: app, desktop: false),
            );
            await tester.pump(const Duration(milliseconds: 800));
            if (composerOpen) {
              await tester.tap(find.byKey(const ValueKey('toggle-composer')));
              await tester.pump();
            }
            await tester.tap(find.byType(TerminalView));
            await tester.pump();
            final before = tester.getRect(find.byType(TerminalView));
            final focus = tester
                .widget<TerminalView>(find.byType(TerminalView))
                .focusNode!;
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await tester.pump();
            expect(tester.getRect(find.byType(TerminalView)), before);
            expect(focus.hasFocus, isTrue);
            if (!composerOpen) {
              // Mobile feedback is now in the status menu, without adding rows.
              expect(find.text('Unsupported terminal key.'), findsNothing);
              await tester.tap(find.byTooltip('Terminal status & more'));
              await tester.pumpAndSettle();
            }
            expect(find.text('Unsupported terminal key.'), findsOneWidget);
            expect(backend.input, isEmpty);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pump(const Duration(milliseconds: 350));
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(app.shutdown);
            await tester.pump();
          }
        },
      );
    }
  }
  testWidgets(
    'temporary discovery failure pauses input without losing terminal focus',
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
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        final focus = tester
            .widget<TerminalView>(find.byType(TerminalView))
            .focusNode!;
        expect(focus.hasFocus, isTrue);
        backend.catalogError = ConnectionFailure(
          'Temporary network interruption',
        );
        await app.refresh();
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        expect(
          tester.widget<TerminalView>(find.byType(TerminalView)).readOnly,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 16));
        expect(backend.input, isEmpty);
        backend.catalogError = null;
        await app.refresh();
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump();
        expect(backend.input.map((event) => event.toJson()), [
          {
            'keys': ['down'],
          },
        ]);
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
  testWidgets(
    'keyboard dispatch begins within a frame and composer starts collapsed',
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
        app.updateDraft(backend.session.key.id, 'keep draft');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
        await tester.pump(const Duration(milliseconds: 800));
        expect(find.byKey(const ValueKey('draft-input')), findsNothing);
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump();
        expect(backend.input.map((e) => e.toJson()), [
          {
            'keys': ['up'],
          },
        ]);
        await tester.tap(find.byKey(const ValueKey('toggle-composer')));
        await tester.pump();
        expect(find.byKey(const ValueKey('draft-input')), findsOneWidget);
        expect(
          (tester.widget(
            find.byKey(const ValueKey('draft-input')),
          ) as TextField).controller!.text,
          'keep draft',
        );
        await tester.tap(find.byKey(const ValueKey('toggle-composer')));
        await tester.pump();
        expect(find.byKey(const ValueKey('draft-input')), findsNothing);
        expect(app.layout.drafts[backend.session.key.id], 'keep draft');
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
  test(
    'composed delivery stays pending across source return and late failure',
    () async {
      final backend = InputFixture()
        ..allowComposed = true
        ..hold = Completer<void>()
        ..uncertain = true;
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      final id = backend.session.key.id;
      try {
        await app.start(polling: false);
        app.select(id);
        app.updateDraft(id, 'keep draft');
        final sending = app.sendDraft(id);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await app.switchSource('demo');
        app.select(id);
        app.acknowledgeDelivery(id);
        expect(app.terminalInputPending(id), isTrue);
        expect(app.canSendTerminalInput(id), isFalse);
        app.sendTerminalInput(id, TerminalInput.keys(['enter']));
        await app.sendDraft(id);
        expect(backend.composedCalls, 1);
        expect(backend.input, isEmpty);
        backend.hold!.complete();
        await sending;
        expect(app.layout.uncertainDeliveries, contains(id));
        expect(app.sendStates[id]!.uncertain, isTrue);
        expect(app.layout.drafts[id], 'keep draft');
      } finally {
        if (!backend.hold!.isCompleted) backend.hold!.complete();
        await app.shutdown();
      }
    },
  );
  testWidgets('Alt Space and Alt Shift digit retain their modifiers', (
    tester,
  ) async {
    final backend = InputFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '!');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(backend.input.expand((e) => e.keyNames ?? []), [
        'alt+space',
        'alt+shift+1',
      ]);
    } finally {
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
      await tester.pump();
    }
  });
  testWidgets(
    'phone CRLF paste reaches the terminal without changing the draft',
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
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        tester.testTextInput.enterText('  first\r\nsecond');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(backend.input.single.isPaste, isTrue);
        expect(backend.input.single.textValue, 'first\nsecond');
        expect(app.layout.drafts[backend.session.key.id], 'keep');
        expect(find.byKey(const ValueKey('draft-input')), findsNothing);
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
  for (final draftFocused in [false, true]) {
    testWidgets('Cmd+V follows focus with composer open: $draftFocused', (
      tester,
    ) async {
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      final pasted = List.filled(120, '  first\tsecond café\n').join();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': pasted} : null,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byKey(const ValueKey('toggle-composer')));
        await tester.pump();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('draft-input')),
        );
        field.controller!.selection = const TextSelection.collapsed(offset: 4);
        if (!draftFocused) {
          await tester.tap(find.byType(TerminalView));
          await tester.pump();
        }
        // Native macOS paste selector uses the focused editor, like Cmd+V.
        if (draftFocused) {
          final editor = tester.state<EditableTextState>(
            find.descendant(
              of: find.byKey(const ValueKey('draft-input')),
              matching: find.byType(EditableText),
            ),
          );
          await editor.pasteText(SelectionChangedCause.keyboard);
        } else {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        }
        await tester.pump(const Duration(milliseconds: 100));
        expect(field.focusNode!.hasFocus, draftFocused);
        expect(backend.composedCalls, 0);
        if (draftFocused) {
          expect(backend.input, isEmpty);
          expect(app.layout.drafts[backend.session.key.id], 'keep$pasted');
        } else {
          expect(backend.input.single.isPaste, isTrue);
          expect(backend.input.single.textValue, pasted);
          expect(app.layout.drafts[backend.session.key.id], 'keep');
        }
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      }
    });
  }
  testWidgets('oversized terminal paste preserves the existing draft', (
    tester,
  ) async {
    final backend = InputFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {'text': '${List.filled(maxInputBytes, 'é').join()}\nsecond'}
          : null,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      app.updateDraft(backend.session.key.id, 'keep');
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(backend.input, isEmpty);
      expect(app.layout.drafts[backend.session.key.id], 'keep');
      expect(find.textContaining('16 KiB'), findsWidgets);
    } finally {
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
      await tester.pump();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    }
  });
  test('literal spaces are valid but controls and malformed logical keys are rejected', () {
    expect(TerminalInput.text(' café ').validationError, isNull);
    expect(
      TerminalInput.keys(['up', 'ctrl+enter', 'alt+left', 'shift+tab'])
          .validationError,
      isNull,
    );
    expect(TerminalInput.text('\x1b[A').validationError, isNotNull);
    expect(TerminalInput.text('first\nsecond').validationError, isNotNull);
    expect(TerminalInput.paste('first\n\tsecond').validationError, isNull);
    expect(TerminalInput.paste('bad\x1b').validationError, isNotNull);
    expect(
      TerminalInput.keys(['ctrl+enter; injected']).validationError,
      isNotNull,
    );
    expect(TerminalInput.keys(['ctrl+ctrl+c']).validationError, isNotNull);
  });
  test(
    'keyboard input is ordered and never clears the composed draft',
    () async {
      final dir = await Directory.systemTemp.createTemp('as-input-test-');
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: LayoutStore(dir.path),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep this draft');
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.text('café '),
        );
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['up', 'ctrl+enter']),
        );
        // Input waits for the persisted checkpoint before delivery. Observe
        // delivery instead of assuming disk I/O completes within 250 ms.
        final deliveryWait = Stopwatch()..start();
        while (backend.input.length < 2 &&
            deliveryWait.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(backend.input.map((i) => i.toJson()).toList(), [
          {'text': 'café '},
          {
            'keys': ['up', 'ctrl+enter'],
          },
        ]);
        expect(app.layout.drafts[backend.session.key.id], 'keep this draft');
      } finally {
        await app.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'uncertain keyboard delivery drops queued keys and persists the warning',
    () async {
      final dir = await Directory.systemTemp.createTemp('as-input-test-');
      final backend = InputFixture()
        ..hold = Completer<void>()
        ..uncertain = true;
      final app = AppController(
        snapshot: AppSnapshot(),
        store: LayoutStore(dir.path),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['up']),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['ctrl+enter']),
        );
        backend.hold!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await app.flush();
        expect(backend.input, hasLength(1));
        expect(
          (await LayoutStore(
            dir.path,
          ).load()).layoutFor('demo').uncertainDeliveries,
          contains(backend.session.key.id),
        );
      } finally {
        await app.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'focused terminal receives arrows and Ctrl+Enter while the composer is preserved',
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
        app.updateDraft(backend.session.key.id, 'draft stays');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        app.terminals[backend.session.key.id]!.screen.terminal!.write(
          '\x1b[6n\x1b[c',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          backend.input,
          isEmpty,
          reason: 'Screen/device queries must not produce terminal input.',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(
          backend.input.expand((e) => e.keyNames ?? []),
          containsAllInOrder(['up', 'ctrl+enter']),
        );
        expect(app.layout.drafts[backend.session.key.id], 'draft stays');
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
  test('leaving a terminal before dispatch drops queued input', () async {
    final backend = InputFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      app.sendTerminalInput(
        backend.session.key.id,
        TerminalInput.keys(['ctrl+enter']),
      );
      app.overview();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(backend.input, isEmpty);
    } finally {
      await app.shutdown();
    }
  });
  test(
    'returning to a session cannot overlap a cancelled in-flight key delivery',
    () async {
      final backend = InputFixture()..hold = Completer<void>();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['up']),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await app.switchSource('demo');
        app.select(backend.session.key.id);
        app.acknowledgeDelivery(backend.session.key.id);
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['ctrl+enter']),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(backend.input, hasLength(1));
        backend.hold!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } finally {
        if (!backend.hold!.isCompleted) backend.hold!.complete();
        await app.shutdown();
      }
    },
  );
  test('an in-flight acknowledgement cannot erase a later uncertainty after source return', () async {
    final backend = InputFixture()
      ..hold = Completer<void>()
      ..uncertain = true;
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      app.sendTerminalInput(backend.session.key.id, TerminalInput.keys(['up']));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await app.switchSource('demo');
      app.select(backend.session.key.id);
      app.acknowledgeDelivery(backend.session.key.id);
      backend.hold!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(app.layout.uncertainDeliveries, contains(backend.session.key.id));
      expect(app.sendStates[backend.session.key.id]!.uncertain, isTrue);
      expect(app.canSendTerminalInput(backend.session.key.id), isFalse);
    } finally {
      if (!backend.hold!.isCompleted) backend.hold!.complete();
      await app.shutdown();
    }
  });
  test(
    'queue overflow stops the sequence and requires a delivery check',
    () async {
      final backend = InputFixture()..hold = Completer<void>();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['up']),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        for (var i = 0; i < 130; i++) {
          app.sendTerminalInput(
            backend.session.key.id,
            const TerminalInput.text('x'),
          );
          app.sendTerminalInput(
            backend.session.key.id,
            TerminalInput.keys(['right']),
          );
        }
        backend.hold!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['enter']),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(backend.input, hasLength(1));
        expect(
          app.layout.uncertainDeliveries,
          contains(backend.session.key.id),
        );
        expect(app.canSendTerminalInput(backend.session.key.id), isFalse);
      } finally {
        if (!backend.hold!.isCompleted) backend.hold!.complete();
        await app.shutdown();
      }
    },
  );
  testWidgets('AltGr characters are sent as text rather than Ctrl+Alt keys', (
    tester,
  ) async {
    final backend = InputFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ, character: '@');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(backend.input.map((e) => e.toJson()).toList(), [
        {'text': '@'},
      ]);
    } finally {
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
      await tester.pump();
    }
  });
  testWidgets(
    'multiline terminal paste keeps the message box closed and draft unchanged',
    (tester) async {
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'first\nsecond'}
            : null,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(backend.input.single.isPaste, isTrue);
        expect(backend.input.single.textValue, 'first\nsecond');
        expect(backend.composedCalls, 0);
        expect(app.layout.drafts[backend.session.key.id], 'keep');
        expect(find.byKey(const ValueKey('draft-input')), findsNothing);
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      }
    },
  );
  testWidgets('input uncertainty remains visible with the composer hidden', (
    tester,
  ) async {
    final backend = InputFixture()..uncertain = true;
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: true));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byKey(const ValueKey('draft-input')), findsNothing);
      app.sendTerminalInput(backend.session.key.id, TerminalInput.keys(['up']));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(
        find.textContaining('Terminal input delivery is uncertain'),
        findsOneWidget,
      );
      expect(find.text('I’ve checked'), findsOneWidget);
    } finally {
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
      await tester.pump();
    }
  });
  test(
    'delivery markers at their saved limit block new input before dispatch',
    () async {
      final backend = InputFixture();
      final snapshot = AppSnapshot();
      snapshot
          .layoutFor('demo')
          .uncertainDeliveries
          .addAll(
            List.generate(
              256,
              (i) => SessionKey('demo', 'demo', 'server', 'other$i').id,
            ),
          );
      final app = AppController(
        snapshot: snapshot,
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep');
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['ctrl+enter']),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await app.sendDraft(backend.session.key.id);
        expect(backend.input, isEmpty);
        expect(backend.composedCalls, 0);
        expect(app.layout.drafts[backend.session.key.id], 'keep');
      } finally {
        await app.shutdown();
      }
    },
  );
  testWidgets(
    'phone terminal accepts keyboard text without submitting its composer',
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
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'mobile draft');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);
        tester.testTextInput.enterText('  café ');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(
          backend.input.map((e) => e.toJson()),
          contains(equals({'text': 'café '})),
        );
        expect(app.layout.drafts[backend.session.key.id], 'mobile draft');
      } finally {
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        await tester.pump();
      }
    },
  );
}
