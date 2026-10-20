import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/dictation.dart';

void main() {
  test('OpenAI replaces deltas with finals and preserves commit order', () {
    final p = DictationProtocol(DictationProvider.openai);
    p.receive({'type': 'input_audio_buffer.committed', 'item_id': 'a'});
    p.receive({'type': 'input_audio_buffer.committed', 'item_id': 'b'});
    p.receive({
      'type': 'conversation.item.input_audio_transcription.delta',
      'item_id': 'a',
      'delta': 'first par',
    });
    expect(p.text, 'first par');
    p.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'b',
      'transcript': 'second',
    });
    p.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'a',
      'transcript': 'first corrected',
    });
    expect(p.text, 'first corrected second');
    expect(p.completedCount, 2);
    p.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'a',
      'transcript': 'first corrected',
    });
    expect(p.completedCount, 2);
  });
  test('ElevenLabs partials replace each other and committed segments do not repeat', () {
    final p = DictationProtocol(DictationProvider.elevenlabs);
    p.receive({'message_type': 'partial_transcript', 'text': 'hel'});
    p.receive({'message_type': 'partial_transcript', 'text': 'hello'});
    expect(p.text, 'hello');
    p.receive({'message_type': 'committed_transcript', 'text': 'Hello.'});
    p.receive({'message_type': 'partial_transcript', 'text': 'Again'});
    expect(p.text, 'Hello. Again');
    p.receive({'message_type': 'committed_transcript', 'text': 'Again.'});
    expect(p.text, 'Hello. Again.');
    expect(p.completedCount, 2);
  });
  test(
    'provider audio and commit messages use PCM and explicit finalization',
    () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final openai = DictationProtocol(DictationProvider.openai);
      expect(openai.audio(bytes), {
        'type': 'input_audio_buffer.append',
        'audio': base64Encode(bytes),
      });
      expect(openai.commit(), {'type': 'input_audio_buffer.commit'});
      final eleven = DictationProtocol(DictationProvider.elevenlabs);
      expect(eleven.audio(bytes), {
        'message_type': 'input_audio_chunk',
        'audio_base_64': base64Encode(bytes),
        'sample_rate': 24000,
      });
      expect(eleven.commit(), {
        'message_type': 'input_audio_chunk',
        'audio_base_64': '',
        'sample_rate': 24000,
        'commit': true,
      });
    },
  );
  test('configuration chooses transcription only and manual commit', () {
    final p = DictationProtocol(DictationProvider.openai);
    expect(p.configuration!['session'], {
      'type': 'transcription',
      'audio': {
        'input': {
          'format': {'type': 'audio/pcm', 'rate': 24000},
          'transcription': {'model': 'gpt-live-transcribe'},
          'turn_detection': null,
        },
      },
    });
    expect(
      DictationProvider.elevenlabs.endpoint.queryParameters['commit_strategy'],
      'manual',
    );
    expect(
      DictationProvider.openai.endpoint.queryParameters['intent'],
      'transcription',
    );
  });
  test('raw provider errors never expose keys or audio', () {
    final p = DictationProtocol(DictationProvider.openai);
    p.receive({
      'type': 'error',
      'error': {'code': 'invalid_api_key', 'message': 'secret audio api-key'},
    });
    expect(p.error, contains('API key'));
    expect(p.error, isNot(contains('secret')));
    final eleven = DictationProtocol(DictationProvider.elevenlabs);
    eleven.receive({'message_type': 'quota_exceeded', 'error': 'secret'});
    expect(eleven.error, contains('quota'));
    expect(eleven.error, isNot(contains('secret')));
  });
}
