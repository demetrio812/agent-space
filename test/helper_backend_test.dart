import 'dart:convert';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agentspace/herdr');
  late HelperHerdrBackend backend;
  final requests = <Map>[];
  final jobs = <String, List<String>>{};
  var uncertain = false;
  var absent = false;
  var identity = '/custom/state/server.rpc:1:2:3';
  var restartAfterCatalog = false;
  final resizeRequests = <Map>[];
  final heldControls = <String, Completer<Map<String, dynamic>>>{};
  final controlReads = <String>{};
  Completer<void>? catalogHold;
  setUp(() {
    requests.clear();
    jobs.clear();
    uncertain = false;
    absent = false;
    identity = '/custom/state/server.rpc:1:2:3';
    restartAfterCatalog = false;
    resizeRequests.clear();
    heldControls.clear();
    controlReads.clear();
    catalogHold = null;
    backend = HelperHerdrBackend(
      ConnectionProfile(
        id: 'helper',
        label: 'Custom Mac',
        executable: '/custom/bin/herdr',
        socketPath: '/custom/state/server.rpc',
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final data = Map<String, dynamic>.from(call.arguments as Map? ?? {});
          if (call.method == 'identity') {
            return identity;
          }
          if (call.method == 'start') {
            requests.add(data);
            jobs[data['id'] as String] = List<String>.from(data['arguments']);
            return null;
          }
          if (call.method == 'resize') {
            resizeRequests.add(data);
            return null;
          }
          if (call.method == 'stop' || call.method == 'close') {
            for (final pending in heldControls.values) {
              if (!pending.isCompleted) {
                pending.complete({
                  'out': Uint8List(0),
                  'err': Uint8List(0),
                  'exit': 0,
                });
              }
            }
            return null;
          }
          final args = jobs[data['id']]!;
          if (args.take(2).join(' ') == 'agent list') await catalogHold?.future;
          if (args.take(3).join(' ') == 'terminal session control' &&
              !controlReads.add(data['id'] as String)) {
            return (heldControls[data['id']] ??=
                    Completer<Map<String, dynamic>>())
                .future;
          }
          if (uncertain && args.take(2).join(' ') == 'pane run') {
            throw PlatformException(code: 'helper_lost');
          }
          final payload = switch (args.take(2).join(' ')) {
            'agent list' => {
              'result': {
                'agents': [
                  if (!absent)
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
            },
            'workspace list' => {
              'result': {
                'workspaces': [
                  {'workspace_id': 'w1', 'label': 'Custom'},
                ],
              },
            },
            'tab list' => {
              'result': {
                'tabs': [
                  {
                    'workspace_id': 'w1',
                    'tab_id': 'tab1',
                    'label': 'Helper session',
                    'number': 1,
                  },
                ],
              },
            },
            'pane layout' => {
              'result': {
                'layout': {
                  'panes': [
                    {
                      'pane_id': 'p1',
                      'rect': {'width': 175, 'height': 55},
                    },
                  ],
                },
              },
            },
            'pane run' => {
              'result': {'type': 'ok'},
            },
            'pane send-text' || 'pane send-keys' => {
              'result': {'type': 'ok'},
            },
            _ => {
              'type': 'terminal.frame',
              'encoding': 'ansi',
              'width': 175,
              'height': 55,
              'seq': 0,
              'full': true,
              'bytes': 'ZGVtbw==',
            },
          };
          final output = args.take(3).join(' ') == 'terminal session control'
              ? '${jsonEncode(payload)}\n'
              : args.first == 'terminal'
              ? '${jsonEncode(payload)}\n{"type":"terminal.closed","reason":"Fixture complete"}\n'
              : jsonEncode(payload);
          if (restartAfterCatalog && args.take(2).join(' ') == 'agent list') {
            identity = '/custom/state/server.rpc:1:3:4';
          }
          return {
            'out': Uint8List.fromList(utf8.encode(output)),
            'err': Uint8List(0),
            if (args.take(3).join(' ') != 'terminal session control') 'exit': 0,
          };
        });
  });
  test('helper viewport stream sends bounded dimensions and releases its controller', () async {
    final session = (await backend.listSessions()).single;
    final ready = Completer<void>();
    final subscription = backend.observeViewport(session, 90, 30).listen((
      event,
    ) {
      if (event is TerminalFrame && !ready.isCompleted) ready.complete();
    });
    await ready.future;
    await backend.resizeViewport(session, 80, 25);
    expect(requests.last['arguments'], [
      'terminal',
      'session',
      'control',
      't1',
      '--cols',
      '90',
      '--rows',
      '30',
    ]);
    expect(resizeRequests.last['cols'], 80);
    expect(resizeRequests.last['rows'], 25);
    await expectLater(
      backend.resizeViewport(session, 512, 256),
      throwsArgumentError,
    );
    await subscription.cancel();
    await expectLater(
      backend.resizeViewport(session, 80, 25),
      throwsA(isA<ConnectionFailure>()),
    );
  });
  tearDown(() async {
    await backend.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('cancelled viewport validation never starts a controller', () async {
    final session = (await backend.listSessions()).single;
    requests.clear();
    catalogHold = Completer<void>();
    final sub = backend.observeViewport(session, 90, 30).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    catalogHold!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      requests.where(
        (r) =>
            (r['arguments'] as List).take(3).join(' ') ==
            'terminal session control',
      ),
      isEmpty,
    );
  });
  test(
    'keyboard validation avoids label discovery but checks the current target',
    () async {
      final session = (await backend.listSessions()).single;
      requests.clear();
      await backend.sendTerminalInput(session, TerminalInput.keys(['up']));
      expect(requests.map((r) => r['arguments']).toList(), [
        ['agent', 'list'],
        ['pane', 'send-keys', 'p1', 'up'],
      ]);
      requests.clear();
      absent = true;
      await expectLater(
        backend.sendTerminalInput(session, TerminalInput.keys(['enter'])),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(
        requests.where((r) => (r['arguments'] as List).first == 'pane'),
        isEmpty,
      );
    },
  );
  test(
    'server replacement during the focused keyboard check blocks dispatch',
    () async {
      final session = (await backend.listSessions()).single;
      requests.clear();
      restartAfterCatalog = true;
      await expectLater(
        backend.sendTerminalInput(session, TerminalInput.keys(['enter'])),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(
        requests.where((r) => (r['arguments'] as List).first == 'pane'),
        isEmpty,
      );
    },
  );
  test(
    'helper catalog and frames preserve custom paths and native dimensions',
    () async {
      final session = (await backend.listSessions()).single;
      expect(session.title, 'Helper session');
      final frames = await backend.observe(session).toList();
      expect((frames.first as TerminalFrame).width, 175);
      expect((frames.first as TerminalFrame).height, 55);
      expect(utf8.decode((frames.first as TerminalFrame).bytes), 'demo');
      expect(
        requests.every(
          (r) =>
              r['executable'] == '/custom/bin/herdr' &&
              r['socketPath'] == '/custom/state/server.rpc',
        ),
        isTrue,
      );
      expect(requests.last['arguments'], [
        'terminal',
        'session',
        'observe',
        't1',
        '--cols',
        '175',
        '--rows',
        '55',
      ]);
    },
  );
  test(
    'helper routes typing and logical keys without an extra Enter',
    () async {
      final session = (await backend.listSessions()).single;
      await backend.sendTerminalInput(
        session,
        const TerminalInput.text(' café '),
      );
      await backend.sendTerminalInput(
        session,
        TerminalInput.keys(['up', 'ctrl+enter']),
      );
      final input = requests
          .map((r) => r['arguments'] as List)
          .where(
            (a) =>
                a[0] == 'pane' &&
                const {'send-text', 'send-keys'}.contains(a[1]),
          )
          .toList();
      expect(input, [
        ['pane', 'send-text', 'p1', ' café '],
        ['pane', 'send-keys', 'p1', 'up', 'ctrl+enter'],
      ]);
    },
  );
  test(
    'helper loss after input submission is uncertain and never replayed',
    () async {
      final session = (await backend.listSessions()).single;
      uncertain = true;
      await expectLater(
        backend.sendText(session, 'fixture only'),
        throwsA(isA<DeliveryUncertain>()),
      );
      expect(
        requests.where(
          (r) => (r['arguments'] as List).take(2).join(' ') == 'pane run',
        ),
        hasLength(1),
      );
    },
  );
}
