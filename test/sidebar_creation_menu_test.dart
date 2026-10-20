import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1200, 800),
  ]) {
    testWidgets('compact sidebar creation menu routes actions at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        await tester.pumpWidget(
          AgentSpaceApp(controller: app, desktop: size.width >= 850),
        );
        await tester.pumpAndSettle();
        Future<void> openSidebar() async {
          if (size.width < 850) {
            await tester.tap(find.byKey(const ValueKey('workspace-picker')));
            await tester.pumpAndSettle();
          }
        }

        for (final action in ['New session', 'New workspace', 'New group']) {
          await openSidebar();
          final create = find.byKey(const ValueKey('sidebar-new'));
          final settings = find.byKey(const ValueKey('sidebar-settings'));
          expect(find.text('New session'), findsNothing);
          expect(find.text('New workspace'), findsNothing);
          expect(find.text('New group'), findsNothing);
          expect(find.text('Settings'), findsNothing);
          expect(
            tester.getCenter(create).dy,
            closeTo(tester.getCenter(settings).dy, 1),
          );
          expect(
            tester.getCenter(settings).dx,
            greaterThan(tester.getCenter(create).dx),
          );
          await tester.tap(create);
          await tester.pumpAndSettle();
          await tester.tap(find.text(action));
          await tester.pumpAndSettle();
          expect(find.widgetWithText(AlertDialog, action), findsOneWidget);
          expect(find.byTooltip('Close sidebar'), findsNothing);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
        await openSidebar();
        await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byTooltip('Close sidebar'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
  }
}
