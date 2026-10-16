import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';

void main() {
  late Directory directory;
  late ServerSocket api, observer;
  late SocketHerdrBackend backend;
  final clients = <Socket>[];
  final requests = <Map>[];
  final wireRequests = <List<int>>[];
  var uncertain = false, oversized = false, idle = false;
  Object? acknowledgement = {'type': 'ok'};
  late Completer<void> disconnected;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agentspace-sockets-');
    final path = '${directory.path}/fixture.sock';
    clients.clear();
    requests.clear();
    wireRequests.clear();
    uncertain = false;
    oversized = false;
    idle = false;
    acknowledgement = {'type': 'ok'};
    disconnected = Completer<void>();
    api = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    observer = await ServerSocket.bind(
      InternetAddress(
        '${directory.path}/fixture-client.sock',
        type: InternetAddressType.unix,
      ),
      0,
    );
    api.listen((client) {
      clients.add(client);
      client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final request = jsonDecode(line) as Map;
            requests.add(request);
            final result = switch (request['method']) {
              'agent.list' => {
                'agents': [
                  {
                    'terminal_id': 't1',
                    'pane_id': 'p1',
                    'workspace_id': 'w1',
                    'tab_id': 'tab1',
                    'terminal_title': 'Generated',
                    'agent_status': 'idle',
                  },
                ],
              },
              'workspace.list' => {
                'workspaces': [
                  {'workspace_id': 'w1', 'label': 'Work'},
                ],
              },
              'tab.list' => {
                'tabs': [
                  {
                    'workspace_id': 'w1',
                    'tab_id': 'tab1',
                    'label': 'Socket task',
                    'number': 1,
                  },
                ],
              },
              'pane.layout' => {
                'layout': {
                  'panes': [
                    {
                      'pane_id': 'p1',
                      'rect': {'width': 175, 'height': 55},
                    },
                  ],
                },
              },
              'pane.send_input' => acknowledgement,
              _ => {'type': 'error'},
            };
            if (uncertain && request['method'] == 'pane.send_input') {
              client.destroy();
              return;
            }
            client.writeln(jsonEncode({'id': request['id'], 'result': result}));
          }, onError: (Object _) {});
    });
    observer.listen((client) {
      clients.add(client);
      final pending = <int>[];
      client.listen(
        (chunk) {
          pending.addAll(chunk);
          while (pending.length >= 4) {
            final size = ByteData.sublistView(
              Uint8List.fromList(pending.take(4).toList()),
            ).getUint32(0, Endian.little);
            if (pending.length < size + 4) return;
            final payload = pending.sublist(4, 4 + size);
            pending.removeRange(0, 4 + size);
            wireRequests.add(payload);
            if (payload.first == 0) {
              client.add([4, 0, 0, 0, 0, 22, 1, 0]);
            }
            if (payload.first == 7) {
              if (idle) continue;
              if (oversized) {
                client.add([1, 0, 32, 0]);
              } else {
                // Golden protocol-22 bytes independently confirmed by installed CLI.
                client.add([10, 0]);
                client.add([
                  0,
                  0,
                  1,
                  0,
                  175,
                  55,
                  1,
                  4,
                  ...'demo'.codeUnits,
                  2,
                  0,
                  0,
                  0,
                  3,
                  0,
                ]);
              }
            }
          }
        },
        onError: (Object _) {},
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    backend = SocketHerdrBackend(
      ConnectionProfile(
        id: 'fixture',
        label: 'Disposable',
        executable: '/missing/herdr',
        socketPath: path,
      ),
    );
  });
  tearDown(() async {
    await backend.close();
    for (final client in clients) {
      client.destroy();
    }
    await api.close();
    await observer.close();
    await directory.delete(recursive: true);
  });
  test(
    'local socket catalog needs no external executable and preserves labels',
    () async {
      final sessions = await backend.listSessions();
      expect(sessions.single.title, 'Socket task');
      expect(requests.map((r) => r['method']), [
        'agent.list',
        'workspace.list',
        'tab.list',
      ]);
    },
  );
  test(
    'observer uses native geometry with only read-only protocol messages',
    () async {
      final session = (await backend.listSessions()).single;
      final events = await backend
          .observe(session)
          .toList()
          .timeout(const Duration(seconds: 8));
      final frame = events.first as TerminalFrame;
      expect(frame.height, 55);
      expect(frame.width, 175);
      expect(utf8.decode(frame.bytes), 'demo');
      expect(events.last, isA<TerminalClosed>());
      expect(wireRequests, [
        [0, 22, 175, 55, 0, 0, 0],
        [7, 2, 116, 49],
      ]);
    },
  );
  test(
    'socket input is literal once and lost acknowledgement is uncertain',
    () async {
      final session = (await backend.listSessions()).single;
      const text = '--literal café; \$(echo harmless)\nsecond line';
      await backend.sendText(session, text);
      final input = requests
          .where((r) => r['method'] == 'pane.send_input')
          .single;
      expect(input['params'], {
        'pane_id': 'p1',
        'text': text,
        'keys': ['Enter'],
      });
      uncertain = true;
      await expectLater(
        backend.sendText(session, 'one more submission'),
        throwsA(isA<DeliveryUncertain>()),
      );
      expect(
        requests.where((r) => r['method'] == 'pane.send_input'),
        hasLength(2),
      );
    },
  );
  test('input needs an explicit successful acknowledgement', () async {
    final session = (await backend.listSessions()).single;
    for (final invalid in [
      null,
      {},
      {'type': 'error'},
      {'type': 'ok', 'ok': false},
      {'type': 'ok', 'error': 'denied'},
    ]) {
      acknowledgement = invalid;
      await expectLater(
        backend.sendText(session, 'fixture only'),
        throwsA(isA<DeliveryUncertain>()),
      );
    }
    expect(
      requests.where((r) => r['method'] == 'pane.send_input'),
      hasLength(5),
    );
  });
  for (final name in ['fixture.rpc', 'fixture']) {
    test('observer derives sibling client socket from $name', () async {
      final path = '${directory.path}/$name';
      await File('${directory.path}/fixture.sock').rename(path);
      await backend.close();
      backend = SocketHerdrBackend(
        ConnectionProfile(id: 'fixture', label: 'Disposable', socketPath: path),
      );
      final session = (await backend.listSessions()).single;
      final events = await backend
          .observe(session)
          .toList()
          .timeout(const Duration(seconds: 8));
      expect(events.first, isA<TerminalFrame>());
    });
  }
  test(
    'cancelling an idle observation disconnects its socket promptly',
    () async {
      idle = true;
      final session = (await backend.listSessions()).single;
      final subscription = backend
          .observe(session)
          .listen((_) {}, onError: (Object _) {});
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (wireRequests.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(wireRequests.last.first, 7);
      await subscription.cancel();
      await disconnected.future.timeout(const Duration(seconds: 2));
    },
  );
  test(
    'oversized binary frames are rejected before payload allocation',
    () async {
      oversized = true;
      final session = (await backend.listSessions()).single;
      await expectLater(
        backend.observe(session).toList(),
        throwsFormatException,
      );
    },
  );
}
