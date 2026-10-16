import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/session_actions_ui.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  testWidgets(
    'right click and three dot menu share rename and close; cancelling preserves terminal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        final session = app.visibleSessions.first;
        await tester.tapAt(
          tester.getCenter(find.byKey(ValueKey('tile-${session.key.id}'))),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('Close terminal…'), findsOneWidget);
        await tester.tap(find.text('Close terminal…'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('ends the running terminal'),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('Demo computer'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(app.sessionById(session.key.id)!.available, true);
        await tester.tap(
          find.byKey(ValueKey('session-menu-${session.key.id}')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Rename'), findsOneWidget);
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('session-title')),
          'Cancelled name',
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(app.sessionById(session.key.id)!.title, session.title);
      } finally {
        await closeApp(tester, app);
      }
    },
  );
  testWidgets(
    'rename keeps favourite order and close leaves an unavailable bookmark',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final a = app.sessions.first, b = app.sessions[1];
        app.toggleFavourite(a);
        app.toggleFavourite(b);
        app.setFilter('favourites');
        final order = List.of(app.layout.favouriteOrder);
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('session-menu-${a.key.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('session-title')),
          'Renamed favourite',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
        await tester.pumpAndSettle();
        expect(app.sessionById(a.key.id)!.title, 'Renamed favourite');
        expect(app.layout.favouriteOrder, order);
        await tester.tap(find.byKey(ValueKey('session-menu-${a.key.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close terminal…'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Close terminal'));
        await tester.pumpAndSettle();
        expect(app.layout.favourites[a.key.id]!.available, false);
        expect(app.layout.favouriteOrder, order);
      } finally {
        await closeApp(tester, app);
      }
    },
  );
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1200, 800),
  ]) {
    for (final appearance in ['light', 'dark']) {
      testWidgets(
        'new shell dialog fits $size $appearance and selects returned session',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final app = await createApp();
          app.snapshot.appearance = appearance;
          try {
            await tester.pumpWidget(
              AgentSpaceApp(controller: app, desktop: size.width > 1000),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('New session').first);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('new-session-computer')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('new-session-workspace')),
              findsOneWidget,
            );
            await tester.enterText(
              find.byKey(const ValueKey('session-title')),
              'Disposable shell',
            );
            await tester.enterText(
              find.byKey(const ValueKey('session-folder')),
              '~/project',
            );
            await tester.ensureVisible(
              find.widgetWithText(FilledButton, 'Create session'),
            );
            await tester.tap(
              find.widgetWithText(FilledButton, 'Create session'),
            );
            await tester.pumpAndSettle();
            expect(app.selectedSession!.title, 'Disposable shell');
            expect(app.selectedSession!.agent, 'terminal');
            expect(app.selectedSession!.key.terminal, startsWith('created-'));
            expect(tester.takeException(), isNull);
          } finally {
            await closeApp(tester, app);
          }
        },
      );
    }
  }
  testWidgets(
    'uncertain action inspection is explicit and leaves keyboard warnings alone',
    (tester) async {
      final app = await createApp();
      try {
        final origin = app.computers.first.origin;
        app.layout.uncertainActions[origin.computerId] = SessionActionRecord(
          'create',
          origin,
        );
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Check unconfirmed session action'));
        await tester.pumpAndSettle();
        expect(find.textContaining('may have completed'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(app.layout.uncertainActions, isNotEmpty);
        await tester.tap(find.byTooltip('Check unconfirmed session action'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('I’ve checked'));
        await tester.pumpAndSettle();
        expect(app.layout.uncertainActions, isEmpty);
      } finally {
        await closeApp(tester, app);
      }
    },
  );
  testWidgets('source change invalidates an open creation dialog', (
    tester,
  ) async {
    final app = await createApp();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(showCreateSession(context, app));
      await tester.pumpAndSettle();
      await tester.runAsync(() => app.switchSource('other'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create session'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('unsupported connections disable real terminal actions', (
    tester,
  ) async {
    final app = await createApp();
    app.computers = [
      for (final c in app.computers)
        ComputerInfo(origin: c.origin, state: c.state),
    ];
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pumpAndSettle();
      final id = app.visibleSessions.first.key.id;
      await tester.tap(find.byKey(ValueKey('session-menu-$id')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Rename'),
            )
            .enabled,
        false,
      );
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Close terminal…'),
            )
            .enabled,
        false,
      );
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets('landscape creation stays usable above the onscreen keyboard', (
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
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New session').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final button = find.widgetWithText(FilledButton, 'Create session');
      expect(button.hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets(
    'changing computer clears folder and workspace; retargeting prevents create',
    (tester) async {
      final app = await createApp();
      final first = app.computers.single;
      final other = SessionOrigin(
        profile: 'demo',
        machineId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        machineLabel: 'Other computer',
        herdrSession: 'default',
        targetHash: first.origin.targetHash,
        generation: first.origin.generation,
      );
      app.computers = [
        first,
        ComputerInfo(
          origin: other,
          state: ComputerState.live,
          managementEnabled: true,
          workspaces: const [SessionWorkspace('w2', 'Remote workspace')],
        ),
      ];
      try {
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('New session').first);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('session-folder')),
          '~/old',
        );
        await tester.tap(find.byKey(const ValueKey('new-session-computer')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Other computer').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('session-folder')))
              .controller!
              .text,
          isEmpty,
        );
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.byKey(const ValueKey('new-session-workspace')),
              )
              .value,
          isNull,
        );
        final submit = find.widgetWithText(FilledButton, 'Create session');
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        await tester.tap(find.byKey(const ValueKey('new-session-workspace')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remote workspace').last);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
        final changed = SessionOrigin(
          profile: other.profile,
          machineId: other.machineId,
          machineLabel: other.machineLabel,
          herdrSession: other.herdrSession,
          targetHash: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          generation: other.generation,
        );
        app.computers = [
          first,
          ComputerInfo(
            origin: changed,
            state: ComputerState.live,
            managementEnabled: true,
            workspaces: const [SessionWorkspace('w2', 'Remote workspace')],
          ),
        ];
        app.setSearch('refresh');
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(submit).onPressed, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    },
  );
}
