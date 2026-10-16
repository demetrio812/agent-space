import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/storage.dart';

import 'fixtures/network_fixture.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ac-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  Future<AppController> create(
    WidgetTester tester, {
    String appearance = 'system',
    int count = 3,
  }) async {
    final fixture = NetworkFixture();
    fixture.initial = [
      fixture.session(machine: 'gateway', label: 'Gateway'),
      fixture.session(machine: fixtureMachineA, label: 'Mac'),
      fixture.session(
        machine: fixtureMachineB,
        label: 'Mac',
        herdrSession: 'work',
      ),
      for (var i = 3; i < count; i++)
        fixture.session(
          machine: i.toRadixString(16).padLeft(32, '0'),
          label: 'Computer $i 長い名前',
        ),
    ];
    final app = fixture.controller(directory, store: _MemoryStore());
    app.snapshot.appearance = appearance;
    await app.start(polling: false);
    await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
    });
    return app;
  }

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1366, 1024),
  ]) {
    testWidgets('computer filters fit phone and tablet at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await create(tester);
      final picker = find.byKey(const ValueKey('workspace-picker'));
      if (picker.evaluate().isNotEmpty) {
        await tester.tap(picker);
        await tester.pumpAndSettle();
      }
      expect(find.text('Computers'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Computer Mac · work')),
        findsOneWidget,
      );
      final peer = app.sessions.singleWhere(
        (s) => s.origin!.herdrSession == 'work',
      );
      final button = find.byKey(ValueKey('computer-${peer.computerId}'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(app.layout.filter, 'computer:${peer.computerId}');
      expect(app.visibleSessions.single.key, peer.key);
      expect(find.byTooltip('Close sidebar'), findsNothing);
      expect(tester.takeException(), isNull);
      if (size.width < 700) {
        await tester.tap(find.byTooltip('Find a session'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Cancel search'), findsOneWidget);
        expect(
          tester.getSize(find.byType(TextField).first).width,
          greaterThan(size.width - 100),
        );
        await tester.tap(find.byTooltip('Cancel search'));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(app.shutdown);
    });
  }
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    for (final appearance in ['system', 'light', 'dark']) {
      testWidgets(
        'long computer list stays scrollable with keyboard in $appearance at $size',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          tester.view.viewInsets = FakeViewPadding(
            bottom:
                (size.height > size.width ? 320 : 220) *
                tester.view.devicePixelRatio,
          );
          addTearDown(tester.view.resetViewInsets);
          final app = await create(tester, appearance: appearance, count: 64);
          await tester.tap(find.byKey(const ValueKey('workspace-picker')));
          await tester.pumpAndSettle();
          final last = app.computers.last;
          final button = find.byKey(
            ValueKey('computer-${last.origin.computerId}'),
          );
          await tester.scrollUntilVisible(
            button,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.runAsync(app.shutdown);
        },
      );
    }
  }
  testWidgets(
    'All sessions, named search and unavailable favourites retain origins',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = NetworkFixture();
      final a = fixture.session(machine: fixtureMachineA, label: 'Mac'),
          b = fixture.session(
            machine: fixtureMachineB,
            label: 'Mac',
            herdrSession: 'nightly',
          );
      fixture.initial = [a, b];
      fixture.completeInitially = false;
      final app = fixture.controller(directory, store: _MemoryStore());
      await app.start(polling: false);
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pumpAndSettle();
      expect(app.visibleSessions, hasLength(2));
      expect(
        app.workspaces.values.every((label) => label.contains('Mac')),
        true,
      );
      expect(find.textContaining('Mac · nightly'), findsWidgets);
      final search = find.byType(TextField).first;
      await tester.enterText(search, 'nightly');
      await tester.pumpAndSettle();
      expect(app.visibleSessions.single.key, b.key);
      await tester.enterText(search, '');
      app.toggleFavourite(b);
      fixture.emit(
        NetworkUpdate(
          epoch: fixture.epoch,
          computers: [
            ComputerInfo(origin: a.origin!, state: ComputerState.live),
            ComputerInfo(origin: b.origin!, state: ComputerState.offline),
          ],
          sessions: [a, b.unavailable()],
          complete: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-favourites')));
      await tester.pumpAndSettle();
      expect(app.visibleSessions.single.key, b.key);
      expect(app.visibleSessions.single.available, false);
      expect(find.text('Unavailable'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.runAsync(app.shutdown);
    },
  );
  testWidgets('another computer status never shifts the selected terminal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = NetworkFixture();
    final a = fixture.session(machine: fixtureMachineA, label: 'A'),
        b = fixture.session(machine: fixtureMachineB, label: 'B');
    fixture.initial = [a, b];
    fixture.completeInitially = false;
    final app = fixture.controller(directory, store: _MemoryStore());
    await app.start(polling: false);
    app.select(a.key.id);
    await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
    await tester.pump(const Duration(milliseconds: 100));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
    });
    final terminal = find.byType(TerminalView);
    expect(terminal, findsOneWidget);
    await tester.tap(terminal);
    await tester.pump();
    final focus = tester.widget<TerminalView>(terminal).focusNode!;
    expect(focus.hasFocus, true);
    final before = tester.getRect(terminal);
    fixture.emit(
      NetworkUpdate(
        epoch: fixture.epoch,
        computers: [
          ComputerInfo(origin: a.origin!, state: ComputerState.live),
          ComputerInfo(
            origin: b.origin!,
            state: ComputerState.attention,
            message: 'Check access',
          ),
        ],
        sessions: [a, b.unavailable()],
        complete: false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getRect(terminal), before);
    expect(focus.hasFocus, true);
    expect(find.text('Check access'), findsOneWidget);
    expect(app.connectionState.toString(), contains('live'));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(app.shutdown);
  });
}

class _MemoryStore extends LayoutStore {
  _MemoryStore() : super('/unused');
  @override
  Future<void> save(AppSnapshot value) async {}
}
