import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/dictation.dart';
import 'package:agentspace/src/dictation_settings.dart';
import 'package:agentspace/src/dictation_dialog.dart';

import 'controller_test.dart' show FakeBackend, item;
import 'dictation_capture_test.dart' show FakeMic;

class MemoryKeys implements DictationKeys {
  final values = <DictationProvider, String>{};
  @override
  Future<String?> read(DictationProvider provider) async => values[provider];
  @override
  Future<void> write(DictationProvider provider, String key) async {
    values[provider] = key;
  }

  @override
  Future<void> delete(DictationProvider provider) async {
    values.remove(provider);
  }
}

class FakeCapture extends DictationCapture {
  FakeCapture() : super(DictationProvider.openai, microphone: FakeMic());
  int cancels = 0;
  @override
  Future<void> start(String key) async {
    phase = DictationPhase.recording;
    notifyListeners();
  }

  @override
  Future<void> finish() async {
    if (phase != DictationPhase.recording) return;
    protocol.receive({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'one',
      'transcript': 'Please review the changes.',
    });
    phase = DictationPhase.review;
    notifyListeners();
  }

  @override
  Future<void> cancel() async {
    cancels++;
    phase = DictationPhase.cancelled;
  }
}

class MemoryStore extends LayoutStore {
  MemoryStore() : super('unused');
  @override
  Future<void> save(AppSnapshot value) async {}
}

void main() {
  late AppController app;
  late FakeBackend backend;
  late MemoryKeys keys;
  setUp(() async {
    backend = FakeBackend('demo', [item('one'), item('two')]);
    app = AppController(
      snapshot: AppSnapshot(),
      store: MemoryStore(),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
    app.select(backend.sessions.first.key.id);
    keys = MemoryKeys();
  });

  testWidgets('keys are independent by provider and absent from snapshot', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DictationSettings(app: app, keys: keys),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('dictation-api-key'));
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, 'openai-test-secret');
    await tester.tap(find.text('Save API key'));
    await tester.pumpAndSettle();
    expect(keys.values[DictationProvider.openai], 'openai-test-secret');
    await tester.tap(find.byKey(const ValueKey('dictation-provider-openai')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ElevenLabs').last);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'eleven-test-secret');
    await tester.tap(find.text('Save API key'));
    await tester.pumpAndSettle();
    expect(keys.values.length, 2);
    expect(app.snapshot.toJson().toString(), isNot(contains('test-secret')));
    expect(app.snapshot.dictationProvider, 'elevenlabs');
    await tester.tap(find.text('Remove API key'));
    await tester.pumpAndSettle();
    expect(keys.values.keys, [DictationProvider.openai]);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  });

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1024, 768),
  ]) {
    testWidgets('dictation review fits $size and never sends automatically', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      keys.values[DictationProvider.openai] = 'test';
      final capture = FakeCapture();
      await tester.pumpWidget(
        MaterialApp(
          home: DictationDialog(
            app: app,
            session: backend.sessions.first,
            generation: app.dictationGeneration,
            capture: capture,
            keys: keys,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dictation-review')), findsOneWidget);
      expect(backend.sends, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    });
  }
  testWidgets('review corrections survive background and resume', (
    tester,
  ) async {
    keys.values[DictationProvider.openai] = 'test';
    final capture = FakeCapture();
    await tester.pumpWidget(
      MaterialApp(
        home: DictationDialog(
          app: app,
          session: backend.sessions.first,
          generation: app.dictationGeneration,
          capture: capture,
          keys: keys,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('dictation-review'));
    await tester.enterText(field, 'Corrected transcript');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Corrected transcript',
    );
    expect(capture.phase, DictationPhase.review);
    expect(capture.cancels, 0);
    expect(backend.sends, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  });
  testWidgets('Stop and Send finalizes once and preserves an existing draft', (
    tester,
  ) async {
    keys.values[DictationProvider.openai] = 'test';
    final capture = FakeCapture();
    final session = backend.sessions.first;
    app.updateDraft(session.key.id, 'Existing draft');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => DictationDialog(
                app: app,
                session: session,
                generation: app.dictationGeneration,
                capture: capture,
                keys: keys,
              ),
            ),
            child: const Text('Open dictation'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open dictation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop & Send'));
    await tester.pumpAndSettle();
    expect(backend.sends, 1);
    expect(find.byType(DictationDialog), findsNothing);
    expect(app.layout.drafts[session.key.id], 'Existing draft');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  });
  testWidgets('background stops recording without sending', (tester) async {
    keys.values[DictationProvider.openai] = 'test';
    final capture = FakeCapture();
    await tester.pumpWidget(
      MaterialApp(
        home: DictationDialog(
          app: app,
          session: backend.sessions.first,
          generation: app.dictationGeneration,
          capture: capture,
          keys: keys,
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(capture.cancels, greaterThan(0));
    expect(backend.sends, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Stop & Send'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  });
  testWidgets('changing session cancels recording and disables delivery', (
    tester,
  ) async {
    keys.values[DictationProvider.openai] = 'test';
    final capture = FakeCapture();
    await tester.pumpWidget(
      MaterialApp(
        home: DictationDialog(
          app: app,
          session: backend.sessions.first,
          generation: app.dictationGeneration,
          capture: capture,
          keys: keys,
        ),
      ),
    );
    await tester.pumpAndSettle();
    app.select(backend.sessions.last.key.id);
    await tester.pumpAndSettle();
    expect(capture.cancels, greaterThan(0));
    expect(backend.sends, 0);
    expect(find.text('Stop & Send'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  });
}
