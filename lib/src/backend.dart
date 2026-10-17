import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'protocol.dart';
import 'backend_errors.dart';
import 'bridge_protocol.dart';
import 'persistent_bridge.dart';
import 'ssh_bridge.dart';
import 'native_bridge.dart';
export 'backend_errors.dart';
export 'session_actions.dart';

part 'local_socket_backend.dart';
part 'helper_backend.dart';
part 'viewport_backend.dart';

class _CommandFailure extends ConnectionFailure {
  _CommandFailure(this.missingGate)
    : super(
        'Herdr could not complete the request. Check the connection and pairing.',
      );
  final bool missingGate;
}

abstract class SessionBackend {
  String get sourceId;
  Future<List<SessionInfo>> listSessions();
  Stream<ObserveEvent> observe(SessionInfo session);
  Future<void> sendText(SessionInfo session, String text);
  Future<void> close();
}

abstract interface class TerminalInputBackend {
  Future<void> sendTerminalInput(SessionInfo session, TerminalInput input);
}

abstract interface class TerminalScrollBackend {
  bool get terminalScrollEnabled;
  Future<void> scrollTerminal(SessionInfo session, int lines);
}

abstract interface class TerminalViewportBackend {
  Stream<ObserveEvent> observeViewport(SessionInfo session, int cols, int rows);
  Future<void> resizeViewport(SessionInfo session, int cols, int rows);
}

bool validViewport(int cols, int rows) =>
    cols >= 1 &&
    cols <= 512 &&
    rows >= 1 &&
    rows <= 256 &&
    cols * rows <= 65536;

class _Command {
  _Command(this.stdout, this.stderr, this.exit, this.stop, {this.resize});
  final Stream<List<int>> stdout, stderr;
  final Future<int?> exit;
  final void Function() stop;
  final Future<void> Function(int, int)? resize;
}

