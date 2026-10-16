import 'dart:convert';
import 'dart:typed_data';

import 'backend_errors.dart';

const bridgeProtocol = 'agentspace-bridge-v2';
const maxBridgeRecordBytes = 2 * 1024 * 1024;

enum BridgeLane { discovery, input, streams, transfer }

class BridgeProtocol {
  BridgeProtocol(String protocol, this.nonce, this.lane) {
    if (protocol != bridgeProtocol ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce)) {
      throw const FormatException(
        'This computer returned an incompatible connection.',
      );
    }
  }
  final String nonce;
  final BridgeLane lane;
  void validate(Map<String, dynamic> row) {
    if (row['nonce'] != nonce ||
        row['lane'] != lane.name ||
        !const ['reply', 'event'].contains(row['type']) ||
        row['id'] is! String ||
        !RegExp(r'^[1-9][0-9]{0,15}$').hasMatch(row['id'] as String)) {
      throw const FormatException(
        'This computer returned an unexpected acknowledgement.',
      );
    }
  }
}

void validateBridgeHello(
  Map<String, dynamic> row,
  BridgeLane lane, {
  String? nonce,
  String? digest,
}) {
  if (row['type'] != 'hello' ||
      row['protocol'] != bridgeProtocol ||
      row['lane'] != lane.name ||
      row['nonce'] is! String ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(row['nonce'] as String) ||
      row['digest'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(row['digest'] as String) ||
      (nonce != null && row['nonce'] != nonce) ||
      (digest != null && row['digest'] != digest) ||
      (row['generation'] != null &&
          (row['generation'] is! String ||
              !RegExp(r'^[0-9a-f]{64}$')
                  .hasMatch(row['generation'] as String))) ||
      row['capabilities'] is! Map ||
      (row['capabilities'] as Map).values.any((v) => v is! bool)) {
    throw const FormatException(
      'This computer needs a compatible AgentSpace helper.',
    );
  }
}

class _JsonObject {
  _JsonObject(this.object);
  final bool object;
  final keys = <String>{};
  bool expectsKey = true;
}

// dart:convert otherwise silently accepts duplicate JSON fields. Check keys
// within each object before decoding, so two correlation IDs cannot collapse.
void _checkJsonKeys(String raw) {
  final stack = <_JsonObject>[];
  for (var i = 0; i < raw.length; i++) {
    final c = raw.codeUnitAt(i);
    if (c == 123 || c == 91) {
      stack.add(_JsonObject(c == 123));
      if (stack.length > 64) {
        throw const FormatException(
          'Connection record nesting exceeds its limit.',
        );
      }
    } else if (c == 125 || c == 93) {
      if (stack.isEmpty) {
        throw const FormatException('Invalid connection record.');
      }
      stack.removeLast();
    } else if (c == 44 && stack.isNotEmpty && stack.last.object) {
      stack.last.expectsKey = true;
    } else if (c == 34) {
      final start = i++;
      for (; i < raw.length; i++) {
        final next = raw.codeUnitAt(i);
        if (next == 92) {
          i++;
          continue;
        }
        if (next == 34) break;
      }
      if (i >= raw.length) {
        throw const FormatException('Invalid connection string.');
      }
      if (stack.isNotEmpty && stack.last.object && stack.last.expectsKey) {
        final key = jsonDecode(raw.substring(start, i + 1)) as String;
        if (!stack.last.keys.add(key)) {
          throw const FormatException('Duplicate connection field.');
        }
        stack.last.expectsKey = false;
      }
    }
  }
}

Map<String, dynamic> decodeBridgeRecord(List<int> bytes) {
  if (bytes.length > maxBridgeRecordBytes) {
    throw const FormatException('Connection record exceeds its limit.');
  }
  final raw = utf8.decode(bytes);
  _checkJsonKeys(raw);
  final row = jsonDecode(raw);
  if (row is! Map<String, dynamic>) {
    throw const FormatException('Invalid connection record.');
  }
  return row;
}

Stream<Map<String, dynamic>> decodeBridgeRecords(
  Stream<List<int>> source,
) async* {
  final pending = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in source) {
    var start = 0;
    while (start < chunk.length) {
      final end = chunk.indexOf(10, start);
      final stop = end < 0 ? chunk.length : end;
      length += stop - start;
      if (length > maxBridgeRecordBytes) {
        throw const FormatException('Connection record exceeds its limit.');
      }
      if (stop > start) pending.add(chunk.sublist(start, stop));
      if (end < 0) break;
      yield decodeBridgeRecord(pending.takeBytes());
      length = 0;
      start = end + 1;
    }
  }
  if (length != 0) {
    throw const FormatException('Connection ended with an incomplete record.');
  }
}

Uint8List encodeBridgeRecord(Map<String, dynamic> row) {
  final bytes = Uint8List.fromList(utf8.encode('${jsonEncode(row)}\n'));
  if (bytes.length > maxBridgeRecordBytes) {
    throw const FormatException('Connection record exceeds its limit.');
  }
  return bytes;
}

Object bridgeRejection(Map<String, dynamic> error, {required bool input}) {
  const codes = {
    'invalid_request',
    'unsupported',
    'setup_required',
    'auth_required',
    'host_key',
    'offline',
    'route_changed',
    'generation_changed',
    'terminal_missing',
    'workspace_missing',
    'busy',
    'timeout',
    'delivery_uncertain',
  };
  if (!codes.contains(error['code']) || error['dispatched'] is! bool) {
    return input
        ? DeliveryUncertain()
        : const FormatException('Invalid connection rejection.');
  }
  if (input && error['dispatched'] == true) return DeliveryUncertain();
  return switch (error['code']) {
    'route_changed' => SessionUnavailable(
      'This computer changed in Herdr. Refresh before typing again.',
    ),
    'generation_changed' ||
    'terminal_missing' ||
    'workspace_missing' => SessionUnavailable(),
    'auth_required' => ConnectionFailure(
      'This computer needs SSH access from the connected computer.',
      permanent: true,
    ),
    'host_key' => ConnectionFailure(
      'Verify this computer’s SSH identity on the connected computer.',
      permanent: true,
    ),
    'setup_required' => ConnectionFailure(
      'This computer needs Python 3 and a compatible running Herdr.',
      permanent: true,
    ),
    'unsupported' => ConnectionFailure(
      'This computer does not support this action.',
      permanent: true,
    ),
    'busy' => ConnectionFailure(
      'Other live sessions are using this connection. Try again.',
    ),
    'invalid_request' => ConnectionFailure(
      'This terminal action is not supported.',
      permanent: true,
    ),
    _ => ConnectionFailure(
      'This computer is unavailable. Reconnect to try again.',
    ),
  };
}
