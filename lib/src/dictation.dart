import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:record/record.dart';

enum DictationProvider {
  openai('OpenAI'),
  elevenlabs('ElevenLabs');

  const DictationProvider(this.label);
  final String label;
  static DictationProvider parse(String value) =>
      values.where((p) => p.name == value).firstOrNull ?? openai;
  Uri get endpoint => this == openai
      ? Uri.parse('wss://api.openai.com/v1/realtime?intent=transcription')
      : Uri.https('api.elevenlabs.io', '/v1/speech-to-text/realtime', {
          'model_id': 'scribe_v2_realtime',
          'audio_format': 'pcm_24000',
          'commit_strategy': 'manual',
        }).replace(scheme: 'wss');
}

abstract class DictationKeys {
  Future<String?> read(DictationProvider provider);
  Future<void> write(DictationProvider provider, String key);
  Future<void> delete(DictationProvider provider);
}

class SecureDictationKeys implements DictationKeys {
  final _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  String _key(DictationProvider p) => 'agentspace.dictation.${p.name}';
  @override
  Future<String?> read(DictationProvider provider) =>
      _storage.read(key: _key(provider));
  @override
  Future<void> write(DictationProvider provider, String key) =>
      _storage.write(key: _key(provider), value: key);
  @override
  Future<void> delete(DictationProvider provider) =>
      _storage.delete(key: _key(provider));
}

/// Provider wire formats are separate from microphone and UI lifecycle.
class DictationProtocol {
  DictationProtocol(this.provider);
  final DictationProvider provider;
  final _items = <String, String>{};
  final _completed = <String>{};
  final _committedOrder = <String>[];
  String _partial = '';
  String? error;
  bool ready = false;
  int get completedCount => _completed.length;
  String get text {
    final order = [
      ..._committedOrder,
      ..._items.keys.where((id) => !_committedOrder.contains(id)),
    ];
    return [
      ...order.map((id) => _items[id] ?? ''),
      _partial,
    ].where((text) => text.isNotEmpty).join(' ').trim();
  }

  Map<String, dynamic>? get configuration =>
      provider == DictationProvider.openai
      ? {
          'type': 'session.update',
          'session': {
            'type': 'transcription',
            'audio': {
              'input': {
                'format': {'type': 'audio/pcm', 'rate': 24000},
                'transcription': {'model': 'gpt-live-transcribe'},
                'turn_detection': null,
              },
            },
          },
        }
      : null;
  Map<String, dynamic> audio(Uint8List bytes) =>
      provider == DictationProvider.openai
      ? {'type': 'input_audio_buffer.append', 'audio': base64Encode(bytes)}
      : {
          'message_type': 'input_audio_chunk',
          'audio_base_64': base64Encode(bytes),
          'sample_rate': 24000,
        };
  Map<String, dynamic> commit() => provider == DictationProvider.openai
      ? {'type': 'input_audio_buffer.commit'}
      : {
          'message_type': 'input_audio_chunk',
          'audio_base_64': '',
          'sample_rate': 24000,
          'commit': true,
        };

  void receive(Map<String, dynamic> event) {
    final type = event['type'] ?? event['message_type'];
    if (type == 'session.updated' ||
        type == 'transcription_session.updated' ||
        type == 'session_started') {
      ready = true;
    }
    if (type == 'input_audio_buffer.committed' && event['item_id'] is String) {
      final id = event['item_id'] as String;
      if (!_committedOrder.contains(id)) _committedOrder.add(id);
    }
    if (type == 'conversation.item.input_audio_transcription.delta') {
      final id = event['item_id'];
      if (id is String &&
          event['delta'] is String &&
          !_completed.contains(id)) {
        _items[id] = (_items[id] ?? '') + (event['delta'] as String);
      }
    }
    if (type == 'conversation.item.input_audio_transcription.completed') {
      final id = event['item_id'];
      if (id is String && event['transcript'] is String) {
        _items[id] = event['transcript'];
        _completed.add(id);
      }
    }
    if (type == 'partial_transcript' && event['text'] is String) {
      _partial = event['text'];
    }
    if (type == 'committed_transcript' && event['text'] is String) {
      final id = 'segment-${_items.length}';
      _items[id] = event['text'];
      _completed.add(id);
      _partial = '';
    }
    if (type == 'error' ||
        type == 'conversation.item.input_audio_transcription.failed' ||
        (event.containsKey('error') && type != 'warning')) {
      final details = event['error'];
      final code = (details is Map ? details['code'] : type)?.toString() ?? '';
      error = code.contains('auth') || code.contains('api_key')
          ? 'The provider rejected the API key. Check Dictation in Settings.'
          : code.contains('quota') ||
                code.contains('rate') ||
                code.contains('resource_exhausted')
          ? 'The provider quota or rate limit was reached. Check your API account.'
          : 'Transcription failed. Check your provider account and try again.';
    }
  }
}

