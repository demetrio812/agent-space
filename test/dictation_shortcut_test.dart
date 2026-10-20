import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/controller.dart';

import 'terminal_input_test.dart' show InputFixture;

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/dictation_dialog.dart';
import 'package:agentspace/src/dictation_settings.dart';
import 'package:agentspace/src/dictation_shortcut.dart';
import 'package:agentspace/src/storage.dart';

import 'app_widget_test.dart' show createApp, closeApp;
import 'dictation_widgets_test.dart' show MemoryKeys, MemoryStore;

void main() {
  test('default shortcut and custom choice survive saving', () {
    final snapshot = AppSnapshot();
    expect(snapshot.dictationShortcut.label, '⌘⇧D');
    snapshot.dictationShortcut = const DictationShortcut(
      key: 'K',
      command: false,
      control: true,
      option: true,
      shift: false,
    );
    final restored = AppSnapshot.fromJson(snapshot.toJson());
    expect(restored.dictationShortcut.label, '⌃⌥K');
    expect(restored.dictationShortcut.enabled, isTrue);
    snapshot.dictationShortcut = snapshot.dictationShortcut.copyWith(
      enabled: false,
    );
    expect(
      AppSnapshot.fromJson(snapshot.toJson()).dictationShortcut.enabled,
      isFalse,
    );
  });
  test('unsafe or malformed stored combinations revert to default', () {
    for (final value in [
      null,
      {'key': 'unknown'},
      {'key': 'Q', 'command': true, 'shift': false},
      {
        'key': 'D',
        'command': false,
        'control': false,
        'option': false,
        'shift': false,
      },
    ]) {
      final snapshot = AppSnapshot.fromJson({
        'version': 1,
        'dictationShortcut': value,
      });
      expect(snapshot.dictationShortcut.label, '⌘⇧D');
    }
    expect(
      const DictationShortcut(key: 'V', shift: false).validationError,
      isNotNull,
    );
  });
  test('native Mac menu combinations cannot be assigned', () {
    for (final value in [
      const DictationShortcut(key: 'F', control: true, shift: false),
      const DictationShortcut(key: 'F', option: true, shift: false),
      const DictationShortcut(key: 'V', option: true),
      const DictationShortcut(key: 'G'),
      const DictationShortcut(key: 'E', shift: false),
      const DictationShortcut(key: 'J', shift: false),
    ]) {
      expect(value.validationError, isNotNull, reason: value.label);
    }
  });
  testWidgets(
    'Mac shortcut opens once from a focused terminal and respects disabling',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final backend = InputFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: MemoryStore(),
        backendFactory: (_) => backend,
      );
      await app.start(polling: false);
      try {
        app.select(app.sessions.first.key.id);
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        expect(
          tester
              .widget<TerminalView>(find.byType(TerminalView))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
        await tester.pumpAndSettle();
        expect(find.byType(DictationDialog), findsOneWidget);
        expect(backend.input, isEmpty);
        expect(backend.composedCalls, 0);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
        expect(find.byType(DictationDialog), findsOneWidget);
        await tester.tap(
          find.text('Close').evaluate().isNotEmpty
              ? find.text('Close')
              : find.text('Cancel'),
        );
        await tester.pumpAndSettle();
        app.setDictationShortcut(
          app.snapshot.dictationShortcut.copyWith(enabled: false),
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pumpAndSettle();
        expect(find.byType(DictationDialog), findsNothing);
        Future<void> pressShortcut(LogicalKeyboardKey key) async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await tester.pumpAndSettle();
        }

        app.setDictationShortcut(const DictationShortcut(key: 'K'));
        await pressShortcut(LogicalKeyboardKey.keyD);
        expect(find.byType(DictationDialog), findsNothing);
        await pressShortcut(LogicalKeyboardKey.keyK);
        expect(find.byType(DictationDialog), findsOneWidget);
        await tester.tap(
          find.text('Close').evaluate().isNotEmpty
              ? find.text('Close')
              : find.text('Cancel'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Settings & connections'));
        await tester.pumpAndSettle();
        await pressShortcut(LogicalKeyboardKey.keyK);
        expect(find.byType(DictationDialog), findsNothing);
      } finally {
        await closeApp(tester, app);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets('iOS hardware keyboard does not trigger the Mac shortcut', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final app = await createApp();
    try {
      app.select(app.sessions.first.key.id);
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byType(DictationDialog), findsNothing);
    } finally {
      await closeApp(tester, app);
      debugDefaultTargetPlatformOverride = null;
    }
  });
  testWidgets('Mac settings edits shortcut and reports conflicts', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final app = await createApp();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DictationSettings(app: app, keys: MemoryKeys()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Change shortcut'));
      await tester.tap(find.text('Change shortcut'));
      await tester.pumpAndSettle();
      expect(find.text('Dictation shortcut'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shortcut-key')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('K').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('K').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save shortcut'));
      await tester.pumpAndSettle();
      expect(app.snapshot.dictationShortcut.label, '⌘⇧K');
    } finally {
      await closeApp(tester, app);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
