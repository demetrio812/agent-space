import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/bridge_protocol.dart';
import 'package:agentspace/src/persistent_bridge.dart';

import 'fixtures/fake_bridge.dart';

void main() {
  test(
    'takeover is carried only on the explicitly requested viewport',
    () async {
      final wire = FakeBridge();
      final bridge = PersistentBridge(wire.open);
      addTearDown(bridge.close);
      for (final takeover in [false, true, false]) {
        final sub = bridge
            .observe(fixtureRoute, cols: 90, rows: 30, takeover: takeover)
            .listen((_) {});
        await bridge.request(BridgeLane.streams, 'health', {});
        final request = wire.requests.lastWhere((r) => r['op'] == 'observe');
        expect((request['payload'] as Map)['takeover'], takeover ? true : null);
        await sub.cancel();
      }
      expect(
        () => bridge.observe(fixtureRoute, takeover: true),
        throwsArgumentError,
      );
    },
  );

  test(
    'late frame after cancelled view does not retire another stream lane',
    () async {
      final wire = FakeBridge();
      final bridge = PersistentBridge(wire.open);
      addTearDown(bridge.close);
      final sub = bridge.observe(fixtureRoute).listen((_) {});
      await bridge.request(BridgeLane.streams, 'health', {});
      final id =
          wire.requests.firstWhere((r) => r['op'] == 'observe')['id'] as String;
      await sub.cancel();
      wire.lateFrame(id);
      await Future<void>.delayed(Duration.zero);
      await bridge.request(BridgeLane.streams, 'health', {});
      expect(
        wire.openedLanes.where((l) => l == BridgeLane.streams),
        hasLength(1),
      );
    },
  );
  test('ready lane reused for twenty keys and catalogs', () async {
    final wire = FakeBridge();
    final bridge = PersistentBridge(wire.open);
    addTearDown(bridge.close);
    for (var i = 0; i < 20; i++) {
      await bridge.request(BridgeLane.input, 'input', {
        'keys': ['cmd+backspace'],
      }, route: fixtureRoute);
    }
    expect(wire.sentInputs, hasLength(20));
    expect(wire.openedLanes.where((l) => l == BridgeLane.input), hasLength(1));
    expect(await bridge.discover(1, {}).toList(), hasLength(1));
    expect(await bridge.discover(2, {}).toList(), hasLength(1));
    expect(
      wire.openedLanes.where((l) => l == BridgeLane.discovery),
      hasLength(1),
    );
  });
  test('discovery deadline cannot cancel a ready input lane', () async {
    final wire = FakeBridge();
    final bridge = PersistentBridge(wire.open);
    addTearDown(bridge.close);
    wire.hold(BridgeLane.discovery);
    final stalled = expectLater(
      bridge.request(
        BridgeLane.discovery,
        'health',
        {},
        timeout: const Duration(milliseconds: 80),
      ),
      throwsA(isA<ConnectionFailure>()),
    );
    final ack = await bridge.request(BridgeLane.input, 'input', {
      'keys': ['ctrl+enter'],
    }, route: fixtureRoute);
    expect(ack['sent'], true);
    await stalled;
    expect(wire.closedLanes, isNot(contains(BridgeLane.input)));
  });
  for (final fault in ['lost', 'nonce', 'id', 'malformed', 'partial']) {
    test('$fault acknowledgement stays uncertain with one attempt', () async {
      final wire = FakeBridge()..inputFault = fault;
      final bridge = PersistentBridge(wire.open);
      addTearDown(bridge.close);
      await expectLater(
        bridge.request(
          BridgeLane.input,
          'input',
          {'text': 'one attempt'},
          route: fixtureRoute,
          timeout: const Duration(milliseconds: 80),
        ),
        throwsA(isA<DeliveryUncertain>()),
      );
      expect(wire.sentInputs, hasLength(1));
    });
  }
  test('correlated pre-dispatch rejection is definite', () async {
    final wire = FakeBridge()..inputFault = 'rejected';
    final bridge = PersistentBridge(wire.open);
    addTearDown(bridge.close);
    await expectLater(
      bridge.request(BridgeLane.input, 'input', {
        'text': 'not sent',
      }, route: fixtureRoute),
      throwsA(isA<SessionUnavailable>()),
    );
  });
  test('close during pending open prevents subsequent request write', () async {
    final wire = FakeBridge()..opening = Completer<void>();
    final bridge = PersistentBridge(wire.open);
    final result = expectLater(
      bridge.request(BridgeLane.input, 'input', {
        'text': 'never sent',
      }, route: fixtureRoute),
      throwsA(isA<ConnectionFailure>()),
    );
    await bridge.close();
    wire.opening!.complete();
    await result;
    expect(wire.sentInputs, isEmpty);
    expect(wire.closedLanes, contains(BridgeLane.input));
  });
}