Future<Uint8List> _boundedBytes(Stream<List<int>> stream, int limit) async {
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in stream) {
    length += chunk.length;
    if (length > limit) {
      throw ConnectionFailure(
        'The response exceeded its size limit.',
        permanent: true,
      );
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<String> _readCommand(
  _Command command, {
  Duration timeout = const Duration(seconds: 6),
  bool input = false,
}) async {
  try {
    final results = await Future.wait<Object?>([
      _boundedBytes(command.stdout, maxCatalogBytes),
      _boundedBytes(command.stderr, 64 * 1024),
      command.exit,
    ], eagerError: true).timeout(timeout);
    if (results[2] != 0) {
      final error = utf8.decode(results[1] as Uint8List, allowMalformed: true);
      if (error.contains('AGENTSPACE_HERDR_MISSING')) {
        throw ConnectionFailure(
          'SSH connected, but Herdr was not found on this computer. Check its Herdr installation.',
          permanent: true,
        );
      }
      if (error.contains('AGENTSPACE_SOCKET_MISSING')) {
        throw ConnectionFailure(
          'SSH connected, but no running Herdr server was found. Start Herdr on this computer.',
          permanent: true,
        );
      }
      if (results[2] == 127 &&
          error.contains('python3') &&
          error.contains('not found')) {
        throw ConnectionFailure(
          'SSH connected, but this computer needs Python 3 to run the Herdr bridge.',
          permanent: true,
        );
      }
      throw _CommandFailure(
        results[2] == 127 &&
            error.contains('agentspace-catalog-v1') &&
            error.contains('not found'),
      );
    }
    return utf8.decode(results[0] as Uint8List);
  } catch (_) {
    if (input) throw DeliveryUncertain();
    rethrow;
  } finally {
    command.stop();
  }
}

Stream<ObserveEvent> decodeObservation(Stream<List<int>> source) async* {
  var pending = <int>[];
  await for (final chunk in source) {
    for (final byte in chunk) {
      if (byte == 10) {
        if (pending.isNotEmpty && pending.last == 13) pending.removeLast();
        final event = parseObserveLine(utf8.decode(pending));
        pending = [];
        yield event;
        if (event is TerminalClosed) return;
      } else {
        if (pending.length >= 2 * 1024 * 1024) {
          throw const FormatException('Terminal record exceeded 2 MiB.');
        }
        pending.add(byte);
      }
    }
  }
  throw ConnectionFailure('Terminal stream disconnected.');
}

Stream<ObserveEvent> _observeCommand(
  Future<_Command> Function() open, {
  void Function()? onCancel,
}) {
  _Command? command;
  var cancelled = false;
  late StreamController<ObserveEvent> controller;
  Future<void> start() async {
    try {
      command = await open();
      if (cancelled) return;
      final errors = _boundedBytes(command!.stderr, 64 * 1024);
      // Consume stderr concurrently so a noisy server cannot block stdout.
      unawaited(
        errors.catchError((Object error) {
          command?.stop();
          if (!cancelled && !controller.isClosed) controller.addError(error);
          return Uint8List(0);
        }),
      );
      await for (final event in decodeObservation(command!.stdout)) {
        if (cancelled) break;
        controller.add(event);
      }
    } catch (error, stack) {
      if (!cancelled && !controller.isClosed) controller.addError(error, stack);
    } finally {
      command?.stop();
      if (!controller.isClosed) unawaited(controller.close());
    }
  }

  controller = StreamController<ObserveEvent>(
    onListen: () => unawaited(start()),
    onCancel: () {
      cancelled = true;
      onCancel?.call();
      command?.stop();
    },
  );
  return controller.stream;
}

class LocalHerdrBackend
    with _ViewportSupport
    implements SessionBackend, TerminalInputBackend {
  LocalHerdrBackend(this.profile);
  final ConnectionProfile profile;
  bool get _supportsViewport => true;
  final _processes = <Process>{};
  bool _closed = false;
  @override
  String get sourceId => profile.id;
  Future<_Command> _spawn(
    List<String> arguments, {
    void Function(void Function())? onStopReady,
  }) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    if (!Platform.isMacOS) {
      throw ConnectionFailure(
        'Local Herdr is available on desktop. Use an SSH connection on this device.',
        permanent: true,
      );
    }
    if (!profile.executable.startsWith('/') || profile.socketPath.isEmpty) {
      throw ConnectionFailure(
        'Choose the Herdr executable and server socket in Settings.',
        permanent: true,
      );
    }
    try {
      final p = await Process.start(
        profile.executable,
        arguments,
        environment: {'HERDR_SOCKET_PATH': profile.socketPath},
      );
      _processes.add(p);
      onStopReady?.call(() => p.kill());
      if (_closed) p.kill();
      final control = arguments.take(3).join(' ') == 'terminal session control';
      if (!control) unawaited(p.stdin.close());
      unawaited(p.exitCode.then((_) => _processes.remove(p)));
      return _Command(
        p.stdout,
        p.stderr,
        p.exitCode,
        () => p.kill(),
        resize: control
            ? (cols, rows) async {
                if (!validViewport(cols, rows)) {
                  throw ArgumentError('Invalid terminal dimensions.');
                }
                p.stdin.writeln(
                  jsonEncode({
                    'type': 'terminal.resize',
                    'cols': cols,
                    'rows': rows,
                  }),
                );
                await p.stdin.flush();
              }
            : null,
      );
    } on ProcessException {
      throw ConnectionFailure(
        'Herdr could not be launched. Check its executable path in Settings.',
        permanent: true,
      );
    }
  }

  Future<String> _identity() async {
    try {
      final path = await File(profile.socketPath).resolveSymbolicLinks();
      final stat = await Process.run('/usr/bin/stat', [
        '-L',
        '-f',
        '%d:%i:%B',
        path,
      ]);
      if (stat.exitCode != 0 || (stat.stdout as String).trim().isEmpty) {
        throw const FileSystemException();
      }
      return sha256
          .convert(utf8.encode('$path:${(stat.stdout as String).trim()}'))
          .toString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 1 || error.osError?.errorCode == 13) {
        throw ConnectionFailure(
          'Allow access to local Herdr in Settings, then reconnect.',
          permanent: true,
        );
      }
      throw ConnectionFailure(
        'Herdr is offline. Start Herdr on this Mac, then reconnect.',
      );
    } catch (_) {
      throw ConnectionFailure(
        'Herdr is offline. Start Herdr on this Mac, then reconnect.',
      );
    }
  }

  Future<Map<String, dynamic>> _json(List<String> args) async {
    final raw = await _readCommand(await _spawn(args));
    try {
      final j = jsonDecode(raw);
      if (j is! Map || failedResponse(j)) throw const FormatException();
      return Map<String, dynamic>.from(j);
    } catch (_) {
      throw const FormatException('Herdr returned an invalid response.');
    }
  }

  @override
  Future<List<SessionInfo>> listSessions() => _catalog();

  Future<List<SessionInfo>> _catalog({bool includeLabels = true}) async {
    final identity = await _identity();
    final agents = await _json(['agent', 'list']);
    List<dynamic> workspaces = [], tabs = [];
    if (includeLabels) {
      try {
        final result = await _json(['workspace', 'list']);
        workspaces = result['result']?['workspaces'] as List? ?? [];
      } catch (_) {
        /* older Herdr versions omit labels */
      }
      try {
        final result = await _json(['tab', 'list']);
        tabs = result['result']?['tabs'] as List? ?? [];
      } catch (_) {
        /* generated titles remain available */
      }
    }
    if (identity != await _identity()) {
      throw ConnectionFailure('Herdr restarted during discovery. Reconnect.');
    }
    return parseCatalog(
      jsonEncode({
        'serverIdentity': identity,
        'catalog': agents,
        'workspaces': workspaces,
        'tabs': tabs,
        'inputEnabled': true,
        'terminalInputEnabled': true,
        'terminalViewportEnabled': _supportsViewport,
      }),
      profile.id,
    );
  }

  Future<SessionInfo> _validate(
    SessionInfo session, {
    bool includeLabels = true,
  }) async {
    if (session.key.backend != 'herdr' || session.key.profile != profile.id) {
      throw SessionUnavailable();
    }
    if (await _identity() != session.key.server) {
      throw SessionUnavailable(
        'Herdr restarted. This saved session belongs to the previous server.',
      );
    }
    final rows = await _catalog(includeLabels: includeLabels);
    final match = rows.where((s) => s.key == session.key).firstOrNull;
    if (match == null || !terminalIdPattern.hasMatch(match.paneId)) {
      throw SessionUnavailable();
    }
    return match;
  }

  @override
  Stream<ObserveEvent> observe(SessionInfo session) =>
      _observeCommand(() async {
        final current = await _validate(session);
        final dimensions = <String>[];
        try {
          final response = await _json([
            'pane',
            'layout',
            '--pane',
            current.paneId,
          ]);
          final panes = response['result']?['layout']?['panes'];
          if (panes is List) {
            final row = panes
                .whereType<Map>()
                .where((p) => p['pane_id'] == current.paneId)
                .firstOrNull;
            final w = row?['rect']?['width'], h = row?['rect']?['height'];
            if (w is int &&
                h is int &&
                w >= 1 &&
                w <= 512 &&
                h >= 1 &&
                h <= 256 &&
                w * h <= 65536) {
              dimensions.addAll(['--cols', '$w', '--rows', '$h']);
            }
          }
        } catch (_) {
          /* projection fallback for older servers */
        }
        if (await _identity() != session.key.server) throw SessionUnavailable();
        return _spawn([
          'terminal',
          'session',
          'observe',
          current.key.terminal,
          ...dimensions,
        ]);
      });
  @override
  Future<void> sendText(SessionInfo session, String text) async {
    final invalid = validateInput(text);
    if (invalid != null) throw ArgumentError(invalid);
    final current = await _validate(session);
    if (await _identity() != session.key.server) throw SessionUnavailable();
    final raw = await _readCommand(
      await _spawn(['pane', 'run', current.paneId, text]),
      input: true,
    );
    if (raw.trim().isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is! Map || failedResponse(j) || !j.containsKey('result')) {
          throw const FormatException();
        }
      } catch (_) {
        throw DeliveryUncertain();
      }
    }
  }

  @override
  Stream<ObserveEvent> observeViewport(
    SessionInfo session,
    int cols,
    int rows,
  ) => viewportStream(session, cols, rows, (view) async {
    final current = await _validate(session, includeLabels: false);
    if (!current.inputEnabled || await _identity() != session.key.server) {
      throw SessionUnavailable();
    }
    view.ensureActive();
    return _spawn([
      'terminal',
      'session',
      'control',
      session.key.terminal,
      '--cols',
      '${view.cols}',
      '--rows',
      '${view.rows}',
    ], onStopReady: view.bindStop);
  });

  @override
  Future<void> sendTerminalInput(
    SessionInfo session,
    TerminalInput input,
  ) async {
    if (input.isPaste) {
      throw SessionUnavailable('Terminal paste requires a persistent connection.');
    }
    if (input.clickCell != null) {
      throw SessionUnavailable(
        'Terminal clicks require an attached connection.',
      );
    }
    final invalid = input.validationError;
    if (invalid != null) throw ArgumentError(invalid);
    // Keyboard batches need current membership and pane identity, not display labels.
    final current = await _validate(session, includeLabels: false);
    if (!current.inputEnabled ||
        !current.terminalInputEnabled ||
        await _identity() != session.key.server) {
      throw SessionUnavailable();
    }
    final args = input.textValue != null
        ? ['pane', 'send-text', current.paneId, input.textValue!]
        : ['pane', 'send-keys', current.paneId, ...input.keyNames!];
    final raw = await _readCommand(await _spawn(args), input: true);
    if (raw.trim().isNotEmpty) {
      try {
        final j = jsonDecode(raw);
        if (j is! Map || failedResponse(j) || !j.containsKey('result')) {
          throw const FormatException();
        }
      } catch (_) {
        throw DeliveryUncertain();
      }
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final p in _processes.toList()) {
      p.kill();
    }
    _processes.clear();
  }
}

