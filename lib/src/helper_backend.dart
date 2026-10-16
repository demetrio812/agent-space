part of 'backend.dart';

/// macOS app-private XPC bridge; the app itself keeps App Sandbox enabled.
class HelperHerdrBackend extends LocalHerdrBackend {
  HelperHerdrBackend(super.profile);
  static const _channel = MethodChannel('agentspace/herdr');
  static var _nextCommand = 0;
  final _stops = <String, void Function()>{};
  NativeBridgeFactory? _bridgeFactory;
  PersistentBridge? _bridge;
  PersistentBridge get persistentBridge => _bridge ??= PersistentBridge(
    (_bridgeFactory ??= NativeBridgeFactory(profile)).open,
  );

  @override
  Future<String> _identity() async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    try {
      final identity = await _channel
          .invokeMethod<String>('identity', {'socketPath': profile.socketPath})
          .timeout(const Duration(seconds: 6));
      if (identity == null || identity.isEmpty) throw const FormatException();
      return sha256.convert(utf8.encode(identity)).toString();
    } catch (_) {
      throw ConnectionFailure(
        'Local Herdr is unavailable. Check its paths in Settings, then reconnect.',
      );
    }
  }

  @override
  Future<_Command> _spawn(
    List<String> arguments, {
    void Function(void Function())? onStopReady,
  }) async {
    if (_closed) throw ConnectionFailure('Connection closed.');
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_nextCommand++}';
    var stopped = false, paused = false;
    final done = Completer<int?>();
    late StreamController<List<int>> output;
    final errors = StreamController<List<int>>();
    void stop() {
      if (stopped) return;
      stopped = true;
      _stops.remove(id);
      unawaited(
        _channel
            .invokeMethod<void>('stop', {'id': id})
            .catchError((Object _) {}),
      );
    }

    _stops[id] = stop;
    onStopReady?.call(stop);
    try {
      if (stopped) throw ConnectionFailure('Terminal viewport was cancelled.');
      await _channel
          .invokeMethod<void>('start', {
            'id': id,
            'executable': profile.executable,
            'socketPath': profile.socketPath,
            'arguments': arguments,
          })
          .timeout(const Duration(seconds: 6));
      if (_closed || stopped) throw ConnectionFailure('Connection closed.');
    } catch (_) {
      stop();
      if (arguments.firstOrNull == 'pane' &&
          const {
            'run',
            'send-text',
            'send-keys',
          }.contains(arguments.elementAtOrNull(1))) {
        throw DeliveryUncertain();
      }
      throw ConnectionFailure(
        'The local Herdr helper could not start. Check its paths, then reconnect.',
      );
    }
    Future<void> pump() async {
      try {
        while (!stopped) {
          if (paused) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }
          final row = await _channel
              .invokeMapMethod<String, dynamic>('read', {'id': id})
              .timeout(const Duration(seconds: 6));
          if (stopped) break;
          if (row == null ||
              row['out'] is! Uint8List ||
              row['err'] is! Uint8List) {
            throw const FormatException('Invalid helper response.');
          }
          if ((row['out'] as Uint8List).isNotEmpty) {
            output.add(row['out'] as Uint8List);
          }
          if ((row['err'] as Uint8List).isNotEmpty) {
            errors.add(row['err'] as Uint8List);
          }
          if (row['exit'] is int) {
            done.complete(row['exit'] as int);
            break;
          }
        }
      } catch (error, stack) {
        if (!stopped) output.addError(error, stack);
      } finally {
        stop();
        if (!done.isCompleted) done.complete(-1);
        unawaited(output.close());
        unawaited(errors.close());
      }
    }

    output = StreamController<List<int>>(
      onListen: () => unawaited(pump()),
      onCancel: stop,
      onPause: () => paused = true,
      onResume: () => paused = false,
    );
    final control = arguments.take(3).join(' ') == 'terminal session control';
    return _Command(
      output.stream,
      errors.stream,
      done.future,
      stop,
      resize: control
          ? (cols, rows) async {
              if (!validViewport(cols, rows) || stopped || _closed) {
                throw ConnectionFailure('Terminal resize is unavailable.');
              }
              await _channel
                  .invokeMethod<void>('resize', {
                    'id': id,
                    'cols': cols,
                    'rows': rows,
                  })
                  .timeout(const Duration(seconds: 6));
            }
          : null,
    );
  }

  @override
  Future<void> close() async {
    await _bridge?.close();
    await _bridgeFactory?.close();
    await super.close();
    for (final stop in _stops.values.toList()) {
      stop();
    }
    try {
      await _channel
          .invokeMethod<void>('close')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
