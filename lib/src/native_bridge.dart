import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'backend_errors.dart';
import 'bridge_protocol.dart';
import 'models.dart';
import 'persistent_bridge.dart';
import 'ssh_bridge.dart' show BridgeAssets;

class NativeBridgeFactory {
  NativeBridgeFactory(this.profile);
  final ConnectionProfile profile;
  static const channel = MethodChannel('agentspace/herdr');
  static int _next = 0;
  final _connections = <_NativeConnection>{};
  bool _closed = false;
  Future<BridgeConnection> open(BridgeLane lane) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    final assets = await BridgeAssets.load();
    final id = 'bridge-${DateTime.now().microsecondsSinceEpoch}-${_next++}';
    final connection = _NativeConnection(
      id,
      onClose: (c) => _connections.remove(c),
    );
    _connections.add(connection);
    try {
      if (_closed) throw ConnectionFailure('Connection closed.');
      await channel
          .invokeMethod<void>('startBridge', {
            'id': id,
            'lane': lane.name,
            'executable': profile.executable,
            'socketPath': profile.socketPath,
          })
          .timeout(const Duration(seconds: 6));
      if (_closed) throw ConnectionFailure('Connection closed.');
      final hello = await connection.readHello().timeout(
        const Duration(seconds: 6),
      );
      if (hello['type'] == 'setup_error') {
        throw ConnectionFailure(
          'Herdr was not found on this Mac. Check its paths in Settings.',
          permanent: true,
        );
      }
      validateBridgeHello(hello, lane, digest: assets.digest);
      connection.hello = Map.unmodifiable(hello);
      if (_closed) throw ConnectionFailure('Connection closed.');
      return connection;
    } catch (error) {
      await connection.close();
      if (error is PlatformException) {
        throw ConnectionFailure(
          error.message ?? 'The local Herdr helper disconnected.',
          permanent: true,
        );
      }
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait(_connections.toList().map((c) => c.close()));
    try {
      await channel
          .invokeMethod<void>('close')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Every owned job was also stopped separately. */
    }
  }
}

class _NativeConnection implements BridgeConnection {
  _NativeConnection(this.id, {required this.onClose}) {
    _output = StreamController<Uint8List>(
      onListen: () => unawaited(_pump()),
      onPause: () => _paused = true,
      onResume: () => _paused = false,
      onCancel: close,
    );
  }
  final String id;
  final void Function(_NativeConnection) onClose;
  late StreamController<Uint8List> _output;
  final _errors = StreamController<Uint8List>();
  Uint8List _remaining = Uint8List(0);
  int _errorLength = 0;
  bool _closed = false, _paused = false;
  @override
  late Map<String, dynamic> hello;
  @override
  Stream<Uint8List> get stdout => _output.stream;
  @override
  Stream<Uint8List> get stderr => _errors.stream;
  Future<Map<String, dynamic>> _read() async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    final row = await NativeBridgeFactory.channel
        .invokeMapMethod<String, dynamic>('read', {'id': id})
        .timeout(const Duration(seconds: 6));
    if (row == null || row['out'] is! Uint8List || row['err'] is! Uint8List) {
      throw const FormatException('Invalid local helper response.');
    }
    final errors = row['err'] as Uint8List;
    _errorLength += errors.length;
    if (_errorLength > 65536) {
      throw const FormatException(
        'Local helper error output exceeded its limit.',
      );
    }
    if (errors.isNotEmpty) _errors.add(errors);
    return row;
  }

  Future<Map<String, dynamic>> readHello() async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    while (!_closed) {
      final row = await _read();
      final chunk = row['out'] as Uint8List;
      final end = chunk.indexOf(10);
      final count = end < 0 ? chunk.length : end;
      length += count;
      if (length > maxBridgeRecordBytes) {
        throw const FormatException('Local helper record exceeds its limit.');
      }
      bytes.add(Uint8List.sublistView(chunk, 0, count));
      if (end >= 0) {
        _remaining = Uint8List.sublistView(chunk, end + 1);
        return decodeBridgeRecord(bytes.takeBytes());
      }
      if (row['exit'] != null) {
        throw ConnectionFailure(
          'The local Herdr worker ended before connecting.',
        );
      }
    }
    throw ConnectionFailure('Connection closed.');
  }

  Future<void> _pump() async {
    try {
      if (_remaining.isNotEmpty) {
        _output.add(_remaining);
        _remaining = Uint8List(0);
      }
      while (!_closed) {
        if (_paused) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }
        final row = await _read();
        if (_closed) break;
        final chunk = row['out'] as Uint8List;
        if (chunk.isNotEmpty) _output.add(chunk);
        if (row['exit'] != null) break;
      }
    } catch (error, stack) {
      if (!_closed) _output.addError(error, stack);
    } finally {
      await close();
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    if (bytes.isEmpty ||
        bytes.last != 10 ||
        bytes.length > maxBridgeRecordBytes) {
      throw const FormatException('Invalid local helper request.');
    }
    // Swift appends the single record delimiter after validating the object.
    await NativeBridgeFactory.channel
        .invokeMethod<void>('writeBridge', {
          'id': id,
          'record': Uint8List.sublistView(bytes, 0, bytes.length - 1),
        })
        .timeout(const Duration(seconds: 3));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose(this);
    try {
      await NativeBridgeFactory.channel
          .invokeMethod<void>('stop', {'id': id})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Global XPC invalidation also stops its owned jobs. */
    }
    unawaited(_output.close());
    unawaited(_errors.close());
  }
}
