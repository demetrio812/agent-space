import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/terminal_pane.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  testWidgets(
    'four panels keep streams and focus separate, maximise and restore',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final ids = app.sessions.take(5).map((s) => s.key.id).toList();
        final group = app.createGroup('Together', ids);
        app.setFilter('group:${group.id}');
        app.setGroupView(GroupView.grid);
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalPane), findsNWidgets(4));
        expect(
          tester
              .widgetList<TerminalSurface>(find.byType(TerminalSurface))
              .where((s) => s.autofocus)
              .length,
          1,
        );
        final subscriptions = [
          for (final id in ids.take(4)) app.terminals[id]!.subscription,
        ];
        await tester.tap(find.text('Panel 2'));
        await tester.pumpAndSettle();
        expect(app.layout.selectedId, ids[1]);
        final focusedViews = tester
            .widgetList<TerminalView>(find.byType(TerminalView))
            .where((view) => view.focusNode!.hasFocus)
            .toList();
        expect(focusedViews, hasLength(1));
        expect(
          focusedViews.single.terminal,
          app.terminals[ids[1]]!.screen.terminal,
        );
        expect(
          tester
              .widgetList<TerminalSurface>(find.byType(TerminalSurface))
              .where((s) => s.sendInput != null)
              .length,
          1,
        );
        expect([
          for (final id in ids.take(4)) app.terminals[id]!.subscription,
        ], subscriptions);
        for (final id in ids.take(4)) {
          expect(app.terminals[id]!.viewportControl, isTrue);
        }
        app.setFilter('group:${group.id}');
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        for (final id in ids.take(4)) {
          expect(app.canResizeViewport(id), isTrue);
          expect(app.terminals[id]!.subscription, isNotNull);
        }
        await tester.runAsync(() => app.switchSource(app.source));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        for (final id in ids.take(4)) {
          expect(app.canResizeViewport(id), isTrue);
          expect(app.terminals[id]!.subscription, isNotNull);
        }
        await tester.tap(find.byKey(const ValueKey('maximize-panel-1')));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalPane), findsOneWidget);
        app.select(ids[2]);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TerminalPane>(find.byType(TerminalPane)).session.key.id,
          ids[2],
        );
        await tester.tap(find.byKey(const ValueKey('maximize-panel-2')));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalPane), findsNWidgets(4));
        app.select(ids[1]);
        app.select(ids[4]);
        await tester.pumpAndSettle();
        expect(group.panels[1], ids[4]);
        app.setGroupRatios(column: .6, row: .4);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('split-panel-0'))).width,
          greaterThan(
            tester.getSize(find.byKey(const ValueKey('split-panel-1'))).width,
          ),
        );
      } finally {
        await closeApp(tester, app);
      }
    },
  );
  testWidgets(
    'small viewport shows active session without overwriting preset or ratios',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final ids = app.sessions.take(5).map((s) => s.key.id).toList();
        final group = app.createGroup('Together', ids);
        app.setFilter('group:${group.id}');
        app.setGroupView(GroupView.grid);
        app.setGroupRatios(column: .65, row: .35);
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalPane), findsOneWidget);
        app.select(ids[4]);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TerminalPane>(find.byType(TerminalPane)).session.key.id,
          ids[4],
        );
        expect(group.view, GroupView.grid);
        expect(group.columnRatio, .65);
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalPane), findsNWidgets(4));
      } finally {
        await closeApp(tester, app);
      }
    },
  );
}
