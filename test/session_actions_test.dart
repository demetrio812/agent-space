import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/demo_backend.dart';
import 'package:agentspace/src/bridge_protocol.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/network_backend.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/persistent_bridge.dart';
import 'package:agentspace/src/storage.dart';

import 'fixtures/fake_bridge.dart';
import 'fixtures/network_fixture.dart';

Map<String, dynamic> managed(String machine) {
  final row = wireComputer(machine, machine);
  row['catalog']['sessionManagementEnabled'] = true;
  return row;
}

class Harness {
  final wire = FakeBridge()
    ..computerEvents = [managed(fixtureMachineA), managed(fixtureMachineB)];
  late final backend = NetworkHerdrBackend(
    ConnectionProfile(id: 'remote', label: 'Gateway'),
    PersistentBridge(wire.open),
  );
  Future<void> start() =>
      backend.discover(epoch: 1, priorityMachines: {}).drain<void>();
}

void main() {
  test('linked-worktree refusal is a definite rejection', () {
    final error = bridgeRejection({
      'code': 'workspace_group_close_required',
      'dispatched': false,
    }, input: true);
    expect(error, isA<SessionUnavailable>());
    expect(error.toString(), contains('Nothing was closed'));
    expect(
      bridgeRejection({
        'code': 'workspace_group_close_required',
        'dispatched': true,
      }, input: true),
      isA<DeliveryUncertain>(),
    );
  });
  test(
    'workspace rename and close are scoped and verify current workspace',
    () async {
      final h = Harness();
      addTearDown(h.backend.close);
      await h.start();
      final c = h.backend.sessionComputers.last, w = c.workspaces.single;
      await h.backend.renameWorkspace(c.origin, w, 'Research');
      await h.backend.listSessions();
      expect(
        h.backend.sessionComputers.last.workspaces.single.label,
        'Research',
      );
      expect(
        h.backend.sessionComputers.first.workspaces.single.label,
        'Workbench',
      );
      await h.backend.closeWorkspace(c.origin, w);
      final remaining = await h.backend.listSessions();
      expect(remaining, hasLength(1));
      expect(remaining.single.origin!.machineId, fixtureMachineA);
      expect(h.wire.managementRequests.map((r) => r['op']), [
        'workspace.rename',
        'workspace.close',
      ]);
      expect(
        h.wire.managementRequests.every(
          (r) => r['route']['machine'] == fixtureMachineB,
        ),
        true,
      );
      await expectLater(
        h.backend.closeWorkspace(c.origin, w),
        throwsA(isA<SessionUnavailable>()),
      );
      expect(h.wire.managementRequests, hasLength(2));
    },
  );
  test(
    'workspace rename lost acknowledgement persists the inspection gate',
    () async {
      final h = Harness();
      final directory = await Directory.systemTemp.createTemp(
        'workspace-action-',
      );
      final app = AppController(
        snapshot: AppSnapshot()..activeSource = 'remote',
        store: LayoutStore(directory.path),
        backendFactory: (_) => h.backend,
      );
      addTearDown(() async {
        await app.shutdown();
        await directory.delete(recursive: true);
      });
      await app.start(polling: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final c = app.computers.last, w = c.workspaces.single;
      h.wire.managementFault = 'lost';
      await expectLater(
        app.renameWorkspace(c.origin, w, 'Research'),
        throwsA(isA<SessionActionUncertain>()),
      );
      expect(
        app.layout.uncertainActions[c.origin.computerId]!.operation,
        'workspace.rename',
      );
      await expectLater(
        app.closeWorkspace(c.origin, w),
        throwsA(isA<SessionUnavailable>()),
      );
      expect(h.wire.managementRequests, hasLength(1));
    },
  );

  test(
    'workspace creation uses the selected peer and returns its first shell',
    () async {
      final h = Harness();
      addTearDown(h.backend.close);
      await h.start();
      final computer = h.backend.sessionComputers.last;
      final created = await h.backend.createWorkspace(
        computer.origin,
        title: 'Research',
        cwd: '~/research',
      );
      expect(created.origin!.machineId, fixtureMachineB);
      expect(created.workspaceId, 'new-workspace');
      expect(created.agent, 'terminal');
      expect(h.wire.managementRequests.single['op'], 'workspace.create');
      expect(
        h.wire.managementRequests.single['route'],
        computer.origin.computerRoute,
      );
      expect(h.wire.managementRequests.single['payload'], {
        'title': 'Research',
        'cwd': '~/research',
      });
      expect(h.backend.sessionComputers.first.workspaces, hasLength(1));
      expect(h.backend.sessionComputers.last.workspaces.last.label, 'Research');
    },
  );
  test(
    'lost workspace acknowledgement is uncertain and never resubmitted',
    () async {
      final h = Harness();
      addTearDown(h.backend.close);
      await h.start();
      h.wire.managementFault = 'lost';
      await expectLater(
        h.backend.createWorkspace(
          h.backend.sessionComputers.last.origin,
          title: 'Research',
        ),
        throwsA(isA<SessionActionUncertain>()),
      );
      expect(h.wire.managementRequests, hasLength(1));
    },
  );

  test(
    'typed actions preserve peer route and verify returned shell identity',
    () async {
      final h = Harness();
      addTearDown(h.backend.close);
      await h.start();
      final sessions = await h.backend.listSessions();
      final b = sessions.last;
      final computer = h.backend.sessionComputers.last;
      expect(computer.workspaces.single.id, 'w1');
      await h.backend.renameSession(b, 'Review café');
      expect(
        h.wire.managementRequests.single['route'],
        b.origin!.route('t1', 'p1'),
      );
      final created = await h.backend.createSession(
        computer.origin,
        computer.workspaces.single,
        title: 'Shell',
        cwd: '~/project',
      );
      expect(created.origin!.machineId, fixtureMachineB);
      expect(created.key.terminal, 'new-terminal');
      expect(created.agent, 'terminal');
      await h.backend.closeSession(created);
      expect(h.wire.managementRequests.map((r) => r['op']), [
        'rename',
        'create',
        'close',
      ]);
      expect(
        (await h.backend.listSessions()).where(
          (s) => s.origin!.machineId == fixtureMachineA,
        ),
        hasLength(1),
      );
    },
  );
  test(
    'unsupported stale and malformed actions reject before submission',
    () async {
      final h = Harness();
      addTearDown(h.backend.close);
      await h.start();
      final b = (await h.backend.listSessions()).last,
          c = h.backend.sessionComputers.last;
      for (final title in ['bad\n', 'é' * 65]) {
        await expectLater(
          h.backend.renameSession(b, title),
          throwsA(isA<ArgumentError>()),
        );
      }
      await expectLater(
        h.backend.createSession(c.origin, c.workspaces.single, cwd: 'relative'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        h.backend.createSession(
          c.origin,
          const SessionWorkspace('other', 'Other'),
        ),
        throwsA(isA<SessionUnavailable>()),
      );
      h.wire.computerEvents.last['targetHash'] = 'c' * 64;
      await h.backend.listSessions();
      await expectLater(
        h.backend.renameSession(b, 'old'),
        throwsA(isA<SessionUnavailable>()),
      );
      h.wire.computerEvents.last['catalog']['sessionManagementEnabled'] = false;
      final now = (await h.backend.listSessions()).last;
      await expectLater(
        h.backend.closeSession(now),
        throwsA(isA<SessionUnavailable>()),
      );
      expect(h.wire.managementRequests, isEmpty);
    },
  );
  test('closing while startup is pending cancels unsent mutation', () async {
    final h = Harness();
    await h.start();
    final b = (await h.backend.listSessions()).last;
    h.wire.opening = Completer<void>();
    final future = h.backend.renameSession(b, 'Unsaved');
    final failed = expectLater(future, throwsA(isA<ConnectionFailure>()));
    await Future<void>.delayed(Duration.zero);
    await h.backend.close();
    h.wire.opening!.complete();
    await failed;
    expect(h.wire.managementRequests, isEmpty);
  });
  test('lost acknowledgement persists a separate inspection gate and never replays', () async {
    final h = Harness();
    final directory = await Directory.systemTemp.createTemp('as-actions-');
    addTearDown(() => directory.delete(recursive: true));
    final snapshot = AppSnapshot()..activeSource = 'remote';
    final app = AppController(
      snapshot: snapshot,
      store: LayoutStore(directory.path),
      backendFactory: (_) => h.backend,
    );
    addTearDown(app.shutdown);
    await app.start(polling: false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final b = app.sessions.last;
    app.toggleFavourite(b);
    app.select(b.key.id);
    final order = List.of(app.layout.favouriteOrder),
        terminal = app.terminals[b.key.id];
    await app.renameSession(b, 'Renamed');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(app.layout.favourites[b.key.id]!.title, 'Renamed');
    expect(app.layout.favouriteOrder, order);
    expect(app.terminals[b.key.id], same(terminal));
    h.wire.managementFault = 'lost';
    final c = app.computers.last;
    await expectLater(
      app.createSession(c.origin, c.workspaces.single),
      throwsA(isA<SessionActionUncertain>()),
    );
    expect(app.layout.uncertainDeliveries, isEmpty);
    expect(app.layout.uncertainActions.keys, [c.origin.computerId]);
    final restored = AppSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())),
    );
    expect(
      restored
          .layoutFor('remote')
          .uncertainActions[c.origin.computerId]!
          .operation,
      'create',
    );
    await expectLater(app.closeSession(b), throwsA(isA<SessionUnavailable>()));
    expect(
      h.wire.managementRequests.where((r) => r['op'] == 'create'),
      hasLength(1),
    );
    app.acknowledgeSessionAction(c.origin.computerId);
    expect(app.layout.uncertainActions, isEmpty);
  });
  test(
    'wrong created identity is uncertain without another submission',
    () async {
      final h = Harness();
      addTearDown(h.backend.close);
      await h.start();
      final computer = h.backend.sessionComputers.last;
      h.wire.managementFault = 'wrong-created';
      await expectLater(
        h.backend.createSession(computer.origin, computer.workspaces.single),
        throwsA(isA<SessionActionUncertain>()),
      );
      expect(
        h.wire.managementRequests.where((r) => r['op'] == 'create'),
        hasLength(1),
      );
    },
  );
  test('confirmed close returns selected view to overview and retains favourite bookmark', () async {
    final h = Harness();
    final directory = await Directory.systemTemp.createTemp('as-close-');
    addTearDown(() => directory.delete(recursive: true));
    final snapshot = AppSnapshot()..activeSource = 'remote';
    final app = AppController(
      snapshot: snapshot,
      store: LayoutStore(directory.path),
      backendFactory: (_) => h.backend,
    );
    addTearDown(app.shutdown);
    await app.start(polling: false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final a = app.sessions.first, b = app.sessions.last;
    app.toggleFavourite(b);
    app.select(b.key.id);
    final order = List.of(app.layout.favouriteOrder);
    await app.closeSession(b);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(app.layout.selectedId, isNull);
    expect(app.layout.favourites[b.key.id]!.available, false);
    expect(app.layout.favouriteOrder, order);
    expect(app.sessions.any((s) => s.key == a.key && s.available), true);
    expect(app.layout.uncertainActions, isEmpty);
  });
  test(
    'resolved pane title overrides tab label while raw OSC remains separate',
    () {
      final catalog = wireCatalog('OSC');
      catalog['tabs'] = [
        {'tab_id': 'tab1', 'workspace_id': 'w1', 'label': 'Custom tab'},
      ];
      catalog['catalog']['result']['agents'][0]['title'] = 'Renamed pane';
      final row = parseCatalog(jsonEncode(catalog), 'remote').single;
      expect(row.title, 'Renamed pane');
      expect(row.terminalTitle, 'OSC');
      expect(row.agent, 'terminal');
      catalog['catalog']['result']['agents'][0].remove('title');
      expect(
        parseCatalog(jsonEncode(catalog), 'remote').single.title,
        'Custom tab',
      );
    },
  );
  test(
    'stored action metadata discards malformed identities and bounds records',
    () {
      final origin = SessionOrigin(
        profile: 'remote',
        machineId: fixtureMachineB,
        machineLabel: 'Mac',
        herdrSession: 'default',
        targetHash: fixtureTarget,
        generation: fixtureGeneration,
      );
      final record = SessionActionRecord('create', origin);
      final good = origin.computerId;
      final decoded = WorkspaceLayout.fromJson({
        'uncertainActions': {good: record.toJson(), 'bad': record.toJson()},
      });
      expect(decoded.uncertainActions.keys, [good]);
      expect(
        WorkspaceLayout.fromJson({
          'uncertainActions': {
            good: {...record.toJson(), 'operation': 'shell'},
          },
        }).uncertainActions,
        isEmpty,
      );
    },
  );
  for (final transition in ['source', 'background']) {
    test(
      'pending management is cancelled immediately on $transition before delayed stream cleanup',
      () async {
        final h = Harness();
        final directory = await Directory.systemTemp.createTemp('as-cancel-');
        addTearDown(() => directory.delete(recursive: true));
        final snapshot = AppSnapshot()..activeSource = 'remote';
        final app = AppController(
          snapshot: snapshot,
          store: LayoutStore(directory.path),
          backendFactory: (source) =>
              source == 'remote' ? h.backend : DemoBackend(),
        );
        addTearDown(app.shutdown);
        await app.start(polling: false);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final b = app.sessions.last;
        app.select(b.key.id);
        final until = DateTime.now().add(const Duration(seconds: 2));
        while (!h.wire.requests.any((r) => r['op'] == 'observe') &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(h.wire.requests.any((r) => r['op'] == 'observe'), true);
        h.wire.hold(BridgeLane.streams);
        h.wire.opening = Completer<void>();
        final action = app.renameSession(b, 'Must not arrive');
        final outcome = action.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        while (!h.wire.startingLanes.contains(BridgeLane.input) &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(h.wire.startingLanes, contains(BridgeLane.input));
        final switching = transition == 'source'
            ? app.switchSource('demo')
            : app.setActive(false);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        h.wire.opening!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final submitted = List.of(h.wire.managementRequests);
        h.wire.release(BridgeLane.streams);
        await switching;
        final error = await outcome;
        expect(
          submitted,
          isEmpty,
          reason: 'Leaving a source must cancel before waiting for its stream cleanup.',
        );
        expect(error, isA<ConnectionFailure>());
        expect(snapshot.layoutFor('remote').uncertainActions, isEmpty);
      },
    );
  }
}