class SshCredentials {
  const SshCredentials({
    this.privateKey = '',
    this.password = '',
    this.passphrase = '',
  });
  final String privateKey, password, passphrase;
  Map<String, String> toJson() => {
    'privateKey': privateKey,
    'password': password,
    'passphrase': passphrase,
  };
  static SshCredentials fromJson(dynamic j) => j is Map
      ? SshCredentials(
          privateKey: j['privateKey'] as String? ?? '',
          password: j['password'] as String? ?? '',
          passphrase: j['passphrase'] as String? ?? '',
        )
      : const SshCredentials();
}

abstract class CredentialVault {
  Future<SshCredentials> read(String profileId);
  Future<void> write(String profileId, SshCredentials credentials);
  Future<void> delete(String profileId);
}

class SecureCredentialVault implements CredentialVault {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  @override
  Future<SshCredentials> read(String id) async {
    final raw = await _storage.read(key: 'agentspace.ssh.$id');
    return raw == null
        ? const SshCredentials()
        : SshCredentials.fromJson(jsonDecode(raw));
  }

  @override
  Future<void> write(String id, SshCredentials value) => _storage.write(
    key: 'agentspace.ssh.$id',
    value: jsonEncode(value.toJson()),
  );
  @override
  Future<void> delete(String id) => _storage.delete(key: 'agentspace.ssh.$id');
}

