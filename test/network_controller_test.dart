import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/demo_backend.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/network_models.dart';

import 'fixtures/network_fixture.dart';

Future<void> settleNetwork() async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

void main() {
  late Directory directory;
  late NetworkFixture fixture;
  late AppController app;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('an-');
    fixture = NetworkFixture();
    app = fixture.controller(directory);
  });
  tearDown(() async {
    await app.shutdown();
    await directory.delete(recursive: true);
  });
  test(
    'incremental offline peer preserves other live session and favourite draft',
    () async {
      final a = fixture.session(machine: fixtureMachineA),
          b = fixture.session(machine: fixtureMachineB);
      fixture.initial = [a, b];
      fixture.completeInitially = false;
      await app.start(polling: false);
      app.toggleFavourite(b);
      app.updateDraft(b.key.id, 'unfinished');
      fixture.emit(
        NetworkUpdate(
          epoch: 1,
          computers: fixture.computersFor([a]),
          sessions: [a],
          complete: true,
        ),
      );
      await settleNetwork();
      expect(app.connectionState, ConnectionState.live);
      expect(app.sessionById(a.key.id)!.available, true);
      expect(app.sessionById(b.key.id)!.available, false);
      expect(app.layout.drafts[b.key.id], 'unfinished');
    },
  );
  test('obsolete epoch cannot replace current snapshot', () async {
    final a = fixture.session(machine: fixtureMachineA);
    fixture.initial = [a];
    await app.start(polling: false);
    await settleNetwork();
    fixture.completeInitially = false;
    await app.refresh();
    fixture.emit(
      NetworkUpdate(epoch: 1, computers: [], sessions: [], complete: false),
    );
    await settleNetwork();
    expect(app.sessions.single.key, a.key);
  });
  test('legacy workspace filter migrates to gateway scope and names remain searchable', () async {
    final gateway = fixture.session(machine: 'gateway', label: 'Gateway');
    final peer = fixture.session(
      machine: fixtureMachineA,
      label: 'M4',
      herdrSession: 'work',
    );
    fixture.initial = [gateway, peer];
    app.layout.filter = 'w1';
    await app.start(polling: false);
    expect(app.layout.filter, gateway.workspaceFilterId);
    expect(app.visibleSessions.single.key, gateway.key);
    app.setFilter('all');
    app.setSearch('M4');
    expect(app.visibleSessions.single.key, peer.key);
    app.setSearch('work');
    expect(app.visibleSessions, contains(peer));
  });
  test(
    'background closes gateway workers then resume creates a fresh backend',
    () async {
      fixture.initial = [fixture.session(machine: 'gateway')];
      await app.start(polling: false);
      await app.setActive(false);
      expect(fixture.closed, true);
      await app.setActive(true);
      expect(app.connectionState, ConnectionState.live);
    },
  );
  test(
    'one peer attention preserves selected stream and keyboard delivery',
    () async {
      final a = fixture.session(machine: fixtureMachineA),
          b = fixture.session(machine: fixtureMachineB);
      fixture.initial = [a, b];
      await app.start(polling: false);
      app.select(a.key.id);
      await settleNetwork();
      final subscription = app.terminals[a.key.id]!.subscription;
      fixture.completeInitially = false;
      await app.refresh();
      fixture.emit(
        NetworkUpdate(
          epoch: fixture.epoch,
          computers: [
            ComputerInfo(origin: a.origin!, state: ComputerState.live),
            ComputerInfo(
              origin: b.origin!,
              state: ComputerState.attention,
              message: 'Check access',
            ),
          ],
          sessions: [a, b.unavailable()],
          complete: true,
        ),
      );
      await settleNetwork();
      expect(app.terminals[a.key.id]!.subscription, same(subscription));
      expect(app.connectionState, ConnectionState.live);
      app.sendTerminalInput(a.key.id, const TerminalInput.text('stays live'));
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (fixture.inputs.isEmpty && DateTime.now().isBefore(deadline)) {
        await settleNetwork();
      }
      expect(fixture.inputs.single['session'].key, a.key);
    },
  );
  test(
    'discovery error cannot revoke an independently live selected terminal',
    () async {
      final a = fixture.session(machine: fixtureMachineA);
      fixture.initial = [a];
      fixture.completeInitially = false;
      await app.start(polling: false);
      app.select(a.key.id);
      await settleNetwork();
      final subscription = app.terminals[a.key.id]!.subscription;
      fixture.discovery[fixture.epoch]!.addError(
        ConnectionFailure('Catalog timed out'),
      );
      await settleNetwork();
      expect(app.connectionState, ConnectionState.live);
      expect(app.terminals[a.key.id]!.subscription, same(subscription));
      expect(app.canSendTerminalInput(a.key.id), true);
    },
  );
  test('source switch cancels peer keys queued before dispatch', () async {
    await app.shutdown();
    fixture.initial = [fixture.session(machine: fixtureMachineA)];
    app = AppController(
      snapshot: AppSnapshot()..activeSource = 'remote',
      store: LayoutStore(directory.path),
      backendFactory: (source) => source == 'remote' ? fixture : DemoBackend(),
    );
    await app.start(polling: false);
    final session = fixture.initial.single;
    app.select(session.key.id);
    app.sendTerminalInput(
      session.key.id,
      const TerminalInput.text('do not replay'),
    );
    await app.switchSource('demo');
    await settleNetwork();
    expect(fixture.inputs, isEmpty);
    expect(app.source, 'demo');
    expect(fixture.closed, true);
    expect(
      app.sessions.any((s) => s.origin?.machineId == fixtureMachineA),
      false,
    );
  });
  test(
    'new peer generation leaves old favourite and its uncertainty unavailable',
    () async {
      final old = fixture.session(machine: fixtureMachineA);
      fixture.initial = [old];
      await app.start(polling: false);
      app.toggleFavourite(old);
      app.layout.uncertainDeliveries.add(old.key.id);
      app.updateDraft(old.key.id, 'kept');
      await settleNetwork();
      fixture.initial = [
        fixture.session(machine: fixtureMachineA, generation: fixtureTarget),
      ];
      await app.refresh();
      expect(app.sessionById(old.key.id)!.available, false);
      expect(app.layout.drafts[old.key.id], 'kept');
      expect(app.layout.uncertainDeliveries, contains(old.key.id));
      expect(app.canSendTerminalInput(old.key.id), false);
    },
  );
}
