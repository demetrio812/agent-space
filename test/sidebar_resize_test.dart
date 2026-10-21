import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/storage.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  testWidgets('sidebar drag persists, clamps on resize and resets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      app.select(app.sessions.first.key.id);
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pumpAndSettle();
      final sidebar = find.byKey(const ValueKey('persistent-sidebar'));
      final handle = find.byKey(const ValueKey('sidebar-resize'));
      expect(tester.getSize(sidebar).width, 208);
      await tester.drag(handle, const Offset(180, 0));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, greaterThan(350));
      final saved = AppSnapshot.fromJson(app.snapshot.toJson());
      expect(saved.sidebarWidth, app.snapshot.sidebarWidth);
      await tester.binding.setSurfaceSize(const Size(850, 600));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 208);
      expect(app.snapshot.sidebarWidth, saved.sidebarWidth);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, saved.sidebarWidth);
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 208);
    } finally {
      await closeApp(tester, app);
    }
  });
  test('saved sidebar widths reject invalid values and clamp bounds', () {
    for (final value in ['wide', -1, 0, 99999, double.nan]) {
      final snapshot = AppSnapshot.fromJson({
        'version': 1,
        'sidebarWidth': value,
      });
      expect(snapshot.sidebarWidth, inInclusiveRange(208, 520));
    }
  });
}
