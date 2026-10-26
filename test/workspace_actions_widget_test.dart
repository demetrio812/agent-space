import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/network_models.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  for (final size in [const Size(390, 844), const Size(1200, 800)]) {
    testWidgets(
      'favourite workspaces stay visible across computer selection at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = await createApp();
        try {
          final computer = app.computers.first;
          final workspace = computer.workspaces.last;
          final id = scopedWorkspaceId(computer.origin, workspace.id);
          app.setFilter('computer:${computer.origin.computerId}');
          await tester.pumpWidget(
            AgentSpaceApp(controller: app, desktop: size.width > 700),
          );
          await tester.pumpAndSettle();
          if (size.width < 700) {
            await tester.tap(find.byKey(const ValueKey('workspace-picker')));
            await tester.pumpAndSettle();
          }
          final menu = find.byKey(ValueKey('workspace-menu-$id'));
          await tester.ensureVisible(menu);
          await tester.tap(menu);
          await tester.pumpAndSettle();
          expect(find.text('Add to favourites'), findsOneWidget);
          await tester.tap(find.text('Add to favourites'));
          await tester.pumpAndSettle();
          app.setFilter('all');
          await tester.pumpAndSettle();
          final pinned = find.byKey(ValueKey('favourite-workspace-$id'));
          expect(pinned, findsOneWidget);
          expect(
            find.descendant(of: pinned, matching: find.byIcon(Icons.star)),
            findsOneWidget,
          );
          expect(
            tester.getTopLeft(pinned).dy,
            lessThan(tester.getTopLeft(find.text('Computers')).dy),
          );
          await tester.tap(pinned);
          await tester.pumpAndSettle();
          expect(app.layout.filter, id);
          expect(app.selectedComputerId, computer.origin.computerId);
          if (size.width < 700) {
            await tester.tap(find.byKey(const ValueKey('workspace-picker')));
            await tester.pumpAndSettle();
          }
          await tester.tap(
            find.byKey(ValueKey('favourite-workspace-menu-$id')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Remove from favourites'));
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('favourite-workspace-$id')), findsNothing);
          expect(app.layout.filter, id);
          expect(tester.takeException(), isNull);
        } finally {
          await closeApp(tester, app);
        }
      },
    );
    testWidgets('workspace sidebar rename and confirmed close at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final computer = app.computers.first,
            workspace = app.computers.first.workspaces.first;
        final id = scopedWorkspaceId(computer.origin, workspace.id);
        final session = app.sessions.first;
        app.toggleFavourite(session);
        app.toggleWorkspaceFavourite(id);
        app.setFilter(id);
        await tester.pumpWidget(
          AgentSpaceApp(controller: app, desktop: size.width > 700),
        );
        await tester.pumpAndSettle();
        if (size.width < 700) {
          await tester.tap(find.byKey(const ValueKey('workspace-picker')));
          await tester.pumpAndSettle();
        }
        final menu = find.byKey(ValueKey('workspace-menu-$id'));
        await tester.scrollUntilVisible(
          menu,
          100,
          scrollable: find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        if (size.width > 700) {
          await tester.tapAt(
            tester.getCenter(find.byKey(ValueKey('workspace-row-$id'))),
            buttons: kSecondaryMouseButton,
          );
        } else {
          await tester.tap(menu);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('workspace-name')),
          'Renamed workspace',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(app.workspaceTarget(id)!.$2.label, 'Renamed workspace');
        expect(app.isWorkspaceFavourite(id), isTrue);
        expect(app.favouriteWorkspaces[id], startsWith('Renamed workspace · '));
        expect(
          app.sessions
              .where((s) => s.workspaceId == workspace.id)
              .every((s) => s.workspaceLabel == 'Renamed workspace'),
          true,
        );
        expect(app.layout.filter, id);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close workspace…'));
        await tester.pumpAndSettle();
        expect(find.textContaining('running processes'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(app.workspaceTarget(id), isNotNull);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close workspace…'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Close workspace'));
        await tester.pumpAndSettle();
        expect(app.workspaceTarget(id), isNull);
        expect(app.isWorkspaceFavourite(id), isFalse);
        expect(app.favouriteWorkspaces, isEmpty);
        expect(app.sessions.any((s) => s.workspaceId == workspace.id), false);
        expect(app.layout.favourites[session.key.id]!.available, false);
        expect(app.layout.filter, 'computer:${computer.origin.computerId}');
        expect(app.sessions, isNotEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
  }
}
