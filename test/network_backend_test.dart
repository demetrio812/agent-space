import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/network_backend.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/persistent_bridge.dart';

import 'fixtures/fake_bridge.dart';
import 'fixtures/network_fixture.dart';

void main() {
  test(
    'network adapter scopes catalogs and sends only to selected peer',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [
          wireComputer('gateway', 'Gateway'),
          wireComputer(fixtureMachineA, 'Mac'),
          wireComputer(fixtureMachineB, 'Mac'),
        ];
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      final updates = await backend
          .discover(epoch: 1, priorityMachines: {})
          .toList();
      expect(updates.last.complete, true);
      expect(updates.last.sessions, hasLength(3));
      expect(updates.last.sessions.map((s) => s.key.id).toSet(), hasLength(3));
      final b = updates.last.sessions.singleWhere(
        (s) => s.origin!.machineId == fixtureMachineB,
      );
      await backend.sendTerminalInput(
        b,
        TerminalInput.keys(['cmd+backspace', 'ctrl+enter']),
      );
      expect(wire.sentInputs.single['route']['machine'], fixtureMachineB);
      expect(wire.sentInputs.single['route']['generation'], fixtureGeneration);
    },
  );
  test(
    'refresh connecting state and one peer failure retain healthy catalog',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [
          wireComputer('gateway', 'Gateway'),
          wireComputer(fixtureMachineA, 'A'),
          wireComputer(fixtureMachineB, 'B'),
        ];
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      await backend.discover(epoch: 1, priorityMachines: {}).drain<void>();
      wire.computerEvents = [
        wireComputer('gateway', 'Gateway'),
        wireComputer(fixtureMachineA, 'A', state: 'connecting'),
        wireComputer(fixtureMachineB, 'B', state: 'attention'),
      ];
      final last =
          (await backend.discover(epoch: 2, priorityMachines: {}).toList())
              .last;
      expect(
        last.sessions
            .singleWhere((s) => s.origin!.machineId == fixtureMachineA)
            .available,
        true,
      );
      expect(
        last.sessions
            .singleWhere((s) => s.origin!.machineId == fixtureMachineB)
            .available,
        false,
      );
    },
  );
  for (final previousState in ['attention', 'offline']) {
    test(
      'refresh keeps $previousState visible until a new result arrives',
      () async {
        final wire = FakeBridge()
          ..computerEvents = [
            wireComputer(fixtureMachineA, 'MacBook', state: previousState)
              ..['code'] = 'setup_required',
            wireComputer(fixtureMachineB, 'Healthy'),
          ];
        final backend = NetworkHerdrBackend(
          ConnectionProfile(id: 'remote', label: 'Gateway'),
          PersistentBridge(wire.open),
        );
        addTearDown(backend.close);
        final initial =
            (await backend.discover(epoch: 1, priorityMachines: {}).toList())
                .last;
        final prior = initial.computers.singleWhere(
          (c) => c.origin.machineId == fixtureMachineA,
        );
        wire.computerEvents = [
          wireComputer(fixtureMachineA, 'MacBook', state: 'connecting'),
          wireComputer(fixtureMachineA, 'MacBook', state: previousState)
            ..['code'] = 'setup_required',
          wireComputer(fixtureMachineB, 'Healthy'),
        ];
        final updates = await backend
            .discover(epoch: 2, priorityMachines: {})
            .toList();
        for (final update in updates) {
          final computer = update.computers.singleWhere(
            (c) => c.origin.machineId == fixtureMachineA,
          );
          expect(computer.state, prior.state);
          expect(computer.message, prior.message);
          expect(
            update.sessions
                .singleWhere((s) => s.origin!.machineId == fixtureMachineB)
                .available,
            true,
          );
        }
        wire.computerEvents = [wireComputer(fixtureMachineA, 'MacBook')];
        final recovered =
            (await backend.discover(epoch: 3, priorityMachines: {}).toList())
                .last;
        expect(recovered.computers.single.state, ComputerState.live);
        expect(recovered.sessions.single.available, true);
      },
    );
  }
  test(
    'new and retargeted computers still show initial connecting state',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [
          wireComputer(fixtureMachineA, 'MacBook', state: 'connecting'),
        ];
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      expect(
        (await backend.discover(epoch: 1, priorityMachines: {}).toList())
            .last
            .computers
            .single
            .state,
        ComputerState.connecting,
      );
      wire.computerEvents = [
        wireComputer(fixtureMachineA, 'MacBook', state: 'attention'),
      ];
      await backend.discover(epoch: 2, priorityMachines: {}).drain<void>();
      wire.computerEvents = [
        wireComputer(
          fixtureMachineA,
          'MacBook',
          state: 'connecting',
          targetHash: fixtureGeneration,
        ),
      ];
      final changed =
          (await backend.discover(epoch: 3, priorityMachines: {}).toList())
              .last;
      expect(changed.computers.single.state, ComputerState.connecting);
      expect(changed.computers.single.origin.targetHash, fixtureGeneration);
    },
  );
  test(
    'retarget with unchanged server generation rejects captured old session',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [wireComputer(fixtureMachineA, 'A')];
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      final old = (await backend.listSessions()).single;
      wire.computerEvents = [
        wireComputer(fixtureMachineA, 'A', targetHash: fixtureGeneration),
      ];
      await backend.listSessions();
      await expectLater(
        backend.sendTerminalInput(old, const TerminalInput.text('never sent')),
        throwsA(isA<SessionUnavailable>()),
      );
      expect(wire.sentInputs, isEmpty);
    },
  );
}
