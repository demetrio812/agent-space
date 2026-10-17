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
