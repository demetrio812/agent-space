import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final python = Platform.environment['AGENTSPACE_TEST_PYTHON'];
  late Directory directory;
  late Process server;
  Process? apiServer;
  late ConnectionProfile profile;
  late MemoryCredentialVault vault;
  Future<void> normalShell() async {
    await File('${directory.path}/normal-shell').writeAsString('fixture');
    await Directory('${directory.path}/.config/herdr').create(recursive: true);
    await Directory('${directory.path}/.local/bin').create(recursive: true);
    final cli = await File('test/fixtures/normal_ssh_herdr.py')
        .copy('${directory.path}/.local/bin/herdr');
    await Process.run('chmod', ['700', cli.path]);
    apiServer = await Process.start(python!, [
      'test/fixtures/fake_herdr_api.py',
      directory.path,
    ]);
    apiServer!.stderr.drain<void>();
    await apiServer!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
  }

  Future<List<dynamic>> herdrCalls() async => (await File(
    '${directory.path}/herdr-calls.jsonl',
  ).readAsLines()).map(jsonDecode).toList();
  Future<List<dynamic>> events() async => (await File(
    '${directory.path}/events.jsonl',
  ).readAsLines()).map(jsonDecode).toList();
  Future<List<dynamic>> apiCalls() async => (await File(
    '${directory.path}/api-calls.jsonl',
  ).readAsLines()).map(jsonDecode).toList();
  setUp(() async {
    if (python == null) return;
    final created = await Directory('/tmp').createTemp('agentspace-ssh-');
    directory = Directory(await created.resolveSymbolicLinks());
    server = await Process.start(python, [
      'test/fixtures/ssh_server.py',
      directory.path,
    ]);
    // Fixture stderr is drained without retaining handshake details.
    server.stderr.drain<void>();
    final ready = jsonDecode(
      await server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15)),
    ) as Map;
    profile = ConnectionProfile(
      id: 'remote',
      label: 'Disposable SSH',
      kind: ConnectionKind.ssh,
      host: '127.0.0.1',
      port: ready['port'] as int,
      username: 'fixture',
      hostFingerprint: ready['fingerprint'] as String,
    );
    vault = MemoryCredentialVault();
    await vault.write(profile.id, const SshCredentials(password: 'disposable'));
  });
  tearDown(() async {
    if (python == null) return;
    server.kill();
    await server.exitCode;
    apiServer?.kill();
    await apiServer?.exitCode;
    apiServer = null;
    final errors = File('${directory.path}/bridge-errors.log');
    if (await errors.exists()) {
      await errors.copy('../../work/network-latest-ssh-errors.log');
    }
    await directory.delete(recursive: true);
  });
  test(
    'ordinary SSH finds account Python when PATH interpreter is broken',
    () async {
      await normalShell();
      await File('${directory.path}/broken-python').writeAsString('fixture');
      await Link('${directory.path}/.local/bin/python3').create(python!);
      final cli = File('${directory.path}/.local/bin/herdr');
      final source = await cli.readAsString();
      await cli.writeAsString(
        source.replaceFirst('#!/usr/bin/env python3', '#!$python'),
      );
      final backend = RemoteHerdrBackend(profile, vault);
      addTearDown(backend.close);
      expect((await backend.listSessions()).single.title, 'Normal SSH fixture');
    },
    skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false,
  );
  test(
    'warm keys and refreshes add no exec or upload; reconnect reuses digest',
    () async {
      await normalShell();
      var backend = RemoteHerdrBackend(profile, vault);
      try {
        final session = (await backend.listSessions()).single;
        await backend.sendTerminalInput(
          session,
          const TerminalInput.text('warm'),
        );
        final before = await events();
        final execs = before.where((e) => e['command'] != null).length;
        final uploads = before.where((e) => e['upload'] != null).length;
        expect(uploads, 1);
        for (var i = 0; i < 20; i++) {
          await backend.sendTerminalInput(session, TerminalInput.keys(['up']));
        }
        await backend.listSessions();
        await backend.listSessions();
        final after = await events();
        expect(after.where((e) => e['command'] != null), hasLength(execs));
        expect(after.where((e) => e['upload'] != null), hasLength(uploads));
        await backend.close();
        backend = RemoteHerdrBackend(profile, vault);
        await backend.listSessions();
        expect(
          (await events()).where((e) => e['upload'] != null),
          hasLength(uploads),
        );
      } finally {
        await backend.close();
      }
    },
    skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false,
  );
  test('a changed package version uploads once into a separate cache', () async {
    await normalShell();
    var backend = RemoteHerdrBackend(profile, vault);
    try {
      await backend.listSessions();
      await backend.close();
      final data = await rootBundle.load('assets/bridge.pyz');
      final bootstrap = await rootBundle.load('assets/bridge-bootstrap.py');
      final launcher = await rootBundle.load('assets/bridge-launcher.sh');
      final old = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final changed = Uint8List(old.length + 3)..setRange(0, old.length, old);
      // ZIP comment changes version bytes without changing executable modules.
      changed[old.length - 2] = 3;
      changed[old.length - 1] = 0;
      changed.setRange(old.length, changed.length, [118, 50, 33]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', (message) async {
            final key = utf8.decode(
              message!.buffer.asUint8List(
                message.offsetInBytes,
                message.lengthInBytes,
              ),
            );
            return key == 'assets/bridge.pyz'
                ? ByteData.sublistView(changed)
                : key == 'assets/bridge-launcher.sh'
                ? launcher
                : bootstrap;
          });
      backend = RemoteHerdrBackend(profile, vault);
      final session = (await backend.listSessions()).single;
      await backend.sendTerminalInput(
        session,
        const TerminalInput.text('changed version'),
      );
      await backend.listSessions();
      final uploads = (await events())
          .where((e) => e['upload'] != null)
          .toList();
      expect(uploads, hasLength(2));
      expect(uploads[0]['upload'], isNot(uploads[1]['upload']));
    } finally {
      await backend.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
    }
  }, skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false);
  test(
    'normal password SSH reuses private workers and preserves literal input',
    () async {
      await normalShell();
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        final session = (await backend.listSessions()).single;
        expect(session.title, 'Normal SSH fixture');
        expect(session.workspaceLabel, 'Fixture workspace');
        expect(session.inputEnabled, isTrue);
        final frames = await backend.observe(session).toList();
        expect((frames.first as TerminalFrame).width, 90);
        const message = 'café; \$(echo harmless)\nsecond line';
        await backend.sendText(session, message);
        await backend.sendTerminalInput(
          session,
          const TerminalInput.text('nativeaaaa'),
        );
        await backend.sendTerminalInput(
          session,
          TerminalInput.keys(['up', 'ctrl+enter', 'cmd+backspace']),
        );
        final calls = await apiCalls();
        expect(
          calls
              .where((c) => c['method'] == 'pane.send_input')
              .map((c) => c['params'])
              .toList(),
          [
            {
              'pane_id': 'p1',
              'text': message,
              'keys': ['Enter'],
            },
          ],
        );
        expect(
          calls,
          contains(
            predicate(
              (dynamic c) =>
                  c['method'] == 'pane.send_text' &&
                  c['params']['text'] == 'nativeaaaa',
            ),
          ),
        );
        expect(
          calls,
          contains(
            predicate(
              (dynamic c) =>
                  c['method'] == 'pane.send_keys' &&
                  jsonEncode(c['params']['keys']) ==
                      jsonEncode(['up', 'ctrl+enter', 'cmd+backspace']),
            ),
          ),
        );
        expect(
          (await events()).where(
            (e) => e['command'] == 'agentspace-catalog-v1',
          ),
          hasLength(1),
        );
      } finally {
        await backend.close();
      }
    },
    skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false,
  );
  test('custom tilde paths remain data resolved in the SSH account', () async {
    await normalShell();
    profile.executable = '~/.local/bin/herdr';
    profile.socketPath = '~/.config/herdr/herdr.sock';
    final backend = RemoteHerdrBackend(profile, vault);
    try {
      expect((await backend.listSessions()).single.title, 'Normal SSH fixture');
    } finally {
      await backend.close();
    }
  }, skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false);
  test(
    'restricted gate failures do not switch to an ordinary SSH bridge',
    () async {
      await File('${directory.path}/gate-denied').writeAsString('fixture');
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        await expectLater(
          backend.listSessions(),
          throwsA(isA<ConnectionFailure>()),
        );
        expect(
          (await events())
              .where((e) => e['command'] != null)
              .map((e) => e['command']),
          ['agentspace-catalog-v1'],
        );
      } finally {
        await backend.close();
      }
    },
    skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false,
  );
  test(
    'ordinary SSH input failure remains uncertain and is never retried',
    () async {
      await normalShell();
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        final session = (await backend.listSessions()).single;
        await File('${directory.path}/fail-after-input')
            .writeAsString('fixture');
        await expectLater(
          backend.sendText(session, 'one submission'),
          throwsA(isA<DeliveryUncertain>()),
        );
        expect(
          (await apiCalls()).where((c) => c['method'] == 'pane.send_input'),
          hasLength(1),
        );
      } finally {
        await backend.close();
      }
    },
    skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false,
  );
  test('ordinary SSH bridge preserves stdin for viewport resizing', () async {
    await normalShell();
    final backend = RemoteHerdrBackend(profile, vault);
    try {
      final session = (await backend.listSessions()).single;
      final ready = Completer<void>(), resized = Completer<void>();
      final sub = backend.observeViewport(session, 90, 30).listen((event) {
        if (event is TerminalFrame) {
          if (!ready.isCompleted) ready.complete();
          if (event.width == 80 && event.height == 25 && !resized.isCompleted) {
            resized.complete();
          }
        }
      });
      await ready.future.timeout(const Duration(seconds: 5));
      await backend.resizeViewport(session, 80, 25);
      await resized.future.timeout(const Duration(seconds: 5));
      expect(
        await herdrCalls(),
        contains(
          equals([
            'resize',
            {'type': 'terminal.resize', 'cols': 80, 'rows': 25},
          ]),
        ),
      );
      await sub.cancel();
    } finally {
      await backend.close();
    }
  }, skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false);
  for (final missing in ['executable', 'socket']) {
    test('ordinary SSH reports missing Herdr $missing clearly', () async {
      await normalShell();
      if (missing == 'executable') {
        profile.executable = '${directory.path}/no-herdr';
      } else {
        profile.socketPath = '${directory.path}/no-server.sock';
      }
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        await expectLater(
          backend.listSessions(),
          throwsA(
            isA<ConnectionFailure>()
                .having((error) => error.permanent, 'permanent', true)
                .having(
                  (error) => error.message,
                  'diagnostic',
                  contains(
                    missing == 'executable'
                        ? 'Herdr was not found'
                        : 'no running Herdr server',
                  ),
                ),
          ),
        );
      } finally {
        await backend.close();
      }
    }, skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false);
  }
  test('SSH viewport stream keeps one controller and sends resize without a PTY or takeover', () async {
    final backend = RemoteHerdrBackend(profile, vault);
    try {
      final session = (await backend.listSessions()).single;
      final frames = <TerminalFrame>[];
      final ready = Completer<void>();
      final changed = Completer<void>();
      final sub = backend.observeViewport(session, 90, 30).listen((event) {
        if (event is TerminalFrame) {
          frames.add(event);
          if (!ready.isCompleted) ready.complete();
          if (event.width == 80 && event.height == 25 && !changed.isCompleted) {
            changed.complete();
          }
        }
      });
      await ready.future;
      await backend.resizeViewport(session, 80, 25);
      await changed.future;
      expect(frames.first.width, 90);
      final log = await events();
      expect(
        log.where(
          (e) => (e['command'] as String? ?? '').startsWith(
            'agentspace-control-v1',
          ),
        ),
        hasLength(1),
      );
      expect(log.where((e) => e['resize'] != null).last['resize'], {
        'type': 'terminal.resize',
        'cols': 80,
        'rows': 25,
      });
      await sub.cancel();
    } finally {
      await backend.close();
    }
  }, skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false);
  test('stalled discovery cannot interrupt keyboard delivery', () async {
    final backend = RemoteHerdrBackend(profile, vault);
    try {
      final session = (await backend.listSessions()).single;
      await File('${directory.path}/hold-catalog-exec')
          .writeAsString('fixture');
      final discovery = expectLater(
        backend.listSessions(),
        throwsA(isA<TimeoutException>()),
      );
      // Wait until the fixture is holding the catalog exec acknowledgement.
      for (var i = 0; i < 100; i++) {
        if ((await events()).any((e) => e['held'] == true)) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await events()).any((e) => e['held'] == true), isTrue);
      await backend.sendTerminalInput(
        session,
        const TerminalInput.text('exactly once'),
      );
      await discovery;
      expect(
        (await events()).where(
          (e) =>
              (e['command'] as String? ?? '').startsWith('agentspace-input-v1'),
        ),
        hasLength(1),
      );
    } finally {
      await backend.close();
    }
  }, skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false);
  test(
    'a stalled input request does not disconnect the live terminal',
    () async {
      final backend = RemoteHerdrBackend(profile, vault);
      StreamSubscription<ObserveEvent>? sub;
      try {
        final session = (await backend.listSessions()).single;
        final ready = Completer<void>();
        final resized = Completer<void>();
        final failures = <Object>[];
        var ended = false;
        sub = backend
            .observeViewport(session, 90, 30)
            .listen(
              (event) {
                if (event is TerminalFrame) {
                  if (!ready.isCompleted) ready.complete();
                  if (event.width == 80 && !resized.isCompleted) {
                    resized.complete();
                  }
                }
              },
              onError: failures.add,
              onDone: () => ended = true,
            );
        await ready.future.timeout(const Duration(seconds: 5));
        await File('${directory.path}/hold-exec').writeAsString('fixture');
        await expectLater(
          backend.sendText(session, 'one submission'),
          throwsA(isA<DeliveryUncertain>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(failures, isEmpty);
        expect(ended, isFalse);
        await backend.resizeViewport(session, 80, 25);
        await resized.future.timeout(const Duration(seconds: 5));
        expect(
          (await events()).where(
            (e) => (e['command'] as String? ?? '').startsWith(
              'agentspace-send-v1',
            ),
          ),
          hasLength(1),
        );
      } finally {
        await sub?.cancel();
        await backend.close();
      }
    },
    skip: python == null ? 'Set AGENTSPACE_TEST_PYTHON.' : false,
  );
  test(
    'missing SSH exec acknowledgement ends as uncertain within the deadline',
    () async {
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        final session = (await backend.listSessions()).single;
        await File('${directory.path}/hold-exec').writeAsString('fixture');
        await expectLater(
          backend
              .sendText(session, 'one submission')
              .timeout(const Duration(seconds: 8)),
          throwsA(isA<DeliveryUncertain>()),
        );
        expect(
          (await events()).where(
            (e) => (e['command'] as String? ?? '').startsWith(
              'agentspace-send-v1',
            ),
          ),
          hasLength(1),
        );
      } finally {
        await backend.close();
      }
    },
    skip: python == null
        ? 'Set AGENTSPACE_TEST_PYTHON with test/requirements.txt installed.'
        : false,
  );
  test(
    'SSH catalog, framed observation and explicit input use the restricted gate',
    () async {
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        final session = (await backend.listSessions()).single;
        final frames = await backend.observe(session).toList();
        expect((frames.first as TerminalFrame).height, 55);
        const text = 'café; \$(echo harmless)\nsecond line';
        await backend.sendText(session, text);
        final beforeKeyboard = (await events())
            .where((e) => e['command'] != null)
            .length;
        await backend.sendTerminalInput(
          session,
          const TerminalInput.text(' café '),
        );
        await backend.sendTerminalInput(
          session,
          TerminalInput.keys(['up', 'ctrl+enter']),
        );
        final commands = (await events())
            .where((e) => e['command'] != null)
            .map((e) => e['command'])
            .toList();
        expect(
          commands.skip(beforeKeyboard),
          everyElement(startsWith('agentspace-input-v1')),
          reason: 'The restricted input gate checks the live target; keyboard input should not also refresh labels over SSH.',
        );
        expect(commands, contains('agentspace-observe-v1 ${'a' * 64} t1'));
        expect(commands.where((c) => c.startsWith('agentspace-send-v1')), [
          'agentspace-send-v1 ${'a' * 64} t1 ${base64Encode(utf8.encode(text))}',
        ]);
        final keyboard = commands
            .where((c) => c.startsWith('agentspace-input-v1'))
            .map(
              (c) => jsonDecode(
                utf8.decode(base64Decode((c as String).split(' ').last)),
              ),
            )
            .toList();
        expect(keyboard, [
          {'text': ' café '},
          {
            'keys': ['up', 'ctrl+enter'],
          },
        ]);
      } finally {
        await backend.close();
      }
    },
    skip: python == null
        ? 'Set AGENTSPACE_TEST_PYTHON with test/requirements.txt installed.'
        : false,
  );
  test(
    'a changed SSH identity is rejected before authentication',
    () async {
      profile.hostFingerprint = 'SHA256:wrong';
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        await expectLater(
          backend.listSessions(),
          throwsA(
            isA<ConnectionFailure>().having(
              (e) => e.permanent,
              'permanent',
              true,
            ),
          ),
        );
        final log = File('${directory.path}/events.jsonl');
        expect(await log.exists() ? await events() : [], isEmpty);
      } finally {
        await backend.close();
      }
    },
    skip: python == null
        ? 'Set AGENTSPACE_TEST_PYTHON with test/requirements.txt installed.'
        : false,
  );
  test(
    'a lost SSH send acknowledgement is uncertain and never retried',
    () async {
      final backend = RemoteHerdrBackend(profile, vault);
      try {
        final session = (await backend.listSessions()).single;
        await File('${directory.path}/early-close').writeAsString('fixture');
        await expectLater(
          backend.sendText(session, 'one submission'),
          throwsA(isA<DeliveryUncertain>()),
        );
        expect(
          (await events()).where(
            (e) => (e['command'] as String? ?? '').startsWith(
              'agentspace-send-v1',
            ),
          ),
          hasLength(1),
        );
      } finally {
        await backend.close();
      }
    },
    skip: python == null
        ? 'Set AGENTSPACE_TEST_PYTHON with test/requirements.txt installed.'
        : false,
  );
}
