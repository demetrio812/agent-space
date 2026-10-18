import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(1024, 768),
    const Size(1200, 800),
  ]) {
    testWidgets('group menu renames and deletes only the group at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final session = app.sessions.first;
        app.toggleFavourite(session);
        app.updateDraft(session.key.id, 'Keep my draft');
        final group = app.createGroup('Review', [session.key.id]);
        app.setFilter('group:${group.id}');
        await tester.pumpWidget(
          AgentSpaceApp(controller: app, desktop: size.width == 1200),
        );
        await tester.pumpAndSettle();
        if (size.width < 700) {
          await tester.tap(find.byKey(const ValueKey('workspace-picker')));
          await tester.pumpAndSettle();
        }
        final menu = find.byKey(ValueKey('group-menu-${group.id}'));
        await tester.ensureVisible(menu);
        await tester.pumpAndSettle();
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('group-name')))
              .controller!
              .text,
          'Review',
        );
        await tester.enterText(
          find.byKey(const ValueKey('group-name')),
          'Cancelled',
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(group.name, 'Review');
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('group-name')), '   ');
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const ValueKey('group-name')),
          '  Focus  ',
        );
        await tester.pump();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(group.name, 'Focus');
        expect(group.sessions, [session.key.id]);
        expect(app.filterLabel, 'Focus');
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete group…'));
        await tester.pumpAndSettle();
        expect(find.textContaining('keep running'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(app.layout.groups, contains(group));
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete group…'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Delete group'));
        await tester.pumpAndSettle();
        expect(app.layout.groups, isEmpty);
        expect(app.layout.filter, 'all');
        expect(app.sessionById(session.key.id)!.available, isTrue);
        expect(app.layout.favourites, contains(session.key.id));
        expect(app.layout.drafts[session.key.id], 'Keep my draft');
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
  }
  testWidgets(
    'right click opens group actions without changing the selected view',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        final group = app.createGroup('Review', []);
        await tester.pumpWidget(AgentSpaceApp(controller: app));
        await tester.pumpAndSettle();
        final row = find.byKey(ValueKey('group-row-${group.id}'));
        await tester.ensureVisible(row);
        await tester.tapAt(
          tester.getCenter(row),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('Rename'), findsOneWidget);
        expect(find.text('Delete group…'), findsOneWidget);
        expect(app.layout.filter, 'all');
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('group-name')),
          'From context menu',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(group.name, 'From context menu');
      } finally {
        await closeApp(tester, app);
      }
    },
  );
}
