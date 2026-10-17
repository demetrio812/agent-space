import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/session_drag.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(1024, 768),
    const Size(1440, 900),
  ]) {
    testWidgets('Recent navigation, origins and fixed order at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pumpAndSettle();
        final picker = find.byKey(const ValueKey('workspace-picker'));
        if (picker.evaluate().isNotEmpty) {
          await tester.tap(picker);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const ValueKey('nav-recent')));
        await tester.pumpAndSettle();
        expect(app.layout.filter, 'recent');
        expect(find.text('No recent sessions'), findsOneWidget);
        expect(find.byTooltip('Close sidebar'), findsNothing);
        expect(find.byTooltip('Sort sessions'), findsNothing);
        final a = app.sessions.first, b = app.sessions.last;
        app.select(a.key.id);
        app.select(b.key.id);
        app.overview();
        await tester.pumpAndSettle();
        final tile = find.byKey(ValueKey('tile-${b.key.id}'));
        expect(tile, findsOneWidget);
        final location =
            '${app.computerLabel(b.computerId, origin: b.origin)} · ${b.workspaceLabel.isEmpty ? b.project : b.workspaceLabel}';
        expect(
          find.descendant(of: tile, matching: find.text(location)),
          findsOneWidget,
        );
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(app.selectedSession?.key, b.key);
        expect(
          tester
              .widgetList<SessionReorderStart>(find.byType(SessionReorderStart))
              .every((tab) => !tab.enabled),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
  }
}
