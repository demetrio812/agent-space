import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/bridge_protocol.dart';
import 'package:agentspace/src/native_bridge.dart';
import 'package:agentspace/src/persistent_bridge.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/ssh_bridge.dart';

import 'fixtures/fake_bridge.dart' show fixtureRoute;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agentspace/herdr');
  late Map<String, Queue<Uint8List>> output;
  late List<MethodCall> calls;
  late BridgeAssets assets;
  Completer<void>? holdStart;
  bool failDiscovery = false;
  late Map<String, String> lanes;
  setUp(() async {
    output = {};
    calls = [];
    assets = await BridgeAssets.load();
    holdStart = null;
    failDiscovery = false;
    lanes = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final row = call.arguments as Map? ?? {};
          final id = row['id'] as String?;
          if (call.method == 'startBridge') {
            lanes[id!] = row['lane'] as String;
            output[id] = Queue()
              ..add(
                encodeBridgeRecord({
                  'type': 'hello',
                  'protocol': bridgeProtocol,
                  'digest': assets.digest,
                  'nonce': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                  'lane': row['lane'],
                  'generation': fixtureRoute['generation'],
                  'capabilities': {
                    'input': true,
                    'observe': true,
                    'viewport': true,
                    'network': true,
                  },
                }),
              );
            await holdStart?.future;
          } else if (call.method == 'read') {
            if (failDiscovery && lanes[id] == 'discovery') {
              throw PlatformException(code: 'disconnected');
            }
            if (output[id]!.isEmpty) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
            return {
              'out': output[id]!.isEmpty
                  ? Uint8List(0)
                  : output[id]!.removeFirst(),
              'err': Uint8List(0),
            };
          } else if (call.method == 'writeBridge') {
            final request =
                jsonDecode(utf8.decode(row['record'] as Uint8List)) as Map;
            output[id!]!.add(
              encodeBridgeRecord({
                'type': 'reply',
                'nonce': request['nonce'],
                'lane': request['lane'],
                'id': request['id'],
                'ok': true,
                'result': {'sent': true, 'alive': true},
              }),
            );
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('one native worker accepts repeated typed command keys', () async {
    final factory = NativeBridgeFactory(
      ConnectionProfile(
        id: 'local',
        label: 'Local Mac',
        executable: '/tmp/herdr',
        socketPath: '/tmp/herdr.sock',
      ),
    );
    final bridge = PersistentBridge(factory.open);
    try {
      for (var i = 0; i < 3; i++) {
        await bridge.request(BridgeLane.input, 'input', {
          'keys': ['cmd+backspace', 'ctrl+enter'],
        }, route: fixtureRoute);
      }
      expect(calls.where((c) => c.method == 'startBridge'), hasLength(1));
      final writes = calls
          .where((c) => c.method == 'writeBridge')
          .map(
            (c) => jsonDecode(
              utf8.decode((c.arguments as Map)['record'] as Uint8List),
            ) as Map,
          )
          .toList();
      expect(writes, hasLength(3));
      expect((writes.first['payload'] as Map)['keys'], [
        'cmd+backspace',
        'ctrl+enter',
      ]);
      expect(calls.any((c) => c.method == 'start'), false);
    } finally {
      await bridge.close();
      await factory.close();
    }
  });
  test('close during native startup prevents request delivery', () async {
    holdStart = Completer<void>();
    final factory = NativeBridgeFactory(
      ConnectionProfile(
        id: 'local',
        label: 'Mac',
        executable: '/tmp/herdr',
        socketPath: '/tmp/herdr.sock',
      ),
    );
    final bridge = PersistentBridge(factory.open);
    final pending = expectLater(
      bridge.request(BridgeLane.input, 'input', {
        'text': 'never sent',
      }, route: fixtureRoute),
      throwsA(isA<ConnectionFailure>()),
    );
    while (!calls.any((c) => c.method == 'startBridge')) {
      await Future<void>.delayed(Duration.zero);
    }
    await bridge.close();
    await factory.close();
    holdStart!.complete();
    await pending;
    expect(calls.where((c) => c.method == 'writeBridge'), isEmpty);
    expect(calls.where((c) => c.method == 'stop'), isNotEmpty);
  });
  test(
    'native discovery failure stops its job while ready input stays usable',
    () async {
      final factory = NativeBridgeFactory(
        ConnectionProfile(
          id: 'local',
          label: 'Mac',
          executable: '/tmp/herdr',
          socketPath: '/tmp/herdr.sock',
        ),
      );
      final bridge = PersistentBridge(factory.open);
      try {
        await bridge.request(BridgeLane.input, 'input', {
          'text': 'first',
        }, route: fixtureRoute);
        failDiscovery = true;
        await expectLater(
          bridge.request(BridgeLane.discovery, 'health', {}),
          throwsA(isA<ConnectionFailure>()),
        );
        expect(
          (await bridge.request(BridgeLane.input, 'input', {
            'text': 'second',
          }, route: fixtureRoute))['sent'],
          true,
        );
        expect(
          calls.where(
            (c) =>
                c.method == 'startBridge' &&
                (c.arguments as Map)['lane'] == 'input',
          ),
          hasLength(1),
        );
        expect(calls.where((c) => c.method == 'close'), isEmpty);
      } finally {
        await bridge.close();
        await factory.close();
      }
    },
  );
}