abstract class DictationMicrophone {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

class DeviceDictationMicrophone implements DictationMicrophone {
  final _recorder = AudioRecorder();
  @override
  Future<bool> hasPermission() => _recorder.hasPermission();
  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 24000,
      numChannels: 1,
    ),
  );
  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

typedef DictationSocket = Future<WebSocket> Function(
  Uri uri,
  Map<String, String> headers,
);

enum DictationPhase {
  starting,
  recording,
  finalizing,
  review,
  failed,
  cancelled,
}

class DictationCapture extends ChangeNotifier {
  DictationCapture(
    this.provider, {
    DictationMicrophone? microphone,
    DictationSocket? connect,
    this.timeout = const Duration(seconds: 20),
    this.maxDuration = const Duration(minutes: 5),
  }) : microphone = microphone ?? DeviceDictationMicrophone(),
       connect =
           connect ??
           ((uri, headers) =>
               WebSocket.connect(uri.toString(), headers: headers)),
       protocol = DictationProtocol(provider);
  final DictationProvider provider;
  final DictationMicrophone microphone;
  final DictationSocket connect;
  final Duration timeout, maxDuration;
  final DictationProtocol protocol;
  DictationPhase phase = DictationPhase.starting;
  String? error;
  String get text => protocol.text;
  bool _cancelled = false, _disposed = false;
  bool _stoppingAudio = false;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _wire;
  StreamSubscription<Uint8List>? _audio;
  Timer? _limit;
  int _segmentBytes = 0, _commits = 0;
  final _ready = Completer<void>();
  Completer<void>? _finished;
  Future<void>? _startFuture, _finishFuture;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get _ended => _cancelled || phase == DictationPhase.failed;

  Future<void> start(String key) => _startFuture ??= _start(key);
  Future<void> _start(String key) async {
    try {
      if (key.trim().isEmpty ||
          key.length > 4096 ||
          key.contains(RegExp(r'[\r\n]'))) {
        throw const FormatException(
          'Add an API key in Settings → Dictation first.',
        );
      }
      if (!await microphone.hasPermission()) {
        throw const FormatException(
          'Microphone access is disabled. Allow it in system settings to dictate.',
        );
      }
      if (_ended) return;
      final headers = provider == DictationProvider.openai
          ? {'Authorization': 'Bearer ${key.trim()}'}
          : {'xi-api-key': key.trim()};
      final opening = connect(provider.endpoint, headers);
      // A timed-out handshake may still complete later; never leave that socket open.
      unawaited(
        opening.then((socket) {
          if (_ended) unawaited(socket.close());
        }, onError: (_) {}),
      );
      final socket = await opening.timeout(timeout);
      if (_ended) {
        await socket.close();
        return;
      }
      _socket = socket;
      _wire = socket.listen(
        _receive,
        onError: (_) => _fail(
          'The transcription connection was interrupted. Nothing was sent.',
        ),
        onDone: () {
          if (!_ended && phase != DictationPhase.review) {
            _fail('The transcription connection closed. Nothing was sent.');
          }
        },
      );
      if (protocol.configuration != null) _send(protocol.configuration!);
      await _ready.future.timeout(timeout);
      if (_ended) return;
      final stream = await microphone.start();
      if (_ended) {
        await microphone.stop();
        return;
      }
      phase = DictationPhase.recording;
      _audio = stream.listen(
        (bytes) {
          if (_ended || bytes.isEmpty) return;
          _send(protocol.audio(bytes));
          _segmentBytes += bytes.length;
          // Periodic manual commits bound provider turn sizes during long dictation.
          if (_segmentBytes >= 24000 * 2 * 15) _commit();
        },
        onError: (_) =>
            _fail('Microphone recording was interrupted. Nothing was sent.'),
        onDone: () {
          if (!_stoppingAudio && phase == DictationPhase.recording) {
            _fail(
              'Microphone recording stopped. Review the text before sending.',
            );
          }
        },
      );
      _limit = Timer(maxDuration, () => unawaited(finish()));
      _notify();
    } catch (e) {
      _fail(
        e is FormatException
            ? e.message
            : e is TimeoutException
            ? 'The transcription provider did not respond. Check your connection and API key.'
            : 'Could not start dictation. Check microphone access, your connection and API key.',
      );
    }
  }

