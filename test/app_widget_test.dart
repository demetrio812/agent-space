import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoSlider;
import 'package:agentspace/src/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/demo_backend.dart';
import 'package:agentspace/src/storage.dart';

Future<AppController> createApp() async {
  final app = AppController(
    snapshot: AppSnapshot(),
    store: _MemoryStore(),
    backendFactory: (_) => DemoBackend(),
  );
  await app.start(polling: false);
  return app;
}

Future<void> closeApp(WidgetTester tester, AppController app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(app.shutdown);
  await tester.pump();
}

void main() {
  testWidgets('landscape safe area still allows opening the phone sidebar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 440));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.physicalSize = Size(960, 440) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    tester.view.padding = FakeViewPadding(
      left: 60 * tester.view.devicePixelRatio,
      right: 60 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetPadding);
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('workspace-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('nav-favourites')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('phone sidebar selects a workspace and closes at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('workspace-picker')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('nav-favourites')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final library = app.sessions.firstWhere(
          (s) => s.workspaceLabel == 'Library',
        );
        final computer = find.byKey(ValueKey('computer-${library.computerId}'));
        await tester.scrollUntilVisible(
          computer,
          100,
          scrollable: find
              .descendant(
                of: find.byType(Drawer),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(computer);
        await tester.pumpAndSettle();
        final workspace = find.byKey(
          ValueKey('workspace-${library.workspaceFilterId}'),
        );
        await tester.scrollUntilVisible(
          workspace,
          100,
          scrollable: find
              .descendant(
                of: find.byType(Drawer),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(workspace);
        await tester.pumpAndSettle();
        await tester.tap(workspace);
        await tester.pumpAndSettle();
        expect(app.visibleSessions.length, 4);
        expect(
          app.visibleSessions.every(
            (session) => session.workspaceLabel == 'Library',
          ),
          isTrue,
        );
        expect(find.byTooltip('Close sidebar'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('workspace-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close sidebar'));
        await tester.pumpAndSettle();
        expect(app.visibleSessions.length, 4);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
    testWidgets(
      'phone search uses the top bar and cancel restores navigation at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = await createApp();
        try {
          await tester.pumpWidget(
            AgentSpaceApp(controller: app, desktop: false),
          );
          await tester.pump();
          await tester.tap(find.byTooltip('Find a session'));
          await tester.pump();
          final search = find.widgetWithText(TextField, 'Find a session');
          expect(tester.getSize(search).width, greaterThan(size.width - 130));
          expect(find.byKey(const ValueKey('workspace-picker')), findsNothing);
          expect(find.byTooltip('Settings & connections'), findsNothing);
          await tester.enterText(search, 'Build navigation');
          await tester.pump();
          expect(app.visibleSessions.length, 1);
          await tester.tap(find.byTooltip('Cancel search'));
          await tester.pump();
          expect(app.search, isEmpty);
          expect(app.visibleSessions.length, 12);
          expect(
            find.byKey(const ValueKey('workspace-picker')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byTooltip('Settings & connections').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await closeApp(tester, app);
        }
      },
    );
  }
  testWidgets('live source button remains readable in dark appearance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      app.snapshot.profiles.add(
        ConnectionProfile(
          id: 'fixture',
          label: 'Test computer',
          kind: ConnectionKind.ssh,
        ),
      );
      await app.switchSource('fixture');
      app.setAppearance('dark');
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Test computer'),
      );
      final foreground = button.style!.foregroundColor!.resolve({})!;
      final background = button.style!.backgroundColor!.resolve({})!;
      final a = foreground.computeLuminance(),
          b = background.computeLuminance();
      final ratio = (a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05));
      expect(ratio, greaterThanOrEqualTo(4.5));
    } finally {
      await closeApp(tester, app);
    }
  });
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1024, 768),
  ]) {
    testWidgets(
      'mobile flow: search, favourite, terminal, message, zoom and connection editor at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = await createApp();
        try {
          app.setAppearance('dark');
          await tester.pumpWidget(
            AgentSpaceApp(controller: app, desktop: false),
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
          final searchIcon = find.byTooltip('Find a session');
          if (searchIcon.evaluate().isNotEmpty) await tester.tap(searchIcon);
          await tester.pump();
          expect(tester.takeException(), isNull);
          final search = find.widgetWithText(TextField, 'Find a session');
          await tester.enterText(search, 'Build navigation');
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(app.visibleSessions.length, 1);
          final id = app.visibleSessions.single.key.id;
          await tester.tap(find.byKey(ValueKey('star-$id')));
          expect(app.isFavourite(id), isTrue);
          await tester.tap(find.byKey(ValueKey('tile-$id')));
          await tester.pump(const Duration(milliseconds: 800));
          if (find.byTooltip('Cancel search').evaluate().isNotEmpty) {
            await tester.tap(find.byTooltip('Cancel search'));
            await tester.pump(const Duration(milliseconds: 800));
          }
          expect(tester.takeException(), isNull);
          final before = app.terminals[id]!.screen.columns;
          if (find.byTooltip('Larger text').evaluate().isNotEmpty) {
            await tester.tap(find.byTooltip('Larger text'));
          } else {
            await tester.tap(find.byTooltip('Settings & connections'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.scrollUntilVisible(
              find.text('Terminal zoom'),
              150,
              scrollable: find
                  .descendant(
                    of: find.byKey(const ValueKey('settings-scroll')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await Scrollable.ensureVisible(
              tester.element(find.byType(CupertinoSlider).last),
              alignment: .5,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final sliderRect = tester.getRect(
              find.byType(CupertinoSlider).last,
            );
            await tester.dragFrom(
              Offset(
                sliderRect.left + 14 + (sliderRect.width - 28) * .2,
                sliderRect.center.dy,
              ),
              const Offset(30, 0),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            await tester.tap(find.byTooltip('Close settings'));
          }
          await tester.pump(const Duration(milliseconds: 800));
          expect(tester.takeException(), isNull);
          expect(app.terminals[id]!.screen.columns, lessThan(before));
          expect(find.byKey(const ValueKey('draft-input')), findsNothing);
          await tester.tap(find.byKey(const ValueKey('toggle-composer')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.enterText(
            find.byKey(const ValueKey('draft-input')),
            'Mobile review',
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('send-draft')));
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
          expect(app.layout.drafts[id], isNull);
          expect(app.sendStates[id]!.message, contains('Sent'));
          await tester.tap(find.byKey(const ValueKey('toggle-composer')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Settings & connections'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('Add SSH connection'));
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Connection editor must fit the screen',
          );
          expect(find.text('SSH connection'), findsOneWidget);
          expect(find.text('Private key file'), findsNothing);
          await tester.tap(find.text('Save & connect'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final error = find.text(
            'Enter a host, username and valid port, then verify its SSH fingerprint.',
          );
          await tester.scrollUntilVisible(
            error,
            100,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(error, findsOneWidget);
          await tester.tap(find.byTooltip('Close connection settings'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byTooltip('Close settings'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('show-overview')));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(app.selectedSession, isNull);
          expect(app.isFavourite(id), isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await closeApp(tester, app);
        }
      },
    );
  }
  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    testWidgets(
      'appearance switches without losing the selected session or draft at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final app = await createApp();
        try {
          final id = app.sessions.first.key.id;
          app.select(id);
          app.updateDraft(id, 'Preserve my draft');
          await tester.pumpWidget(
            AgentSpaceApp(controller: app, desktop: false),
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
            Brightness.dark,
          );
          await tester.tap(find.byTooltip('Settings & connections'));
          await tester.pumpAndSettle();
          final selector = find.byKey(const ValueKey('appearance-mode'));
          await tester.scrollUntilVisible(
            selector,
            150,
            scrollable: find
                .descendant(
                  of: find.byKey(const ValueKey('settings-scroll')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(find.text('Light').hitTestable());
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(selector)).brightness,
            Brightness.light,
          );
          expect(app.snapshot.appearance, 'light');
          await tester.tap(find.text('Dark').hitTestable());
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(selector)).brightness,
            Brightness.dark,
          );
          await tester.tap(find.text('System').hitTestable());
          await tester.pumpAndSettle();
          tester.platformDispatcher.platformBrightnessTestValue =
              Brightness.light;
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(selector)).brightness,
            Brightness.light,
          );
          expect(app.snapshot.appearance, 'system');
          expect(app.selectedSession!.key.id, id);
          expect(app.layout.drafts[id], 'Preserve my draft');
          await tester.tap(find.byTooltip('Close settings'));
          await tester.pumpAndSettle();
          expect(find.byType(TerminalView), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await closeApp(tester, app);
        }
      },
    );
  }
  test(
    'returning before viewport conversion starts reacquires the same grid',
    () async {
      final app = await createApp();
      try {
        final id = app.sessions.first.key.id;
        app.select(id);
        app.updateViewport(id, 80, 25);
        app.overview();
        app.select(id);
        app.updateViewport(id, 80, 25);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(app.terminals[id]!.viewportControl, isTrue);
        expect(app.terminals[id]!.screen.columns, 80);
      } finally {
        await app.shutdown();
      }
    },
  );
  testWidgets('zoom changes the terminal grid to fit the available view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      app.select(app.sessions.first.key.id);
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      final before = app.terminals[app.sessions.first.key.id]!.screen.columns;
      final availableWidth = tester.getSize(find.byType(TerminalView)).width;
      await tester.tap(find.byTooltip('Larger text'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      final after = app.terminals[app.sessions.first.key.id]!.screen.columns;
      expect(after, lessThan(before));
      final terminal = find.byType(TerminalView);
      expect(tester.getSize(terminal).width, availableWidth);
      await tester.binding.setSurfaceSize(const Size(950, 840));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(
        app.terminals[app.sessions.first.key.id]!.screen.columns,
        lessThan(after),
      );
      expect(tester.getSize(terminal).width, lessThan(availableWidth));
      app.overview();
      await tester.pump();
      expect(
        app.terminals[app.sessions.first.key.id]!.viewportControl,
        isFalse,
      );
      app.select(app.sessions.first.key.id);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(app.terminals[app.sessions.first.key.id]!.viewportControl, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('long group names keep phone search and settings within reach', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      final group = app.createGroup(
        'A long project name that keeps growing across the whole phone screen',
        [],
      );
      app.setFilter('group:${group.id}');
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Cancel search').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel search'));
      await tester.pump();
      expect(
        find.byTooltip('Settings & connections').hitTestable(),
        findsOneWidget,
      );
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('phone landscape keyboard keeps the draft and Send accessible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.viewInsets = FakeViewPadding(
      bottom: 180 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pump();
      app.select(app.sessions.first.key.id);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(find.byKey(const ValueKey('toggle-composer')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        'Landscape draft\nwith another line\nand a third line',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final send = find.byKey(const ValueKey('send-draft'));
      expect(send.hitTestable(), findsOneWidget);
      await tester.tap(send);
      await tester.pump(const Duration(milliseconds: 100));
      expect(app.layout.drafts[app.sessions.first.key.id], isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('favourites shortcut works immediately after launch', (
    tester,
  ) async {
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(app.layout.filter, 'favourites');
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('star from grid then browse the favourites collection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pump(const Duration(milliseconds: 150));
      final first = app.sessions.first;
      await tester.tap(find.byKey(ValueKey('star-${first.key.id}')));
      await tester.tap(find.byKey(const ValueKey('nav-favourites')));
      await tester.pump();
      expect(app.visibleSessions.single.key.id, first.key.id);
      expect(find.text('Build navigation'), findsOneWidget);
      expect(find.text('Add search filters'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('tile opens terminal with tabs and explicit draft send', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pump(const Duration(milliseconds: 150));
      final session = app.sessions.first;
      await tester.tap(find.byKey(ValueKey('tile-${session.key.id}')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TerminalView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toggle-composer')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        'Please review the keyboard shortcuts',
      );
      await tester.pump();
      expect(app.sendStates[session.key.id]?.message, isNull);
      await tester.tap(find.byKey(const ValueKey('send-draft')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        app.terminals[session.key.id]!.screen.text,
        contains('Received locally'),
      );
      expect(app.layout.drafts[session.key.id], isNull);
      await tester.tap(find.byKey(const ValueKey('show-overview')));
      await tester.pump();
      expect(app.selectedSession, isNull);
      expect(find.byType(TerminalView), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets(
    'phone workspace picker exposes favourites and detail fits the screen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final session = app.sessions.first;
        app.toggleFavourite(session);
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byKey(const ValueKey('workspace-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Favourites').last);
        await tester.pumpAndSettle();
        expect(app.visibleSessions.single.key.id, session.key.id);
        expect(app.selectedSession?.key.id, session.key.id);
        expect(find.byType(TerminalView), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('show-overview')));
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('tile-${session.key.id}')), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    },
  );
  testWidgets('iPad sized layout remains usable with the sidebar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('nav-favourites')), findsOneWidget);
      expect(find.text('Build navigation'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
}

class _MemoryStore extends LayoutStore {
  _MemoryStore() : super('unused-widget-store');
  @override
  Future<void> save(AppSnapshot value) async {}
}
