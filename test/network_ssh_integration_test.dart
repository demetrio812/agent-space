import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/image_attachments.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/network_backend.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/protocol.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final python = Platform.environment['AGENTSPACE_TEST_PYTHON'];
  final skip = python == null
      ? 'Set AGENTSPACE_TEST_PYTHON for disposable network SSH.'
      : false;
  late Directory directory;
  late Process fixture;
  late ConnectionProfile profile;
  late MemoryCredentialVault vault;
  late int controlPort;
  final backends = <NetworkHerdrBackend>[];
  NetworkHerdrBackend backend() {
    final value = NetworkHerdrBackend.remote(profile, vault);
    backends.add(value);
    return value;
  }

  Future<Map<String, dynamic>> control(
    String op, {
    String node = 'gateway',
    Map<String, dynamic> data = const {},
  }) async {
    final socket = await Socket.connect('127.0.0.1', controlPort);
    try {
      socket.write('${jsonEncode({'op': op, 'node': node, ...data})}\n');
      return jsonDecode(
        await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15)),
      ) as Map<String, dynamic>;
    } finally {
      socket.destroy();
    }
  }

  List<dynamic> sends(Map stats, String node) =>
      (stats['nodes'][node]['api'] as List)
          .where((r) => (r['method'] as String).startsWith('pane.send'))
          .toList();
  SessionInfo peer(List<SessionInfo> rows, String name) => rows.singleWhere(
    (s) => s.origin!.machineId == List.filled(32, name).join(),
  );
  int count(Map stats, String field) =>
      (stats['events'] as List).where((e) => e[field] != null).length;
  Future<void> workersGone() async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    Map stats = await control('stats');
    while ((stats['workers'] as List).isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stats = await control('stats');
    }
    expect(stats['workers'], isEmpty);
    expect(
      (stats['nodes'] as Map).values.every(
        (v) => (v['observers'] as List).isEmpty,
      ),
      true,
    );
    expect(
      (stats['nodes'] as Map).values.every(
        (v) => (v['cache'] as List).isNotEmpty,
      ),
      true,
    );
  }

  setUp(() async {
    if (python == null) return;
    directory = Directory(
      await (await Directory('/tmp').createTemp('an-')).resolveSymbolicLinks(),
    );
    fixture = await Process.start(python, [
      'test/fixtures/network_ssh_fixture.py',
      directory.path,
    ]);
    fixture.stderr
        .transform(utf8.decoder)
        .listen((line) => stderr.write('Network fixture: $line'));
    final ready = jsonDecode(
      await fixture.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 20)),
    ) as Map;
    controlPort = ready['controlPort'];
    profile = ConnectionProfile(
      id: 'network-test',
      label: 'Disposable gateway',
      kind: ConnectionKind.ssh,
      host: '127.0.0.1',
      port: ready['gateway']['port'],
      username: 'fixture',
      hostFingerprint: ready['gateway']['fingerprint'],
    );
    vault = MemoryCredentialVault();
    await vault.write(profile.id, const SshCredentials(password: 'disposable'));
  });
  tearDown(() async {
    if (python == null) return;
    for (final value in backends) {
      await value.close();
    }
    backends.clear();
    for (final node in ['gateway', 'a', 'b']) {
      final error = File('${directory.path}/$node/errors.log');
      if (await error.exists()) {
        stderr.writeln('Synthetic $node: ${await error.readAsString()}');
      }
    }
    fixture.kill();
    try {
      await fixture.exitCode.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      fixture.kill(ProcessSignal.sigkill);
      await fixture.exitCode;
    }
    await directory.delete(recursive: true);
  });
  List<dynamic> mutations(Map stats, String node) =>
      (stats['nodes'][node]['api'] as List)
          .where(
            (r) => const {
              'pane.rename',
              'pane.close',
              'tab.create',
              'workspace.create',
            }.contains(r['method']),
          )
          .toList();
  Future<void> waitFor(Future<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (!await ready() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    expect(
      await ready(),
      true,
      reason: 'Synthetic state: ${await control("stats")}',
    );
  }

  final disposableImage = Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    1,
    2,
    3,
  ]);
  ImageSource dropped() =>
      ImageSource(name: 'disposable.png', read: () async => disposableImage);
  Future<AppController> imageApp(LayoutStore store) async {
    final app = AppController(
      snapshot: AppSnapshot()..activeSource = profile.id,
      store: store,
      backendFactory: (_) => backend(),
    );
    await app.start(polling: false);
    await waitFor(
      () async => app.sessions.any((s) => s.origin?.machineId == 'b' * 32),
    );
    app.select(peer(app.sessions, 'b').key.id);
    return app;
  }

  test(
    'SSH image drop reaches named peer while typing and preview continue; lost insertion survives restart',
    () async {
      final store = LayoutStore('${directory.path}/state');
      final app = await imageApp(store);
      final b = peer(app.sessions, 'b');
      try {
        await control('flag', node: 'b', data: {'flag': 'hold-image.chunk'});
        final drop = app.dropImages(b.key.id, [dropped()]);
        await waitFor(
          () async => (await control('stats'))['events'].any(
            (e) => e['node'] == 'b' && e['held'] == 'image.chunk',
          ),
        );
        app.sendTerminalInput(b.key.id, TerminalInput.text('during upload '));
        await waitFor(
          () async =>
              sends(await control('stats'), 'b').length == 1 &&
              app.terminals[b.key.id]?.screen.terminal != null,
        );
        await control(
          'flag',
          node: 'b',
          data: {'flag': 'hold-image.chunk', 'enabled': false},
        );
        await drop;
        expect(app.imageDrops[b.key.id]!.phase, ImageDropPhase.complete);
        final files = await control('attachments');
        expect(files['gateway'], isEmpty);
        expect(files['a'], isEmpty);
        expect(files['b'], hasLength(1));
        final file = (files['b'] as List).single as Map;
        expect(base64Decode(file['bytes']), disposableImage);
        expect(file['mode'], 384);
        var stats = await control('stats');
        expect(sends(stats, 'gateway'), isEmpty);
        expect(sends(stats, 'a'), isEmpty);
        expect(sends(stats, 'b').last['method'], 'pane.send_input');
        expect(sends(stats, 'b').last['params'], {
          'pane_id': 'p1',
          'text': file['path'],
          'keys': <String>[],
        });
        await control('lost-ack', node: 'b');
        await app.dropImages(b.key.id, [dropped()]);
        expect(app.imageDrops[b.key.id]!.phase, ImageDropPhase.uncertain);
        await app.flush();
        final saved = await store.load();
        expect(
          saved.layoutFor(profile.id).uncertainDeliveries,
          contains(b.key.id),
        );
        await app.shutdown();
        final next = AppController(
          snapshot: saved,
          store: store,
          backendFactory: (_) => backend(),
        );
        try {
          await next.start(polling: false);
          await waitFor(() async => next.sessions.any((s) => s.key == b.key));
          next.select(b.key.id);
          expect(next.canDropImages(b.key.id), false);
          await next.retryImageDrop(b.key.id);
          next.sendTerminalInput(b.key.id, TerminalInput.text('never replay'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          stats = await control('stats');
          expect(sends(stats, 'b'), hasLength(3));
          expect((await control('attachments'))['b'], hasLength(2));
        } finally {
          await next.shutdown();
        }
      } finally {
        await app.shutdown();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 75)),
  );
  for (final boundary in [
    'selection',
    'background',
    'retarget',
    'after-finish',
  ]) {
    test(
      'SSH image $boundary change never inserts into a pane',
      () async {
        final app = await imageApp(LayoutStore('${directory.path}/state'));
        final b = peer(app.sessions, 'b');
        final operation = boundary == 'after-finish' || boundary == 'retarget'
            ? 'image.finish'
            : 'image.chunk';
        try {
          await control('flag', node: 'b', data: {'flag': 'hold-$operation'});
          final drop = app.dropImages(b.key.id, [dropped()]);
          await waitFor(
            () async => (await control(
              'stats',
            ))['events'].any((e) => e['node'] == 'b' && e['held'] == operation),
          );
          if (boundary == 'background') {
            await app.setActive(false);
          } else if (boundary == 'retarget') {
            await control(
              'route',
              data: {
                'machine': 'b' * 32,
                'changes': {'target': 'replacement'},
              },
            );
          } else {
            app.overview();
          }
          await control(
            'flag',
            node: 'b',
            data: {'flag': 'hold-$operation', 'enabled': false},
          );
          await drop;
          final stats = await control('stats');
          for (final n in ['gateway', 'a', 'b']) {
            expect(sends(stats, n), isEmpty);
          }
          final files = await control('attachments');
          expect(
            (files['b'] as List).where((f) => f['path'].endsWith('.part')),
            isEmpty,
          );
        } finally {
          await app.shutdown();
        }
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  test('attached peer scroll reveals earlier output and returns to live without keyboard input', () async {
    await control('flag', node: 'b', data: {'flag': 'mouse-report'});
    final value = backend();
    final sessions = await value.listSessions();
    final a = peer(sessions, 'a'), b = peer(sessions, 'b');
    final aFrames = <String>[], bFrames = <String>[];
    final aView = value.observeViewport(a, 90, 30).listen((e) {
      if (e is TerminalFrame) aFrames.add(utf8.decode(e.bytes));
    });
    final bView = value.observeViewport(b, 90, 30).listen((e) {
      if (e is TerminalFrame) bFrames.add(utf8.decode(e.bytes));
    });
    Future<void> until(bool Function() ready, String stage) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        ready(),
        true,
        reason: '$stage: A=$aFrames B=$bFrames stats=${await control("stats")}',
      );
    }

    try {
      await until(() => aFrames.isNotEmpty && bFrames.isNotEmpty, 'initial');
      await value.scrollTerminal(b, -9);
      await until(() => bFrames.last.contains('offset=9'), 'scroll');
      expect(aFrames.last, contains('offset=0'));
      await value.sendTerminalInput(b, const TerminalInput.click(12, 25));
      await until(() => bFrames.last.contains('offset=0'), 'click');
      final stats = await control('stats');
      for (final n in ['gateway', 'a', 'b']) {
        expect(sends(stats, n), isEmpty);
      }
      expect(stats['nodes']['a']['mouse'], isEmpty);
      expect(stats['nodes']['gateway']['mouse'], isEmpty);
      expect((stats['nodes']['b']['mouse'] as List).map((r) => r['action']), [
        'down',
        'up',
      ]);
      await bView.cancel();
      await expectLater(value.scrollTerminal(b, -1), throwsException);
    } finally {
      await aView.cancel();
      await bView.cancel();
    }
  }, skip: skip);

  test(
    'workspace SSH creates only on the selected peer',
    () async {
      final value = backend();
      final b = peer(await value.listSessions(), 'b');
      final computer = value.sessionComputers.singleWhere(
        (c) => c.origin.machineId == b.origin!.machineId,
      );
      final created = await value.createWorkspace(
        computer.origin,
        title: 'Research',
        cwd: '~/research',
      );
      expect(created.origin!.machineId, b.origin!.machineId);
      expect(created.workspaceId, 'new-workspace');
      expect(created.agent, 'terminal');
      final stats = await control('stats');
      expect(mutations(stats, 'gateway'), isEmpty);
      expect(mutations(stats, 'a'), isEmpty);
      expect(mutations(stats, 'b').map((r) => r['method']), [
        'workspace.create',
      ]);
      expect(mutations(stats, 'b').single['params']['label'], 'Research');
      expect(mutations(stats, 'b').single['params']['focus'], false);
      expect(
        value.sessionComputers
            .singleWhere((c) => c.origin.machineId == b.origin!.machineId)
            .workspaces
            .last
            .label,
        'Research',
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'management SSH routes shells to the named peer and preserves existing keyboard stream',
    () async {
      final value = backend();
      final rows = await value.listSessions();
      final b = peer(rows, 'b');
      final computer = value.sessionComputers.singleWhere(
        (c) => c.origin.machineId == b.origin!.machineId,
      );
      expect(computer.origin.herdrSession, 'work');
      expect(computer.managementEnabled, true);
      var ended = false;
      final frames = <TerminalFrame>[];
      final observation = value.observeViewport(b, 90, 30).listen((event) {
        if (event is TerminalFrame) frames.add(event);
      }, onDone: () => ended = true);
      try {
        final until = DateTime.now().add(const Duration(seconds: 10));
        while (frames.isEmpty && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(frames, isNotEmpty);
        await value.renameSession(b, 'Peer B renamed');
        final created = await value.createSession(
          computer.origin,
          computer.workspaces.single,
          title: 'Disposable shell',
          cwd: '~/project',
        );
        expect(created.origin!.machineId, b.origin!.machineId);
        expect(created.agent, 'terminal');
        expect(created.key.terminal, 'new-terminal');
        await value.closeSession(created);
        await value.sendTerminalInput(
          b,
          TerminalInput.keys(['up', 'ctrl+enter', 'cmd+backspace']),
        );
        await value.resizeViewport(b, 80, 25);
        final resized = DateTime.now().add(const Duration(seconds: 5));
        while (!frames.any((f) => f.width == 80) &&
            DateTime.now().isBefore(resized)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(ended, false);
        expect(frames.any((f) => f.width == 80), true);
        final stats = await control('stats');
        expect(mutations(stats, 'a'), isEmpty);
        expect(mutations(stats, 'gateway'), isEmpty);
        expect(mutations(stats, 'b').map((r) => r['method']), [
          'pane.rename',
          'tab.create',
          'pane.close',
        ]);
        expect((mutations(stats, 'b')[1]['params'] as Map)['focus'], false);
        final remaining = await value.listSessions();
        expect(peer(remaining, 'b').title, 'Peer B renamed');
        await control(
          'route',
          data: {
            'machine': 'b' * 32,
            'changes': {'target': 'replacement'},
          },
        );
        await expectLater(
          value.closeSession(b),
          throwsA(isA<ConnectionFailure>()),
        );
        expect(mutations(await control('stats'), 'b'), hasLength(3));
      } finally {
        await observation.cancel();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'management lost create acknowledgement survives restart without replay and leaves typing available',
    () async {
      final store = LayoutStore(directory.path);
      final snapshot = AppSnapshot()..activeSource = profile.id;
      final app = AppController(
        snapshot: snapshot,
        store: store,
        backendFactory: (_) => backend(),
      );
      try {
        await app.start(polling: false);
        final until = DateTime.now().add(const Duration(seconds: 15));
        while (!app.computers.any(
              (c) =>
                  c.origin.machineId == 'b' * 32 &&
                  c.state == ComputerState.live,
            ) &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final b = peer(app.sessions, 'b'),
            computer = app.computers.singleWhere(
              (c) => c.origin.machineId == 'b' * 32,
            );
        await control('lost-management-ack', node: 'b');
        await expectLater(
          app.createSession(
            computer.origin,
            computer.workspaces.single,
            title: 'Unconfirmed shell',
          ),
          throwsA(isA<SessionActionUncertain>()),
        );
        expect(
          app.layout.uncertainActions.containsKey(computer.origin.computerId),
          true,
        );
        expect(app.layout.uncertainDeliveries, isEmpty);
        await app.flush();
        final saved = await store.load();
        await app.shutdown();
        final next = AppController(
          snapshot: saved,
          store: store,
          backendFactory: (_) => backend(),
        );
        try {
          await next.start(polling: false);
          final limit = DateTime.now().add(const Duration(seconds: 15));
          while (!next.sessions.any(
                (s) =>
                    s.origin?.machineId == 'b' * 32 &&
                    s.key.terminal == 'new-terminal',
              ) &&
              DateTime.now().isBefore(limit)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final created = next.sessions.singleWhere(
            (s) =>
                s.origin?.machineId == 'b' * 32 &&
                s.key.terminal == 'new-terminal',
          );
          expect(created.title, 'Unconfirmed shell');
          await expectLater(
            next.closeSession(b),
            throwsA(isA<SessionUnavailable>()),
          );
          expect(
            mutations(
              await control('stats'),
              'b',
            ).where((r) => r['method'] == 'tab.create'),
            hasLength(1),
          );
          next.select(b.key.id);
          next.sendTerminalInput(
            b.key.id,
            const TerminalInput.text('still allowed'),
          );
          final sentUntil = DateTime.now().add(const Duration(seconds: 5));
          while (sends(await control('stats'), 'b').isEmpty &&
              DateTime.now().isBefore(sentUntil)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(sends(await control('stats'), 'b'), hasLength(1));
          next.acknowledgeSessionAction(computer.origin.computerId);
          await next.closeSession(created);
          final stats = await control('stats');
          expect(mutations(stats, 'a'), isEmpty);
          expect(mutations(stats, 'gateway'), isEmpty);
          expect(mutations(stats, 'b').map((r) => r['method']), [
            'tab.create',
            'pane.close',
          ]);
        } finally {
          await next.shutdown();
        }
      } finally {
        await app.shutdown();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 70)),
  );

  test(
    'gateway OpenSSH routes colliding peers; warm keys and zoom reuse workers',
    () async {
      final value = backend();
      final rows = await value.listSessions();
      expect(rows, hasLength(3));
      expect(rows.map((s) => s.key.id).toSet(), hasLength(3));
      final a = peer(rows, 'a'), b = peer(rows, 'b');
      expect(a.workspaceFilterId, isNot(b.workspaceFilterId));
      final frames = <TerminalFrame>[];
      final viewport = value.observeViewport(b, 90, 30).listen((event) {
        if (event is TerminalFrame) frames.add(event);
      });
      final previews = <TerminalFrame>[];
      final preview = value.observe(a).listen((event) {
        if (event is TerminalFrame) previews.add(event);
      }, onError: (Object _) {});
      final until = DateTime.now().add(const Duration(seconds: 15));
      while ((frames.isEmpty || previews.isEmpty) &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(frames, isNotEmpty);
      expect(previews, isNotEmpty);
      await value.sendTerminalInput(
        b,
        const TerminalInput.text('café 世界; literal'),
      );
      await value.sendTerminalInput(
        b,
        TerminalInput.keys(['cmd+backspace', 'ctrl+enter', 'up']),
      );
      final warm = await control('stats');
      for (var i = 0; i < 20; i++) {
        await value.sendTerminalInput(b, TerminalInput.keys(['left']));
      }
      await value.resizeViewport(b, 80, 25);
      final resizedUntil = DateTime.now().add(const Duration(seconds: 5));
      while (!frames.any((f) => f.width == 80 && f.height == 25) &&
          DateTime.now().isBefore(resizedUntil)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(frames.any((f) => f.width == 80 && f.height == 25), true);
      await value.listSessions();
      final after = await control('stats');
      expect(count(after, 'exec'), count(warm, 'exec'));
      expect(count(after, 'upload'), count(warm, 'upload'));
      expect(sends(after, 'gateway'), isEmpty);
      expect(sends(after, 'a'), isEmpty);
      expect(sends(after, 'b'), hasLength(22));
      expect(sends(after, 'b').first['params']['text'], 'café 世界; literal');
      expect(sends(after, 'b')[1]['params']['keys'], [
        'cmd+backspace',
        'ctrl+enter',
        'up',
      ]);
      final cliA = (after['nodes']['a']['cli'] as List)
          .map((line) => jsonDecode(line) as List)
          .toList();
      final cliB = (after['nodes']['b']['cli'] as List)
          .map((line) => jsonDecode(line) as List)
          .toList();
      expect(cliA.any((args) => args.contains('observe')), true);
      expect(cliA.any((args) => args.contains('control')), false);
      expect(cliB.any((args) => args.contains('control')), true);
      expect(
        [...cliA, ...cliB].any(
          (args) =>
              args.contains('machine') ||
              args.contains('--takeover') ||
              args.contains('start') ||
              args.contains('stop'),
        ),
        false,
      );
      await preview.cancel();
      await viewport.cancel();
      await value.close();
      await workersGone();
      final restarted = backend();
      expect(await restarted.listSessions(), hasLength(3));
      expect(count(await control('stats'), 'upload'), count(after, 'upload'));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'stalled discovery and flooding peer never block another peer input',
    () async {
      final value = backend();
      final rows = await value.listSessions();
      final a = peer(rows, 'a'), b = peer(rows, 'b');
      final preview = value.observe(a).listen((_) {}, onError: (Object _) {});
      await value.sendTerminalInput(b, TerminalInput.keys(['up']));
      await control('flag', node: 'a', data: {'flag': 'stall-discovery'});
      await control('flag', node: 'a', data: {'flag': 'flood'});
      final refresh = value.listSessions();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await value
          .sendTerminalInput(b, TerminalInput.keys(['ctrl+enter']))
          .timeout(const Duration(seconds: 3));
      expect(sends(await control('stats'), 'b'), hasLength(2));
      final updated = await refresh;
      expect(peer(updated, 'b').available, true);
      await preview.cancel();
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 50)),
  );

  test(
    'retarget, disable and peer restart reject before any wrong delivery',
    () async {
      final value = backend();
      final b = peer(await value.listSessions(), 'b');
      await control(
        'route',
        data: {
          'machine': b.origin!.machineId,
          'changes': {'target': 'peer-a'},
        },
      );
      await expectLater(
        value.sendTerminalInput(b, const TerminalInput.text('never redirect')),
        throwsA(isA<SessionUnavailable>()),
      );
      await control(
        'route',
        data: {
          'machine': b.origin!.machineId,
          'changes': {'target': 'peer-b', 'enabled': false},
        },
      );
      await expectLater(
        value.sendTerminalInput(b, const TerminalInput.text('disabled')),
        throwsA(isA<SessionUnavailable>()),
      );
      await control(
        'route',
        data: {
          'machine': b.origin!.machineId,
          'changes': {'enabled': true},
        },
      );
      await control('replace', node: 'b');
      await expectLater(
        value.sendTerminalInput(b, const TerminalInput.text('old generation')),
        throwsA(isA<SessionUnavailable>()),
      );
      final stats = await control('stats');
      expect(sends(stats, 'a'), isEmpty);
      expect(sends(stats, 'b'), isEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  for (final flag in [
    'deny-auth',
    'missing-python',
    'older-herdr',
    'bad-host',
  ]) {
    test(
      '$flag affects one computer while healthy sessions remain usable',
      () async {
        if (flag == 'bad-host') {
          await control('bad-host');
        } else {
          await control('flag', node: 'a', data: {'flag': flag});
        }
        final value = backend();
        final updates = await value
            .discover(epoch: 1, priorityMachines: {})
            .toList();
        final last = updates.last;
        expect(
          last.computers
              .singleWhere(
                (c) => c.origin.machineId == List.filled(32, 'a').join(),
              )
              .state,
          ComputerState.attention,
        );
        final b = peer(last.sessions, 'b');
        expect(b.available, true);
        await value.sendTerminalInput(b, TerminalInput.keys(['up']));
        expect(sends(await control('stats'), 'b'), hasLength(1));
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  test(
    'lost gateway acknowledgement persists uncertainty and never replays',
    () async {
      final value = backend();
      final store = LayoutStore('${directory.path}/layout.json');
      final snapshot = AppSnapshot()
        ..activeSource = profile.id
        ..profiles.add(profile);
      final app = AppController(
        store: store,
        snapshot: snapshot,
        backendFactory: (_) => value,
      );
      try {
        await app.start(polling: false);
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!app.sessions.any(
              (s) => s.origin?.machineId == List.filled(32, 'b').join(),
            ) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final b = peer(app.sessions, 'b');
        app.select(b.key.id);
        await control('flag', data: {'flag': 'kill-after-dispatch'});
        app.sendTerminalInput(
          b.key.id,
          const TerminalInput.text('one attempt'),
        );
        final wait = DateTime.now().add(const Duration(seconds: 15));
        while (!app.layout.uncertainDeliveries.contains(b.key.id) &&
            DateTime.now().isBefore(wait)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        // The marker precedes dispatch; wait for the observed mutation and the
        // completed queue rather than assuming SSH setup finishes in two seconds.
        await waitFor(
          () async =>
              !app.terminalInputPending(b.key.id) &&
              sends(await control('stats'), 'b').length == 1,
        );
        app.sendTerminalInput(b.key.id, const TerminalInput.text('blocked'));
        await app.flush();
        final saved = await store.load();
        expect(
          saved.layoutFor(profile.id).uncertainDeliveries,
          contains(b.key.id),
        );
        expect(sends(await control('stats'), 'b'), hasLength(1));
        await app.shutdown();
        final next = AppController(
          store: store,
          snapshot: saved,
          backendFactory: (_) => backend(),
        );
        try {
          await next.start(polling: false);
          await Future<void>.delayed(const Duration(seconds: 1));
          next.sendTerminalInput(
            b.key.id,
            const TerminalInput.text('still blocked'),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(sends(await control('stats'), 'b'), hasLength(1));
        } finally {
          await next.shutdown();
        }
      } finally {
        await app.shutdown();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
