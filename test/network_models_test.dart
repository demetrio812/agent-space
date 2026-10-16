import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/storage.dart';

import 'fixtures/network_fixture.dart';

void main() {
  test('scoped filter identifiers fit persisted bounds even for long workspace IDs', () {
    final session = NetworkFixture().session(
      machine: fixtureMachineA,
      workspace: List.filled(500, 'w').join(),
    );
    final layout = WorkspaceLayout()..filter = session.workspaceFilterId;
    expect(
      WorkspaceLayout.fromJson(layout.toJson()).filter,
      session.workspaceFilterId,
    );
    expect(
      WorkspaceLayout.fromJson({'filter': 'computer:--bad'}).filter,
      'all',
    );
    expect(
      WorkspaceLayout.fromJson({'filter': 'workspace:--bad'}).filter,
      'all',
    );
  });
  test('colliding peer terminal and workspace IDs are distinct', () {
    final fixture = NetworkFixture();
    final a = fixture.session(machine: fixtureMachineA);
    final b = fixture.session(machine: fixtureMachineB);
    expect(a.key.id, isNot(b.key.id));
    expect(a.workspaceFilterId, isNot(b.workspaceFilterId));
    expect(a.computerId, isNot(b.computerId));
    final restored = SessionInfo.fromJson(a.toJson())!;
    expect(restored.origin!.machineId, fixtureMachineA);
    expect(restored.inputEnabled, false);
    expect(restored.available, false);
  });
  test('gateway identity and saved favourites drafts groups markers remain unchanged', () {
    final gateway = NetworkFixture().session(
      machine: 'gateway',
      label: 'Gateway',
    );
    final old = SessionKey('herdr', 'remote', fixtureGeneration, 't1');
    expect(gateway.key.id, old.id);
    final layout = WorkspaceLayout()
      ..selectedId = old.id
      ..filter = 'w1';
    layout.favourites[old.id] = SessionInfo(
      key: old,
      paneId: 'p1',
      title: 'Old',
      project: 'project',
      agent: 'terminal',
      status: SessionStatus.idle,
      workspaceId: 'w1',
    );
    layout.retained.addAll(layout.favourites);
    layout.drafts[old.id] = 'unfinished';
    layout.uncertainDeliveries.add(old.id);
    layout.groups.add(TabGroup('group1', 'Group', [old.id]));
    layout.tabOrder.add(old.id);
    final restored = WorkspaceLayout.fromJson(layout.toJson());
    expect(restored.favourites.keys, [old.id]);
    expect(restored.selectedId, old.id);
    expect(restored.drafts[old.id], 'unfinished');
    expect(restored.uncertainDeliveries, {old.id});
    expect(restored.groups.single.sessions, [old.id]);
    expect(restored.tabOrder, [old.id]);
  });
  test('labels do not route, while retarget or named session changes invalidate peer identity', () {
    final f = NetworkFixture();
    final old = f.session(machine: fixtureMachineA, label: 'Old');
    expect(f.session(machine: fixtureMachineA, label: 'Renamed').key, old.key);
    expect(
      f.session(machine: fixtureMachineA, targetHash: fixtureGeneration).key,
      isNot(old.key),
    );
    expect(
      f.session(machine: fixtureMachineA, herdrSession: 'work').key,
      isNot(old.key),
    );
  });
  test(
    'malformed or mismatched stored origin cannot become an input target',
    () {
      final s = NetworkFixture().session(machine: fixtureMachineA);
      final json = s.toJson();
      (json['origin'] as Map)['machineId'] = fixtureMachineB;
      expect(SessionInfo.fromJson(json), isNull);
      expect(
        SessionOrigin.fromJson({'profile': 'remote', 'machineId': '--evil'}),
        isNull,
      );
    },
  );
}