  void _send(Map<String, dynamic> value) {
    if (_ended) return;
    try {
      _socket?.add(jsonEncode(value));
    } catch (_) {
      _fail('The transcription connection was interrupted. Nothing was sent.');
    }
  }

  void _commit() {
    if (_segmentBytes == 0 || _ended) return;
    // Both APIs require a minimum audio duration, including after a periodic commit.
    if (_segmentBytes < 24000 / 5 * 2) {
      _send(protocol.audio(Uint8List((24000 / 5 * 2).toInt() - _segmentBytes)));
    }
    _commits++;
    _segmentBytes = 0;
    _send(protocol.commit());
  }

  void _receive(dynamic raw) {
    if (_ended) return;
    try {
      if (raw is! String || raw.length > 1024 * 1024) {
        throw const FormatException();
      }
      final event = jsonDecode(raw);
      if (event is! Map<String, dynamic>) throw const FormatException();
      protocol.receive(event);
      if (protocol.error != null) {
        _fail(protocol.error!);
        return;
      }
      if (protocol.ready && !_ready.isCompleted) _ready.complete();
      if (text.length > 64000) {
        _fail(
          'The transcript is too long. Review this recording and start a shorter one.',
        );
        return;
      }
      if (_finished != null &&
          !_finished!.isCompleted &&
          protocol.completedCount >= _commits) {
        _finished!.complete();
      }
      _notify();
    } catch (_) {
      _fail(
        'The provider returned an invalid transcription response. Nothing was sent.',
      );
    }
  }

  Future<void> finish() => _finishFuture ??= _finish();
  Future<void> _finish() async {
    if (phase != DictationPhase.recording) return;
    phase = DictationPhase.finalizing;
    _limit?.cancel();
    _notify();
    try {
      _stoppingAudio = true;
      await microphone.stop();
      await _audio?.cancel();
      if (_ended) return;
      _commit();
      if (_commits > protocol.completedCount) {
        _finished = Completer<void>();
        await _finished!.future.timeout(timeout);
      }
      if (_ended) return;
      phase = DictationPhase.review;
      await _closeWire();
      _notify();
    } catch (_) {
      _fail(
        'The final transcript could not be confirmed. Review the captured text; nothing was sent.',
      );
    }
  }

  void _fail(String message) {
    if (_ended) return;
    error = message;
    phase = DictationPhase.failed;
    _limit?.cancel();
    if (!_ready.isCompleted) _ready.complete();
    if (_finished != null && !_finished!.isCompleted) _finished!.complete();
    unawaited(_stop());
    _notify();
  }

  Future<void> _closeWire() async {
    await _wire?.cancel();
    _wire = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close());
  }

  Future<void> _stop() async {
    _stoppingAudio = true;
    try {
      await microphone.stop();
    } catch (_) {}
    await _audio?.cancel();
    await _closeWire();
  }

  Future<void> cancel() async {
    _cancelled = true;
    phase = DictationPhase.cancelled;
    _limit?.cancel();
    if (!_ready.isCompleted) _ready.complete();
    if (_finished != null && !_finished!.isCompleted) _finished!.complete();
    await _stop();
  }

  Future<void> close() async {
    await cancel();
    await _startFuture;
    await microphone.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
