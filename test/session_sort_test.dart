import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/storage.dart';

import 'fixtures/network_fixture.dart';

void main() {
  late Directory directory;
  late AppController app;
  late NetworkFixture fixture;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sort-test-');
    fixture = NetworkFixture();
    fixture.initial = [
      fixture.session(
        machine: fixtureMachineA,
        label: 'Zebra',
        workspace: 'w1',
      ),
      fixture.session(
        machine: fixtureMachineB,
        label: 'Alpha',
        workspace: 'w2',
      ),
    ];
    app = fixture.controller(directory);
    await app.start(polling: false);
  });
  tearDown(() async {
    await app.shutdown();
    await directory.delete(recursive: true);
  });
  test('Recent shows only opened sessions, newest first, without changing other sorts', () async {
    final a = fixture.initial.first, b = fixture.initial.last;
    app.setFilter('recent');
    expect(app.visibleSessions, isEmpty);
    app.select(a.key.id);
    app.select(b.key.id);
    app.select(a.key.id);
    app.overview();
    app.setGridSort(SessionSort.name);
    expect(app.visibleSessions, [a, b]);
    expect(app.filterLabel, 'Recent');
    expect(app.selectedComputerId, isNull);
    expect(app.canReorderGrid, isFalse);
    app.reorderGridSession(a.key.id, b.key.id);
    app.reorderTabs(0, 1);
    expect(app.sessionsForFilter('recent'), [a, b]);
    await app.refresh();
    expect(app.visibleSessions, [a, b]);
    app.setSearch('Alpha');
    expect(app.visibleSessions, [b]);
    app.setSearch('');
    final restored = AppSnapshot.fromJson(app.snapshot.toJson());
    final other = fixture.controller(directory, snapshot: restored);
    await other.start(polling: false);
    expect(other.layout.filter, 'recent');
    expect(other.visibleSessions.map((s) => s.key.id), [a.key.id, b.key.id]);
    await other.shutdown();
    expect(app.layout.gridSort, SessionSort.name);
    // A closed session must not be resurrected from retained/favourite metadata.
    app.toggleFavourite(a);
    app.sessions = [b];
    expect(app.visibleSessions, [b]);
    app.setFilter('all');
    expect(app.visibleSessions, [b]);
  });
  test(
    'sorts grid while retaining filters and saved custom favourite order',
    () {
      final a = fixture.initial.first, b = fixture.initial.last;
      app.toggleFavourite(a);
      app.toggleFavourite(b);
      app.setFilter('favourites');
      app.layout.favouriteOrder
        ..clear()
        ..addAll([a.key.id, b.key.id]);
      app.setGridSort(SessionSort.name);
      expect(app.visibleSessions, [b, a]);
      app.setGridSort(SessionSort.computer);
      expect(app.visibleSessions, [b, a]);
      app.select(a.key.id);
      app.select(b.key.id);
      app.select(a.key.id);
      app.setGridSort(SessionSort.recent);
      expect(app.visibleSessions, [a, b]);
      app.setFilter('computer:${b.computerId}');
      expect(app.visibleSessions, [b]);
      app.setFilter('favourites');
      app.setGridSort(SessionSort.custom);
      expect(app.visibleSessions, [a, b]);
      expect(app.layout.favouriteOrder, [a.key.id, b.key.id]);
      app.setGridSort(SessionSort.name);
      app.reorderFavourite(b.key.id, a.key.id);
      expect(app.layout.gridSort, SessionSort.custom);
      expect(app.visibleSessions, [a, b]);
    },
  );
  test(
    'status prioritizes waiting sessions and workspace sorts alphabetically',
    () {
      SessionInfo withStatus(
        SessionInfo original,
        SessionStatus status,
        String workspace,
      ) => SessionInfo(
        key: original.key,
        origin: original.origin,
        paneId: original.paneId,
        title: original.title,
        project: original.project,
        agent: original.agent,
        status: status,
        workspaceId: original.workspaceId,
        workspaceLabel: workspace,
      );
      final a = withStatus(
        fixture.initial.first,
        SessionStatus.needsInput,
        'Zoo',
      );
      final b = withStatus(
        fixture.initial.last,
        SessionStatus.working,
        'Alpha',
      );
      app.sessions = [b, a];
      app.setGridSort(SessionSort.status);
      expect(app.visibleSessions, [a, b]);
      app.setGridSort(SessionSort.workspace);
      expect(app.visibleSessions, [b, a]);
      app.setSearch('Zebra');
      expect(app.visibleSessions, [a]);
    },
  );
  test(
    'status puts idle below completed, working and needs-input sessions',
    () {
      app.sessions = [
        for (final status in SessionStatus.values)
          SessionInfo(
            key: SessionKey('demo', 'demo', 'server', status.name),
            paneId: status.name,
            title: status.name,
            project: '',
            agent: '',
            status: status,
          ),
      ];
      app.setGridSort(SessionSort.status);
      expect(app.visibleSessions.map((s) => s.status), [
        SessionStatus.needsInput,
        SessionStatus.working,
        SessionStatus.done,
        SessionStatus.idle,
        SessionStatus.unknown,
      ]);
    },
  );
  test('custom grid drag preserves hidden computer and search ordering', () {
    final a = fixture.initial.first, b = fixture.initial.last;
    final c = fixture.session(
      machine: fixtureMachineA,
      terminal: 't2',
      label: 'Zebra',
      workspace: 'w1',
    );
    app.sessions = [a, b, c];
    app.layout.tabOrder.addAll([a.key.id, b.key.id, c.key.id]);
    app.setFilter('computer:${a.computerId}');
    app.reorderGridSession(a.key.id, c.key.id);
    expect(app.visibleSessions, [c, a]);
    app.setFilter('all');
    expect(app.visibleSessions, [c, b, a]);
    app.setSearch('Zebra');
    app.reorderGridSession(c.key.id, a.key.id);
    app.setSearch('');
    expect(app.visibleSessions, [a, b, c]);
    final restored = WorkspaceLayout.fromJson(app.layout.toJson());
    expect(restored.tabOrder, [a.key.id, b.key.id, c.key.id]);
    app.setFilter(a.workspaceFilterId);
    app.reorderGridSession(a.key.id, c.key.id);
    expect(app.visibleSessions, [c, a]);
    app.layout.groups.add(
      TabGroup('test', 'Test', [a.key.id, b.key.id, c.key.id]),
    );
    app.setFilter('group:test');
    app.reorderGridSession(a.key.id, c.key.id);
    expect(app.visibleSessions, [b, c, a]);
    expect(app.layout.tabOrder, [c.key.id, b.key.id, a.key.id]);
  });
  test(
    'sorting and recent session order survive saving with safe defaults',
    () {
      app.select(fixture.initial.first.key.id);
      app.setGridSort(SessionSort.workspace);
      final restored = WorkspaceLayout.fromJson(app.layout.toJson());
      expect(restored.gridSort, SessionSort.workspace);
      expect(restored.recentSessions, [fixture.initial.first.key.id]);
      expect(
        WorkspaceLayout.fromJson({'gridSort': 'unknown'}).gridSort,
        SessionSort.custom,
      );
      expect(
        WorkspaceLayout.fromJson({
          'recentSessions': ['invalid'],
        }).recentSessions,
        isEmpty,
      );
    },
  );
}
