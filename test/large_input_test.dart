import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/storage.dart';

import 'terminal_input_test.dart' show InputFixture, WidgetStore;

void main() {
  test(
    'messages and pastes accept 256 KiB UTF-8 and reject the first extra byte',
    () {
      final text = '🙂' * 65536;
      expect(utf8.encode(text).length, 262144);
      expect(validateInput(text), isNull);
      expect(TerminalInput.paste(text).validationError, isNull);
      expect(TerminalInput.text(text).validationError, isNull);
      for (final invalid in ['$text!', 'x' * 262145]) {
        expect(validateInput(invalid), isNotNull);
        expect(TerminalInput.paste(invalid).validationError, isNotNull);
      }
      expect(TerminalInput.paste('line\n\tline').validationError, isNull);
      expect(TerminalInput.paste('bad\u001b[2J').validationError, isNotNull);
    },
  );
  test(
    'a maximum paste remains one input and later keys stay ordered',
    () async {
      final backend = InputFixture()..hold = Completer<void>();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep draft');
        final text = '🙂' * 65536;
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.paste(text),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(backend.input, hasLength(1));
        app.sendTerminalInput(
          backend.session.key.id,
          TerminalInput.keys(['left']),
        );
        backend.hold!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(backend.input, hasLength(2));
        expect(backend.input.first.isPaste, isTrue);
        expect(backend.input.first.textValue, text);
        expect(backend.input.last.keyNames, ['left']);
        expect(backend.composedCalls, 0);
        expect(app.layout.drafts[backend.session.key.id], 'keep draft');
        expect(app.sendStates[backend.session.key.id]!.uncertain, isFalse);
      } finally {
        if (!backend.hold!.isCompleted) backend.hold!.complete();
        await app.shutdown();
      }
    },
  );
  test(
    'maximum-size reviewed message submits once and clears only its draft',
    () async {
      final backend = InputFixture()..allowComposed = true;
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'é' * 131072);
        expect(await app.sendDraft(backend.session.key.id), isTrue);
        expect(backend.composedCalls, 1);
        expect(backend.input, isEmpty);
        expect(app.layout.drafts[backend.session.key.id] ?? '', isEmpty);
      } finally {
        await app.shutdown();
      }
    },
  );
}