class MemoryCredentialVault implements CredentialVault {
  final _values = <String, SshCredentials>{};
  @override
  Future<SshCredentials> read(String id) async =>
      _values[id] ?? const SshCredentials();
  @override
  Future<void> write(String id, SshCredentials value) async {
    _values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    _values.remove(id);
  }
}

enum _SshTransport { discovery, input, streams, transfer }

class RemoteHerdrBackend
    with _ViewportSupport
    implements SessionBackend, TerminalInputBackend {
  RemoteHerdrBackend(this.profile, this.vault);
  final ConnectionProfile profile;
  final CredentialVault vault;
  // Discovery, input and streams have independent failure lifetimes. A timed-out
  // catalog must not cancel a key already in flight or tear down its live view.
  // Each transport uses the same pinned host identity and stored credentials.
  bool get ordinaryImageTransfers => _ordinarySsh;
  final _clients = <_SshTransport, SSHClient>{};
  final _connecting = <_SshTransport, Future<SSHClient>>{};
  bool _closed = false;
  bool _ordinarySsh = false;
  PersistentBridge? _bridge;
  SshBridgeFactory? _bridgeFactory;
  Future<void>? _negotiating;
  bool _negotiated = false;
  String? _firstLegacyCatalog;
  int _catalogEpoch = 0;
  @override
  String get sourceId => profile.id;
  Future<SSHClient> _connect(_SshTransport transport) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    final client = _clients[transport];
    if (client != null && !client.isClosed) return client;
    final connecting = _connecting[transport];
    if (connecting != null) return connecting;
    final future = _open(transport);
    _connecting[transport] = future;
    try {
      return await future;
    } finally {
      _connecting.remove(transport);
    }
  }

  Future<SSHClient> _open(_SshTransport transport) async {
    if (profile.host.trim().isEmpty ||
        profile.username.trim().isEmpty ||
        profile.port < 1 ||
        profile.port > 65535) {
      throw ConnectionFailure(
        'Enter the SSH host, port and username in Settings.',
        permanent: true,
      );
    }
    if (!profile.hostFingerprint.startsWith('SHA256:')) {
      throw ConnectionFailure(
        'Check and trust the Mac’s SSH identity in Settings first.',
        permanent: true,
      );
    }
    var credentials = await vault.read(profile.id);
    if (credentials.privateKey.isEmpty &&
        profile.privateKeyPath.isNotEmpty &&
        (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      credentials = SshCredentials(
        privateKey: await File(profile.privateKeyPath).readAsString(),
        password: credentials.password,
        passphrase: credentials.passphrase,
      );
    }
    List<SSHKeyPair> identities = [];
    try {
      if (credentials.privateKey.isNotEmpty) {
        identities = SSHKeyPair.fromPem(
          credentials.privateKey,
          credentials.passphrase.isEmpty ? null : credentials.passphrase,
        );
      }
    } catch (_) {
      throw ConnectionFailure(
        'The SSH private key could not be read. Check its format and passphrase.',
        permanent: true,
      );
    }
    var rejectedKey = false;
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(
        profile.host.trim(),
        profile.port,
        timeout: const Duration(seconds: 10),
      );
      if (_closed) {
        socket.close();
        throw ConnectionFailure('Connection closed.');
      }
      client = SSHClient(
        socket,
        username: profile.username.trim(),
        identities: identities,
        onPasswordRequest: credentials.password.isEmpty
            ? null
            : () => credentials.password,
        onVerifyHostKey: (_, fingerprint) {
          final valid = utf8.decode(fingerprint) == profile.hostFingerprint;
          rejectedKey = !valid;
          return valid;
        },
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      await client.authenticated;
      if (_closed) {
        client.close();
        throw ConnectionFailure('Connection closed.');
      }
      _clients[transport] = client;
      return client;
    } catch (error) {
      client?.close();
      if (rejectedKey || error is SSHHostkeyError) {
        throw ConnectionFailure(
          'The SSH host key changed. Verify the Mac identity in Settings; automatic retries are stopped.',
          permanent: true,
        );
      }
      if (error is SSHAuthError || error is SSHAuthAbortError) {
        throw ConnectionFailure(
          'SSH authentication failed. Check your dedicated key and pairing in Settings.',
          permanent: true,
        );
      }
      if (error is ConnectionFailure) rethrow;
      throw ConnectionFailure(
        'Could not reach ${profile.host}. Check the network and SSH Remote Login.',
      );
    }
  }

  Future<_Command> _command(
    String command, {
    bool input = false,
    bool viewport = false,
    bool stream = false,
    bool Function()? cancelled,
    void Function(void Function())? onStopReady,
  }) async {
    final transport = stream
        ? _SshTransport.streams
        : input
        ? _SshTransport.input
        : _SshTransport.discovery;
    final client = await _connect(transport);
    if (cancelled?.call() == true) {
      throw ConnectionFailure('Terminal viewport was cancelled.');
    }
    late SSHSession session;
    try {
      session = await client
          .execute(command)
          .timeout(
            const Duration(seconds: 6),
            onTimeout: () {
              client.close();
              if (identical(_clients[transport], client)) {
                _clients.remove(transport);
              }
              throw TimeoutException('SSH command acknowledgement timed out.');
            },
          );
    } catch (_) {
      if (input) throw DeliveryUncertain();
      rethrow;
    }
    onStopReady?.call(session.close);
    if (!viewport) unawaited(session.stdin.close());
    return _Command(
      session.stdout,
      session.stderr,
      session.done.then((_) => session.exitCode),
      session.close,
      resize: viewport
          ? (cols, rows) async {
              if (!validViewport(cols, rows)) {
                throw ArgumentError('Invalid terminal dimensions.');
              }
              session.stdin.add(
                utf8.encode(
                  '${jsonEncode({'type': 'terminal.resize', 'cols': cols, 'rows': rows})}\n',
                ),
              );
            }
          : null,
    );
  }

  Future<PersistentBridge?> persistentBridge() async {
    if (_negotiated) return _bridge;
    final pending = _negotiating ??= _negotiate();
    try {
      await pending;
    } finally {
      if (identical(_negotiating, pending)) _negotiating = null;
    }
    return _bridge;
  }

  Future<void> _negotiate() async {
    String? catalog;
    try {
      catalog = await _readCommand(await _command('agentspace-catalog-v1'));
    } on _CommandFailure catch (error) {
      if (!error.missingGate) rethrow;
      _ordinarySsh = true;
    }
    var restrictedV2 = false;
    if (catalog != null) {
      final row = jsonDecode(catalog);
      restrictedV2 = row is Map && row['bridgeProtocol'] == bridgeProtocol;
    }
    if (_ordinarySsh || restrictedV2) {
      _bridgeFactory = SshBridgeFactory(
        profile,
        restricted: restrictedV2,
        connect: (lane) => _connect(switch (lane) {
          BridgeLane.discovery => _SshTransport.discovery,
          BridgeLane.input => _SshTransport.input,
          BridgeLane.streams => _SshTransport.streams,
          BridgeLane.transfer => _SshTransport.transfer,
        }),
      );
      _bridge = PersistentBridge(_bridgeFactory!.open);
    } else {
      _firstLegacyCatalog = catalog;
    }
    _negotiated = true;
  }

  Map<String, dynamic> _bridgeRoute(SessionInfo session) {
    if (session.key.profile != profile.id ||
        session.key.backend != 'herdr' ||
        !session.available ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(session.key.server) ||
        !terminalIdPattern.hasMatch(session.key.terminal) ||
        !terminalIdPattern.hasMatch(session.paneId)) {
      throw SessionUnavailable();
    }
    return {
      'machine': 'gateway',
      'session': 'default',
      'targetHash': sha256.convert(utf8.encode('gateway')).toString(),
      'generation': session.key.server,
      'terminal': session.key.terminal,
      'pane': session.paneId,
    };
  }

  @override
  Future<List<SessionInfo>> listSessions() async {
    final bridge = await persistentBridge();
    if (bridge != null) {
      Map<String, dynamic>? root;
      await for (final event in bridge.discover(++_catalogEpoch, {})) {
        final value = event['value'];
        if (event['event'] == 'computer' &&
            value is Map &&
            value['machine'] == 'gateway') {
          root = Map<String, dynamic>.from(value);
        }
      }
      if (root?['catalog'] is! Map) {
        throw ConnectionFailure(
          'SSH connected, but no running Herdr server was found. Start Herdr on this computer.',
          permanent: true,
        );
      }
      return parseCatalog(jsonEncode(root!['catalog']), profile.id);
    }
    final initial = _firstLegacyCatalog;
    _firstLegacyCatalog = null;
    final response =
        initial ?? await _readCommand(await _command('agentspace-catalog-v1'));
    return parseCatalog(response, profile.id);
  }

  @override
  Stream<ObserveEvent> observeViewport(
    SessionInfo session,
    int cols,
    int rows,
  ) {
    if (_bridge != null) {
      if (!session.inputEnabled || !session.terminalViewportEnabled) {
        throw SessionUnavailable();
      }
      return _bridge!.observe(_bridgeRoute(session), cols: cols, rows: rows);
    }
    return viewportStream(session, cols, rows, (view) async {
      if (!session.inputEnabled ||
          !session.terminalViewportEnabled ||
          session.key.backend != 'herdr' ||
          session.key.profile != profile.id ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(session.key.server) ||
          !terminalIdPattern.hasMatch(session.key.terminal)) {
        throw SessionUnavailable();
      }
      view.ensureActive();
      return _command(
        'agentspace-control-v1 ${session.key.server} ${session.key.terminal} ${view.cols} ${view.rows}',
        viewport: true,
        stream: true,
        cancelled: () => view.cancelled,
        onStopReady: view.bindStop,
      );
    });
  }

  @override
  Future<void> resizeViewport(SessionInfo session, int cols, int rows) async {
    if (_bridge != null) {
      await _bridge!.resize(_bridgeRoute(session), cols, rows);
      return;
    }
    await super.resizeViewport(session, cols, rows);
  }

  @override
  Stream<ObserveEvent> observe(SessionInfo session) async* {
    if (_bridge != null) {
      yield* _bridge!.observe(_bridgeRoute(session));
      return;
    }
    yield* _observeCommand(() async {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(session.key.server) ||
          !terminalIdPattern.hasMatch(session.key.terminal) ||
          session.key.profile != profile.id) {
        throw SessionUnavailable();
      }
      return _command(
        'agentspace-observe-v1 ${session.key.server} ${session.key.terminal}',
        stream: true,
      );
    });
  }

  @override
  Future<void> sendText(SessionInfo session, String text) async {
    final invalid = validateInput(text);
    if (invalid != null) throw ArgumentError(invalid);
    if (!session.inputEnabled) {
      throw ConnectionFailure(
        'Input is disabled for this SSH key. Pair it with input enabled.',
        permanent: true,
      );
    }
    if (_bridge != null) {
      await _bridge!.request(
        BridgeLane.input,
        'send',
        {'text': text},
        route: _bridgeRoute(session),
        timeout: const Duration(seconds: 30),
      );
      return;
    }
    final current = (await listSessions())
        .where((s) => s.key == session.key)
        .firstOrNull;
    if (current == null) throw SessionUnavailable();
    if (!current.inputEnabled ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(session.key.server) ||
        !terminalIdPattern.hasMatch(session.key.terminal)) {
      throw SessionUnavailable();
    }
    final encoded = base64Encode(utf8.encode(text));
    final response = await _readCommand(
      await _command(
        'agentspace-send-v1 ${session.key.server} ${session.key.terminal} $encoded',
        input: true,
      ),
      input: true,
    );
    try {
      final j = jsonDecode(response);
      if (j is! Map || j['sent'] != true) throw const FormatException();
    } catch (_) {
      throw DeliveryUncertain();
    }
  }

  @override
  Future<void> sendTerminalInput(
    SessionInfo session,
    TerminalInput input,
  ) async {
    if (input.isPaste && _bridge == null) {
      throw SessionUnavailable('Terminal paste requires a persistent connection.');
    }
    if (input.clickCell != null) {
      throw SessionUnavailable(
        'Terminal clicks require an attached connection.',
      );
    }
    final invalid = input.validationError;
    if (invalid != null) throw ArgumentError(invalid);
    if (session.key.profile != profile.id ||
        !session.inputEnabled ||
        !session.terminalInputEnabled) {
      throw SessionUnavailable();
    }
    if (_bridge != null) {
      await _bridge!.request(
        BridgeLane.input,
        'input',
        input.toJson(),
        route: _bridgeRoute(session),
        timeout: const Duration(seconds: 30),
      );
      return;
    }
    // The restricted input gate revalidates permission, server generation and the
    // live terminal/pane before dispatch. Avoid a second catalog round trip here.
    if (session.key.backend != 'herdr' ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(session.key.server) ||
        !terminalIdPattern.hasMatch(session.key.terminal)) {
      throw SessionUnavailable();
    }
    final encoded = base64Encode(utf8.encode(jsonEncode(input.toJson())));
    final raw = await _readCommand(
      await _command(
        'agentspace-input-v1 ${session.key.server} ${session.key.terminal} $encoded',
        input: true,
      ),
      input: true,
    );
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['sent'] != true) throw const FormatException();
    } catch (_) {
      throw DeliveryUncertain();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _bridge?.close();
    await _bridgeFactory?.close();
    final clients = _clients.values.toList();
    _clients.clear();
    await Future.wait(clients.map((client) => client.close()));
  }
}

Future<String> probeHostFingerprint(ConnectionProfile profile) async {
  if (profile.host.trim().isEmpty || profile.port < 1 || profile.port > 65535) {
    throw ArgumentError('Enter a valid host and port.');
  }
  final result = Completer<String>();
  SSHClient? client;
  try {
    final socket = await SSHSocket.connect(
      profile.host.trim(),
      profile.port,
      timeout: const Duration(seconds: 10),
    );
    client = SSHClient(
      socket,
      username: profile.username.isEmpty ? 'agentspace' : profile.username,
      onVerifyHostKey: (_, fingerprint) {
        if (!result.isCompleted) result.complete(utf8.decode(fingerprint));
        return false; // discovery never authenticates or implicitly trusts a key
      },
    );
    unawaited(
      client.authenticated.catchError((Object error) {
        if (!result.isCompleted) {
          result.completeError(
            ConnectionFailure('Could not read the SSH host identity.'),
          );
        }
      }),
    );
    return await result.future.timeout(const Duration(seconds: 12));
  } finally {
    client?.close();
  }
}
