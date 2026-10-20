import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/dictation.dart';

class FakeMic implements DictationMicrophone {
  final audio = StreamController<Uint8List>.broadcast();
  Completer<bool>? permission;
  bool allowed = true;
  int starts = 0, stops = 0;
  @override
  Future<bool> hasPermission() async =>
      permission == null ? allowed : permission!.future;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    await audio.close();
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 200 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(check(), isTrue);
}

void main() {
  for (final provider in DictationProvider.values) {
    test(
      '${provider.name} streams audio and waits for final transcript',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final mic = FakeMic();
        final messages = <Map<String, dynamic>>[];
        WebSocket? peer;
        final capture = DictationCapture(
          provider,
          microphone: mic,
          connect: (uri, headers) async {
            expect(uri.scheme, 'wss');
            expect(
              headers.values.single,
              provider == DictationProvider.openai
                  ? 'Bearer test-key'
                  : 'test-key',
            );
            return WebSocket.connect(
              'ws://127.0.0.1:${server.port}',
              headers: headers,
            );
          },
          timeout: const Duration(seconds: 2),
        );
        final serving = server.listen((request) async {
          peer = await WebSocketTransformer.upgrade(request);
          if (provider == DictationProvider.elevenlabs) {
            peer!.add(jsonEncode({'message_type': 'session_started'}));
          }
          peer!.listen((raw) {
            final message = jsonDecode(raw as String) as Map<String, dynamic>;
            messages.add(message);
            if (message['type'] == 'session.update') {
              peer!.add(jsonEncode({'type': 'session.updated'}));
            }
          });
        });
        await capture.start('test-key');
        expect(capture.phase, DictationPhase.recording);
        mic.audio.add(Uint8List(12000));
        await until(
          () => messages.any(
            (m) => m.containsKey('audio') || m.containsKey('audio_base_64'),
          ),
        );
        peer!.add(
          jsonEncode(
            provider == DictationProvider.openai
                ? {
                    'type': 'conversation.item.input_audio_transcription.delta',
                    'item_id': 'one',
                    'delta': 'hello',
                  }
                : {'message_type': 'partial_transcript', 'text': 'hello'},
          ),
        );
        await until(() => capture.text == 'hello');
        var done = false;
        final finishing = capture.finish().then((_) => done = true);
        await until(
          () => messages.any(
            (m) =>
                m['type'] == 'input_audio_buffer.commit' || m['commit'] == true,
          ),
        );
        expect(done, isFalse);
        expect(mic.stops, greaterThan(0));
        peer!.add(
          jsonEncode(
            provider == DictationProvider.openai
                ? {
                    'type':
                        'conversation.item.input_audio_transcription.completed',
                    'item_id': 'one',
                    'transcript': 'Hello world.',
                  }
                : {
                    'message_type': 'committed_transcript',
                    'text': 'Hello world.',
                  },
          ),
        );
        await finishing;
        expect(capture.phase, DictationPhase.review);
        expect(capture.text, 'Hello world.');
        expect(
          messages.where(
            (m) =>
                m['commit'] == true || m['type'] == 'input_audio_buffer.commit',
          ),
          hasLength(1),
        );
        await capture.close();
        await peer?.close();
        await serving.cancel();
        await server.close(force: true);
      },
    );
  }
  for (final ready in [false, true]) {
    test(
      ready
          ? 'missing final transcript fails without losing partial text'
          : 'missing provider acknowledgement never starts microphone',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final mic = FakeMic();
        WebSocket? peer;
        final serving = server.listen((request) async {
          peer = await WebSocketTransformer.upgrade(request);
          peer!.listen((raw) {
            final event = jsonDecode(raw as String);
            if (ready && event['type'] == 'session.update') {
              peer!.add(jsonEncode({'type': 'session.updated'}));
            }
            if (event['type'] == 'input_audio_buffer.append') {
              peer!.add(
                jsonEncode({
                  'type': 'conversation.item.input_audio_transcription.delta',
                  'item_id': 'one',
                  'delta': 'partial',
                }),
              );
            }
          });
        });
        final capture = DictationCapture(
          DictationProvider.openai,
          microphone: mic,
          timeout: const Duration(milliseconds: 150),
          connect: (_, _) => WebSocket.connect('ws://127.0.0.1:${server.port}'),
        );
        await capture.start('test-key');
        if (ready) {
          mic.audio.add(Uint8List(12000));
          await until(() => capture.text.isNotEmpty);
          await capture.finish();
          expect(capture.text, contains('partial'));
        } else {
          expect(mic.starts, 0);
        }
        expect(capture.phase, DictationPhase.failed);
        await capture.close();
        await peer?.close();
        await serving.cancel();
        await server.close(force: true);
      },
    );
  }
  test('cancel during permission never opens provider or microphone', () async {
    final mic = FakeMic()..permission = Completer<bool>();
    var connects = 0;
    final capture = DictationCapture(
      DictationProvider.openai,
      microphone: mic,
      connect: (_, _) async {
        connects++;
        throw StateError('Must not connect');
      },
    );
    final starting = capture.start('test-key');
    await capture.cancel();
    mic.permission!.complete(true);
    await starting;
    expect(connects, 0);
    expect(mic.starts, 0);
    expect(capture.phase, DictationPhase.cancelled);
    await capture.close();
  });
  test('permission denial does not connect', () async {
    final mic = FakeMic()..allowed = false;
    final capture = DictationCapture(
      DictationProvider.openai,
      microphone: mic,
      connect: (_, _) async => throw StateError('Must not connect'),
    );
    await capture.start('test-key');
    expect(capture.phase, DictationPhase.failed);
    expect(capture.error, contains('Microphone access'));
    await capture.close();
  });
  test('connection failure never includes the API key in errors', () async {
    final mic = FakeMic();
    final capture = DictationCapture(
      DictationProvider.openai,
      microphone: mic,
      connect: (_, _) async => throw StateError('sensitive-test-key'),
    );
    await capture.start('sensitive-test-key');
    expect(capture.phase, DictationPhase.failed);
    expect(capture.error, isNot(contains('sensitive-test-key')));
    await capture.close();
  });
}
