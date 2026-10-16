import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';

import 'backend_errors.dart';
import 'bridge_protocol.dart';
import 'models.dart';
import 'persistent_bridge.dart';

class BridgeAssets {
  BridgeAssets(this.package, this.bootstrap, this.launcher)
    : digest = sha256.convert(package).toString();
  final Uint8List package;
  final String bootstrap, launcher, digest;
  static Future<BridgeAssets> load() async {
    final data = await rootBundle.load('assets/bridge.pyz');
    return BridgeAssets(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      await rootBundle.loadString('assets/bridge-bootstrap.py'),
      await rootBundle.loadString('assets/bridge-launcher.sh'),
    );
  }
}

String shellQuoteBridge(String source) =>
    "'${source.replaceAll("'", "'\\''")}'";
String bridgeNonce() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class SshBridgeFactory {
  SshBridgeFactory(
    this.profile, {
    required this.connect,
    this.restricted = false,
  });
  final ConnectionProfile profile;
  final Future<SSHClient> Function(BridgeLane lane) connect;
  final bool restricted;
  Future<BridgeAssets>? _assets;
  final _connections = <_SshConnection>{};
  bool _closed = false;
  Future<BridgeConnection> open(BridgeLane lane) async {
    final assets = await (_assets ??= BridgeAssets.load());
    final client = await connect(lane);
    if (_closed) throw ConnectionFailure('Connection closed.');
    final command = restricted
        ? '$bridgeProtocol ${lane.name}'
        : '/bin/sh -c ${shellQuoteBridge(assets.launcher)} agentspace-bootstrap ${shellQuoteBridge(assets.bootstrap)}';
    var abandoned = false;
    final starting = client.execute(command);
    late SSHSession session;
    try {
      session = await starting.timeout(const Duration(seconds: 6));
    } catch (_) {
      abandoned = true;
      unawaited(
        starting
            .then((lateSession) {
              if (abandoned) lateSession.close();
            })
            .catchError((Object _) {}),
      );
      throw ConnectionFailure(
        'This computer did not start its AgentSpace helper.',
      );
    }
    final connection = _SshConnection(
      session,
      onClose: (connection) => _connections.remove(connection),
    );
    _connections.add(connection);
    try {
      if (_closed) throw ConnectionFailure('Connection closed.');
      final nonce = bridgeNonce();
      if (!restricted) {
        await connection.write(
          encodeBridgeRecord({
            'type': 'bootstrap',
            'protocol': bridgeProtocol,
            'digest': assets.digest,
            'nonce': nonce,
            'config': {
              'role': 'gateway',
              'lane': lane.name,
              'herdr': profile.executable,
              'socket': profile.socketPath,
              'generationStyle': 'ssh',
              'allowInput': true,
              'allowManagement': true,
              'allowImages': true,
            },
          }),
        );
        final cache = await connection.nextRecord().timeout(
          const Duration(seconds: 12),
        );
        if (cache['type'] != 'cache' ||
            cache['digest'] != assets.digest ||
            cache['needed'] is! bool) {
          throw ConnectionFailure(
            'The helper cache could not be verified.',
            permanent: true,
          );
        }
        if (cache['needed'] == true) {
          await connection.write(
            encodeBridgeRecord({
              'type': 'package',
              'digest': assets.digest,
              'bytes': base64Encode(assets.package),
            }),
          );
        }
      }
      final hello = await connection.nextRecord().timeout(
        const Duration(seconds: 12),
      );
      if (hello['type'] == 'setup_error') {
        throw ConnectionFailure(
          'SSH connected, but Herdr was not found on this computer. Check its Herdr installation.',
          permanent: true,
        );
      }
      validateBridgeHello(
        hello,
        lane,
        nonce: restricted ? null : nonce,
        digest: assets.digest,
      );
      connection.hello = Map.unmodifiable(hello);
      if (_closed) throw ConnectionFailure('Connection closed.');
      return connection;
    } catch (_) {
      await connection.close();
      _connections.remove(connection);
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    final connections = _connections.toList();
    _connections.clear();
    await Future.wait(connections.map((c) => c.close()));
  }
}

class _SshConnection implements BridgeConnection {
  _SshConnection(this.session, {required this.onClose})
    : _source = StreamIterator(session.stdout) {
    _errorSubscription = session.stderr.listen(
      (chunk) {
        _errorLength += chunk.length;
        if (_errorLength > 65536) {
          unawaited(close());
          return;
        }
        _errors.add(chunk);
        _stderr.add(chunk);
      },
      onError: _stderr.addError,
      onDone: () => unawaited(_stderr.close()),
    );
  }
  final SSHSession session;
  final void Function(_SshConnection connection) onClose;
  final StreamIterator<Uint8List> _source;
  final _stderr = StreamController<Uint8List>();
  final _errors = BytesBuilder(copy: false);
  int _errorLength = 0;
  Uint8List _buffer = Uint8List(0);
  late StreamSubscription<Uint8List> _errorSubscription;
  bool _closed = false;
  @override
  late Map<String, dynamic> hello;
  @override
  Stream<Uint8List> get stderr => _stderr.stream;
  @override
  Stream<Uint8List> get stdout async* {
    if (_buffer.isNotEmpty) {
      yield _buffer;
      _buffer = Uint8List(0);
    }
    while (!_closed && await _source.moveNext()) {
      yield _source.current;
    }
  }

  ConnectionFailure failure() {
    final error = utf8.decode(_errors.toBytes(), allowMalformed: true);
    if (error.contains('python3') && error.contains('not found')) {
      return ConnectionFailure(
        'SSH connected, but this computer needs Python 3 to run the Herdr bridge.',
        permanent: true,
      );
    }
    return ConnectionFailure(
      'This computer could not start its AgentSpace helper.',
      permanent: true,
    );
  }

  Future<Map<String, dynamic>> nextRecord() async {
    final pending = BytesBuilder(copy: false);
    var length = 0;
    while (!_closed) {
      final end = _buffer.indexOf(10);
      if (end >= 0) {
        length += end;
        if (length > maxBridgeRecordBytes) {
          throw const FormatException('Connection record exceeds its limit.');
        }
        pending.add(_buffer.sublist(0, end));
        _buffer = Uint8List.sublistView(_buffer, end + 1);
        return decodeBridgeRecord(pending.takeBytes());
      }
      pending.add(_buffer);
      length += _buffer.length;
      _buffer = Uint8List(0);
      if (length > maxBridgeRecordBytes) {
        throw const FormatException('Connection record exceeds its limit.');
      }
      if (!await _source.moveNext()) throw failure();
      _buffer = _source.current;
    }
    throw ConnectionFailure('Connection closed.');
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    // dartssh2 pumps stdin itself. Its explicit Socket.flush can bind the
    // underlying sink while a large upload still emits SSH packets.
    session.stdin.add(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose(this);
    unawaited(session.stdin.close());
    session.close();
    await _source.cancel();
    await _errorSubscription.cancel();
    unawaited(_stderr.close());
  }
}
