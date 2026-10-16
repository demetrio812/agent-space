import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';

import 'controller_test.dart' show FakeBackend, item;

void main() {
  late Directory directory;
  late FakeBackend backend;
  late AppController app;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('favourite-order-');
    backend = FakeBackend('demo', [
      item('visible-one'),
      item('hidden'),
      item('visible-two'),
    ]);
    app = AppController(
      snapshot: AppSnapshot(),
      store: LayoutStore(directory.path),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
    for (final session in backend.sessions) {
      app.toggleFavourite(session);
    }
  });
  tearDown(() async {
    await app.shutdown();
    await directory.delete(recursive: true);
  });
  test(
    'favourite order persists without changing all sessions or selection',
    () async {
      final allBefore = app
          .sessionsForFilter('all')
          .map((s) => s.key.id)
          .toList();
      app.setFilter('favourites');
      final before = app.visibleSessions.map((s) => s.key.id).toList();
      app.select(before.first);
      final terminal = app.terminals[before.first];
      app.reorderTabs(0, 2);
      expect(app.visibleSessions.map((s) => s.key.id), [
        before[1],
        before[2],
        before[0],
      ]);
      expect(app.sessionsForFilter('all').map((s) => s.key.id), allBefore);
      expect(app.layout.selectedId, before.first);
      expect(identical(app.terminals[before.first], terminal), isTrue);
      final restored = AppController(
        snapshot: AppSnapshot.fromJson(app.snapshot.toJson()),
        store: LayoutStore(directory.path),
        backendFactory: (_) => backend,
      );
      expect(restored.visibleSessions.map((s) => s.key.id), [
        before[1],
        before[2],
        before[0],
      ]);
      await restored.shutdown();
    },
  );
  test('filtered favourite drag leaves hidden positions unchanged', () {
    final one = backend.sessions[0].key.id,
        hidden = backend.sessions[1].key.id,
        two = backend.sessions[2].key.id;
    app.setFilter('favourites');
    app.setSearch('visible');
    app.reorderFavourite(one, two);
    expect(app.visibleSessions.map((s) => s.key.id), [two, one]);
    expect(app.sessionsForFilter('favourites').map((s) => s.key.id), [
      two,
      hidden,
      one,
    ]);
  });
  test('removed favourite cannot be reordered back by a stale drag', () {
    app.setFilter('favourites');
    final one = backend.sessions[0], two = backend.sessions[2];
    app.toggleFavourite(one);
    final before = app.visibleSessions.map((s) => s.key.id).toList();
    app.reorderFavourite(one.key.id, two.key.id);
    expect(app.visibleSessions.map((s) => s.key.id), before);
    expect(app.isFavourite(one.key.id), false);
  });
  test('legacy displayed order migrates and new favourites append', () {
    app.layout.tabOrder.addAll(backend.sessions.reversed.map((s) => s.key.id));
    app.layout.favouriteOrder.clear();
    final legacy = app
        .sessionsForFilter('favourites')
        .map((s) => s.key.id)
        .toList();
    app.setFilter('favourites');
    app.reorderTabs(0, 1);
    expect(app.visibleSessions.map((s) => s.key.id), [
      legacy[1],
      legacy[0],
      legacy[2],
    ]);
    final extra = item('new');
    app.sessions.add(extra);
    app.toggleFavourite(extra);
    expect(app.visibleSessions.last.key.id, extra.key.id);
    app.toggleFavourite(extra);
    expect(app.visibleSessions.map((s) => s.key.id), [
      legacy[1],
      legacy[0],
      legacy[2],
    ]);
  });
}
