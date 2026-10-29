import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/storage.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  for (final size in [const Size(390, 844), const Size(1200, 1000)]) {
    testWidgets(
      'dragging groups saves order without changing selection at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = await createApp();
        try {
          final ids = app.sessions.take(2).map((s) => s.key.id).toList();
          final first = app.createGroup('First', ids);
          final second = app.createGroup('Second', []);
          final third = app.createGroup('Third', []);
          app.setFilter('group:${first.id}');
          app.select(ids.first);
          await tester.pumpWidget(
            AgentSpaceApp(controller: app, desktop: size.width > 850),
          );
          await tester.pumpAndSettle();
          if (size.width < 850) {
            await tester.tap(find.byKey(const ValueKey('workspace-picker')));
            await tester.pumpAndSettle();
          }
          final handle = find.byKey(ValueKey('group-drag-${first.id}'));
          await tester.ensureVisible(handle);
          await tester.pumpAndSettle();
          final target = find.byKey(ValueKey('group-row-${third.id}'));
          final gesture = await tester.startGesture(
            tester.getCenter(handle),
            kind: size.width < 850
                ? PointerDeviceKind.touch
                : PointerDeviceKind.mouse,
          );
          await tester.pump();
          await gesture.moveTo(
            tester.getBottomLeft(target) + const Offset(25, 45),
          );
          await tester.pump(const Duration(milliseconds: 400));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(app.layout.groups.map((g) => g.id), [
            second.id,
            third.id,
            first.id,
          ]);
          expect(app.layout.filter, 'group:${first.id}');
          expect(app.layout.selectedId, ids.first);
          expect(first.sessions, ids);
          final restored = WorkspaceLayout.fromJson(app.layout.toJson());
          expect(restored.groups.map((g) => g.id), [
            second.id,
            third.id,
            first.id,
          ]);
          expect(tester.takeException(), isNull);
        } finally {
          await closeApp(tester, app);
        }
      },
    );
  }
}
