import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/app.dart';

import 'app_widget_test.dart' show createApp, closeApp;

Future<void> moveItem(
  WidgetTester tester,
  Finder source,
  Offset destination,
  PointerDeviceKind kind,
) async {
  final gesture = await tester.createGesture(kind: kind);
  await gesture.down(tester.getCenter(source));
  if (kind == PointerDeviceKind.touch) {
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  }
  await gesture.moveBy(const Offset(24, 0));
  await tester.pump();
  await gesture.moveTo(destination);
  await tester.pump(const Duration(milliseconds: 300));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'grid drag auto-scrolls at edge and ordinary touch still scrolls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        for (final session in app.sessions) {
          app.toggleFavourite(session);
        }
        app.setFilter('favourites');
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pumpAndSettle();
        final grid = find.byType(GridView);
        final state = tester.state<ScrollableState>(
          find.descendant(of: grid, matching: find.byType(Scrollable)).first,
        );
        await tester.drag(grid, const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(state.position.pixels, greaterThan(0));
        state.position.jumpTo(0);
        await tester.pump();
        final first = find.byKey(
          ValueKey('tile-${app.visibleSessions.first.key.id}'),
        );
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.down(tester.getCenter(first));
        await gesture.moveBy(const Offset(24, 0));
        await tester.pump();
        final bounds = tester.getRect(grid);
        await gesture.moveTo(Offset(bounds.center.dx, bounds.bottom - 5));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(state.position.pixels, greaterThan(0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    },
  );
  testWidgets('long grid drag stops scrolling after leaving the edge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      for (final session in app.sessions) {
        app.toggleFavourite(session);
      }
      app.setFilter('favourites');
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pumpAndSettle();
      final grid = find.byType(GridView);
      final state = tester.state<ScrollableState>(
        find.descendant(of: grid, matching: find.byType(Scrollable)).first,
      );
      final first = find.byKey(
        ValueKey('tile-${app.visibleSessions.first.key.id}'),
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.down(tester.getCenter(first));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      final bounds = tester.getRect(grid);
      await gesture.moveTo(Offset(bounds.center.dx, bounds.bottom - 5));
      await tester.pump();
      for (var frame = 0; frame < 65; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.position.pixels, greaterThan(1000));
      expect(state.position.pixels, lessThan(state.position.maxScrollExtent));
      await gesture.moveTo(bounds.center);
      await tester.pump(const Duration(milliseconds: 200));
      final stoppedAt = state.position.pixels;
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.position.pixels, stoppedAt);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });

  testWidgets('horizontal favourites drag scrolls at the far edge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = await createApp();
    try {
      for (final session in app.sessions) {
        app.toggleFavourite(session);
      }
      app.setFilter('favourites');
      final id = app.visibleSessions.first.key.id;
      app.select(id);
      await tester.pumpWidget(AgentSpaceApp(controller: app));
      await tester.pumpAndSettle();
      final strip = find.byWidgetPredicate(
        (widget) =>
            widget is ReorderableListView &&
            widget.scrollDirection == Axis.horizontal,
      );
      final state = tester.state<ScrollableState>(
        find.descendant(of: strip, matching: find.byType(Scrollable)).first,
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.down(tester.getCenter(find.byKey(ValueKey('tab-$id'))));
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      final bounds = tester.getRect(strip);
      await gesture.moveTo(Offset(bounds.right - 5, bounds.center.dy));
      await tester.pump();
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.position.pixels, greaterThan(500));
      await gesture.moveTo(bounds.center);
      await tester.pump(const Duration(milliseconds: 200));
      final stoppedAt = state.position.pixels;
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(state.position.pixels, stoppedAt);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(app.layout.selectedId, id);
      expect(tester.takeException(), isNull);
    } finally {
      await closeApp(tester, app);
    }
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    final size = kind == PointerDeviceKind.mouse
        ? const Size(1200, 800)
        : const Size(390, 844);
    testWidgets('custom All sessions grid drag reorders using $kind', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        app.setFilter('all');
        final ids = app.visibleSessions.map((s) => s.key.id).toList();
        await tester.pumpWidget(
          AgentSpaceApp(
            controller: app,
            desktop: kind == PointerDeviceKind.mouse,
          ),
        );
        await tester.pumpAndSettle();
        await moveItem(
          tester,
          find.byKey(ValueKey('tile-${ids[0]}')),
          tester.getCenter(find.byKey(ValueKey('tile-${ids[1]}'))) +
              const Offset(48, 0),
          kind,
        );
        expect(app.visibleSessions.map((s) => s.key.id), [
          ids[1],
          ids[0],
          ...ids.skip(2),
        ]);
        expect(app.layout.selectedId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
    testWidgets('favourite grid drag reorders using $kind', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        for (final session in app.sessions.take(3)) {
          app.toggleFavourite(session);
        }
        app.setFilter('favourites');
        final ids = app.visibleSessions.map((s) => s.key.id).toList();
        await tester.pumpWidget(
          AgentSpaceApp(
            controller: app,
            desktop: kind == PointerDeviceKind.mouse,
          ),
        );
        await tester.pumpAndSettle();
        final first = find.byKey(ValueKey('tile-${ids[0]}')),
            second = find.byKey(ValueKey('tile-${ids[1]}'));
        await moveItem(
          tester,
          first,
          tester.getCenter(second) + const Offset(48, 0),
          kind,
        );
        expect(app.visibleSessions.map((s) => s.key.id), [
          ids[1],
          ids[0],
          ids[2],
        ]);
        expect(
          tester.getTopLeft(find.byKey(ValueKey('tile-${ids[1]}'))).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byKey(ValueKey('tile-${ids[0]}'))).dy,
          ),
        );
        expect(app.layout.selectedId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
    testWidgets('favourite strip drag keeps open terminal using $kind', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        for (final session in app.sessions.take(3)) {
          app.toggleFavourite(session);
        }
        app.setFilter('favourites');
        final ids = app.visibleSessions.map((s) => s.key.id).toList();
        app.select(ids.first);
        final terminal = app.terminals[ids.first];
        await tester.pumpWidget(
          AgentSpaceApp(
            controller: app,
            desktop: kind == PointerDeviceKind.mouse,
          ),
        );
        await tester.pumpAndSettle();
        final first = find.byKey(ValueKey('tab-${ids[0]}')),
            second = find.byKey(ValueKey('tab-${ids[1]}'));
        await moveItem(
          tester,
          kind == PointerDeviceKind.mouse ? first : second,
          kind == PointerDeviceKind.mouse
              ? tester.getTopRight(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is ReorderableListView &&
                            widget.scrollDirection == Axis.horizontal,
                      ),
                    ) +
                    const Offset(-12, 20)
              : tester.getCenter(first) + const Offset(48, 0),
          kind,
        );
        expect(
          app.visibleSessions.map((s) => s.key.id),
          kind == PointerDeviceKind.mouse
              ? [ids[1], ids[2], ids[0]]
              : [ids[1], ids[0], ids[2]],
        );
        expect(app.layout.selectedId, ids.first);
        expect(identical(app.terminals[ids.first], terminal), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
  }
}
