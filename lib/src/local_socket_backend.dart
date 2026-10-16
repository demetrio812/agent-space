part of 'backend.dart';

/// Local transport runs in the app's sandbox, using the selected socket folder.
/// The CLI backend remains useful for restricted remote gates and integration.
class SocketHerdrBackend extends LocalHerdrBackend {
  @override
  bool get _supportsViewport => false;
  SocketHerdrBackend(super.profile);
  final _sockets = <Socket>{};

  Future<Socket> _connectSocket(String path) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    try {
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 6),
      );
      if (_closed) {
        socket.destroy();
        throw ConnectionFailure('Connection closed.');
      }
      _sockets.add(socket);
      return socket;
    } on SocketException catch (error) {
      final denied =
          error.osError?.errorCode == 1 || error.osError?.errorCode == 13;
      throw ConnectionFailure(
        denied
            ? 'Allow access to the Herdr socket folder in Settings, then reconnect.'
            : 'Herdr is offline. Start Herdr on this Mac, then reconnect.',
        permanent: denied,
      );
    }
  }

  void _release(Socket socket) {
    _sockets.remove(socket);
    socket.destroy();
  }

  @override
  Future<_Command> _spawn(
    List<String> arguments, {
    void Function(void Function())? onStopReady,
  }) async {
    if (arguments.length >= 4 &&
        arguments[0] == 'terminal' &&
        arguments[1] == 'session' &&
        arguments[2] == 'observe') {
      return _observeSocket(arguments);
    }
    final (method, params) = switch (arguments) {
      ['agent', 'list'] => ('agent.list', <String, dynamic>{}),
      ['workspace', 'list'] => ('workspace.list', <String, dynamic>{}),
      ['tab', 'list'] => ('tab.list', <String, dynamic>{}),
      ['pane', 'layout', '--pane', final pane] => (
        'pane.layout',
        <String, dynamic>{'pane_id': pane},
      ),
      ['pane', 'run', final pane, final text] => (
        'pane.send_input',
        <String, dynamic>{
          'pane_id': pane,
          'text': text,
          'keys': ['Enter'],
        },
      ),
      ['pane', 'send-text', final pane, final text] => (
        'pane.send_text',
        <String, dynamic>{'pane_id': pane, 'text': text},
      ),
      ['pane', 'send-keys', final pane, ...final keys] => (
        'pane.send_keys',
        <String, dynamic>{'pane_id': pane, 'keys': keys},
      ),
      _ => throw const FormatException('Unsupported local Herdr request.'),
    };
    final socket = await _connectSocket(profile.socketPath);
    final done = Completer<int?>();
    try {
      socket.write(
        '${jsonEncode({'id': 'agentspace', 'method': method, 'params': params})}\n',
      );
    } catch (_) {
      _release(socket);
      if (method.startsWith('pane.send_')) throw DeliveryUncertain();
      rethrow;
    }
    Stream<List<int>> response() async* {
      final pending = BytesBuilder(copy: false);
      var length = 0;
      try {
        await for (final chunk in socket) {
          final end = chunk.indexOf(10);
          final part = end < 0 ? chunk : chunk.sublist(0, end);
          length += part.length;
          if (length > maxCatalogBytes) {
            throw const FormatException('Herdr response exceeded 2 MiB.');
          }
          pending.add(part);
          if (end >= 0) {
            final bytes = pending.takeBytes();
            final envelope = jsonDecode(utf8.decode(bytes));
            if (envelope is! Map || envelope['id'] != 'agentspace') {
              throw const FormatException(
                'Herdr returned an unexpected response.',
              );
            }
            if (method.startsWith('pane.send_')) {
              final result = envelope['result'];
              if (failedResponse(envelope) ||
                  result is! Map ||
                  failedResponse(result) ||
                  result['type'] != 'ok') {
                throw DeliveryUncertain();
              }
            }
            yield bytes;
            return;
          }
        }
        throw ConnectionFailure(
          'Herdr disconnected before acknowledging the request.',
        );
      } finally {
        _release(socket);
        if (!done.isCompleted) done.complete(0);
      }
    }

    return _Command(
      response(),
      const Stream.empty(),
      done.future,
      () => _release(socket),
    );
  }

  Future<_Command> _observeSocket(List<String> arguments) async {
    var columns = 120, rows = 40;
    for (var i = 4; i + 1 < arguments.length; i += 2) {
      if (arguments[i] == '--cols') columns = int.parse(arguments[i + 1]);
      if (arguments[i] == '--rows') rows = int.parse(arguments[i + 1]);
    }
    if (columns < 1 ||
        columns > 512 ||
        rows < 1 ||
        rows > 256 ||
        columns * rows > 65536) {
      throw const FormatException('Invalid terminal dimensions.');
    }
    final separator = profile.socketPath.lastIndexOf('/');
    final name = profile.socketPath.substring(separator + 1);
    final extension = name.lastIndexOf('.');
    final stem = extension > 0 ? name.substring(0, extension) : name;
    final path =
        '${profile.socketPath.substring(0, separator + 1)}$stem-client.sock';
    final socket = await _connectSocket(path);
    final reader = _SocketWireReader(socket);
    final done = Completer<int?>();
    try {
      // Bincode standard enum/varints: TerminalHello, protocol 22, native size.
      socket.add(
        _wireFrame([0, 22, ..._wireInt(columns), ..._wireInt(rows), 0, 0, 0]),
      );
      final welcome = _BincodeReader(
        await reader.frame().timeout(const Duration(seconds: 6)),
      );
      if (welcome.integer() != 0 ||
          welcome.integer() != 22 ||
          welcome.integer() != 1) {
        throw const FormatException(
          'Unsupported Herdr observer protocol. This app supports protocol 22 with ANSI frames.',
        );
      }
      final error = welcome.optionalString();
      welcome.requireEnd();
      if (error != null) {
        throw ConnectionFailure(displayText(error), permanent: true);
      }
      final target = utf8.encode(arguments[3]);
      socket.add(_wireFrame([7, ..._wireInt(target.length), ...target]));
    } catch (_) {
      _release(socket);
      await reader.cancel();
      rethrow;
    }
    Stream<List<int>> frames() async* {
      try {
        while (true) {
          final message = _BincodeReader(await reader.frame());
          final tag = message.integer();
          if (tag == 1) {
            final sequence = message.integer(),
                width = message.integer(),
                height = message.integer();
            final full = message.boolean();
            final bytes = message.bytes(limit: 1024 * 1024);
            message.requireEnd();
            final event = TerminalFrame(width, height, sequence, full, bytes);
            // Reuse the public ANSI validator at the observation boundary.
            yield utf8.encode('${jsonEncode(event.toJson())}\n');
          } else if (tag == 3) {
            final reason = message.optionalString();
            message.requireEnd();
            yield utf8.encode(
              '${jsonEncode({'type': 'terminal.closed', 'reason': reason ?? 'Herdr observer closed.'})}\n',
            );
            return;
          }
          // Graphics, notifications and controls never become terminal input.
        }
      } finally {
        _release(socket);
        await reader.cancel();
        if (!done.isCompleted) done.complete(0);
      }
    }

    return _Command(
      frames(),
      const Stream.empty(),
      done.future,
      () => _release(socket),
    );
  }

  @override
  Future<void> close() async {
    await super.close();
    for (final socket in _sockets.toList()) {
      _release(socket);
    }
  }
}

