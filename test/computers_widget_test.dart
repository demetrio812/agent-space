import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
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

  for (final size in [const Size(320, 568), const Size(1024, 768)]) {
    testWidgets('grid sort menu works at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await create(tester);
      await tester.tap(find.byTooltip('Sort sessions'));
      await tester.pumpAndSettle();
      expect(find.text('Recently opened'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<SessionSort>, 'Name'),
      );
      await tester.pumpAndSettle();
      expect(app.layout.gridSort, SessionSort.name);
      expect(tester.takeException(), isNull);
    });
  }
  for (final size in [const Size(390, 844), const Size(1366, 1024)]) {
    testWidgets('sidebar expands only the selected computer at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await create(tester);
      Future<void> openSidebar() async {
        final picker = find.byKey(const ValueKey('workspace-picker'));
        if (picker.evaluate().isNotEmpty &&
            find.byTooltip('Close sidebar').evaluate().isEmpty) {
          await tester.tap(picker);
          await tester.pumpAndSettle();
        }
      }

      await openSidebar();
      final peer = app.sessions.last;
      final other = app.sessions.first;
      final all = find.byKey(const ValueKey('nav-all-computers'));
      expect(all, findsOneWidget);
      expect(
        tester.getTopLeft(all).dy,
        lessThan(tester.getTopLeft(find.text('Computers')).dy),
      );
      expect(
        find.byKey(ValueKey('workspace-${other.workspaceFilterId}')),
        findsNothing,
      );
      final computer = find.byKey(ValueKey('computer-${peer.computerId}'));
      await tester.tap(computer);
      await tester.pumpAndSettle();
      if (size.width < 850) {
        expect(find.byTooltip('Close sidebar'), findsOneWidget);
      }

      final workspace = find.byKey(
        ValueKey('workspace-${peer.workspaceFilterId}'),
      );
      await tester.ensureVisible(workspace);
      expect(
        find.byKey(ValueKey('workspace-${other.workspaceFilterId}')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(workspace).dy,
        greaterThan(tester.getBottomLeft(computer).dy),
      );
      await tester.tap(computer);
      await tester.pumpAndSettle();
      expect(workspace, findsNothing);
      expect(app.selectedComputerId, peer.computerId);
      await tester.tap(computer);
      await tester.pumpAndSettle();
      expect(workspace, findsOneWidget);
      await tester.tap(workspace);
      await tester.pumpAndSettle();
      await openSidebar();
      expect(app.selectedComputerId, peer.computerId);
      expect(
        find.byKey(ValueKey('workspace-${other.workspaceFilterId}')),
        findsNothing,
      );
      app.select(peer.key.id);
      await tester.pumpAndSettle();
      await tester.tap(computer);
      await tester.pumpAndSettle();
      expect(workspace, findsNothing);
      expect(app.layout.filter, peer.workspaceFilterId);
      expect(app.selectedSession?.key, peer.key);
      final otherComputer = find.byKey(
        ValueKey('computer-${other.computerId}'),
      );
      await tester.ensureVisible(otherComputer);
      await tester.tap(otherComputer);
      await tester.pumpAndSettle();
      expect(app.selectedComputerId, other.computerId);
      expect(app.selectedSession, isNull);
      expect(workspace, findsNothing);
      expect(
        find.byKey(ValueKey('workspace-${other.workspaceFilterId}')),
        findsOneWidget,
      );
      await tester.ensureVisible(all);
      await tester.tap(all);
      await tester.pumpAndSettle();
      await openSidebar();
      expect(app.layout.filter, 'all');
      expect(app.visibleSessions.length, 3);
      expect(
        find.byKey(ValueKey('workspace-${other.workspaceFilterId}')),
        findsNothing,
      );
      if (size.width < 850) {
        await tester.tap(find.byTooltip('Close sidebar'));
        await tester.pumpAndSettle();
      }
      final overviewWorkspace = find.byKey(
        ValueKey('overview-workspace-${other.workspaceFilterId}'),
      );
      await tester.ensureVisible(overviewWorkspace);
      await tester.tap(overviewWorkspace);
      await tester.pumpAndSettle();
      expect(app.layout.filter, other.workspaceFilterId);
      await openSidebar();
      expect(
        find.byKey(ValueKey('workspace-${other.workspaceFilterId}')),
        findsOneWidget,
      );
      expect(workspace, findsNothing);
      await tester.runAsync(app.flush);
      expect(tester.takeException(), isNull);
    });
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
      final peer = app.sessions.singleWhere(
        (s) => s.origin!.herdrSession == 'work',
      );
      final button = find.byKey(ValueKey('computer-${peer.computerId}'));
      if (picker.evaluate().isNotEmpty) {
        await tester.scrollUntilVisible(
          button,
          150,
          scrollable: find
              .descendant(
                of: find.byType(Drawer),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      } else {
        await tester.ensureVisible(button);
      }
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'^Computer Mac · work')),
        findsOneWidget,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(app.layout.filter, 'computer:${peer.computerId}');
      expect(app.visibleSessions.single.key, peer.key);
      if (picker.evaluate().isNotEmpty) {
        expect(find.byTooltip('Close sidebar'), findsOneWidget);
        await tester.tap(find.byTooltip('Close sidebar'));
        await tester.pumpAndSettle();
      }
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
            scrollable: find
                .descendant(
                  of: find.byType(Drawer),
                  matching: find.byType(Scrollable),
                )
                .first,
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