List<int> _wireInt(int value) {
  if (value < 0 || value > 65535) {
    throw const FormatException('Invalid wire integer.');
  }
  return value < 251 ? [value] : [251, value & 255, (value >> 8) & 255];
}

Uint8List _wireFrame(List<int> payload) {
  final header = ByteData(4)..setUint32(0, payload.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
}

class _SocketWireReader {
  _SocketWireReader(Stream<List<int>> stream)
    : _iterator = StreamIterator(stream);
  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = const [];
  int _offset = 0;
  Future<Uint8List> _exact(int length) async {
    final result = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      if (_offset == _chunk.length) {
        if (!await _iterator.moveNext()) {
          throw ConnectionFailure('Herdr terminal stream disconnected.');
        }
        _chunk = _iterator.current;
        _offset = 0;
        if (_chunk.isEmpty) continue;
      }
      final count = (length - filled) < (_chunk.length - _offset)
          ? length - filled
          : _chunk.length - _offset;
      result.setRange(filled, filled + count, _chunk, _offset);
      filled += count;
      _offset += count;
    }
    return result;
  }

  Future<Uint8List> frame() async {
    final length = ByteData.sublistView(await _exact(4))
        .getUint32(0, Endian.little);
    if (length < 1 || length > 2 * 1024 * 1024) {
      throw const FormatException('Invalid or oversized Herdr wire frame.');
    }
    return _exact(length);
  }

  Future<void> cancel() => _iterator.cancel();
}

class _BincodeReader {
  _BincodeReader(this.data);
  final Uint8List data;
  int offset = 0;
  int _byte() {
    if (offset >= data.length) {
      throw const FormatException('Truncated Herdr wire message.');
    }
    return data[offset++];
  }

  int integer() {
    final tag = _byte();
    if (tag < 251) return tag;
    final size = switch (tag) {
      251 => 2,
      252 => 4,
      253 => 8,
      _ => throw const FormatException('Invalid Herdr wire integer.'),
    };
    var result = 0;
    for (var i = 0; i < size; i++) {
      final byte = _byte();
      if (size == 8 && i == 7 && byte >= 128) {
        throw const FormatException('Herdr wire integer exceeded limit.');
      }
      result |= byte << (8 * i);
    }
    return result;
  }

  bool boolean() {
    final value = _byte();
    if (value > 1) throw const FormatException('Invalid Herdr boolean.');
    return value == 1;
  }

  Uint8List bytes({required int limit}) {
    final length = integer();
    if (length > limit || length > data.length - offset) {
      throw const FormatException('Invalid Herdr wire byte length.');
    }
    final result = Uint8List.sublistView(data, offset, offset + length);
    offset += length;
    return result;
  }

  String? optionalString() {
    final present = _byte();
    if (present == 0) return null;
    if (present != 1) throw const FormatException('Invalid Herdr option.');
    return utf8.decode(bytes(limit: 4096));
  }

  void requireEnd() {
    if (offset != data.length) {
      throw const FormatException('Unexpected trailing Herdr wire data.');
    }
  }
}
