import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/conversation.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/models.dart';

import 'terminal_input_test.dart' show InputFixture, WidgetStore;

const chatSid = '11111111-1111-4111-8111-111111111111';
const firstMessage = '22222222-2222-4222-8222-222222222222';
Map<String, dynamic> chatPage({
  String text = 'Full answer',
  bool canSend = true,
}) => {
  'session': chatSid,
  'status': 'available',
  'messages': [
    {
      'id': firstMessage,
      'role': 'assistant',
      'text': text,
      'tools': <String>[],
      'truncated': false,
    },
  ],
  'before': firstMessage,
  'hasEarlier': false,
  'canSend': canSend,
};

class ChatFixture extends InputFixture implements ConversationBackend {
  Completer<ConversationPage>? readHold;
  int reads = 0;
  final expectedSessions = <String>[];
  Map<String, dynamic>? earlierPage;
  bool failSend = false;
  int chatSends = 0;
  String? receivedSession, receivedText;
  Map<String, dynamic> page = chatPage();
  @override
  Future<ConversationPage> readConversation(
    SessionInfo session, {
    String conversationSession = '',
    String before = '',
  }) async {
    reads++;
    expectedSessions.add(conversationSession);
    if (readHold != null) return await readHold!.future;
    return ConversationPage.fromJson(
      before.isNotEmpty && earlierPage != null ? earlierPage! : page,
    );
  }

  @override
  Future<void> sendConversation(
    SessionInfo session,
    String conversationSession,
    String text,
  ) async {
    chatSends++;
    receivedSession = conversationSession;
    receivedText = text;
    if (failSend) throw DeliveryUncertain();
  }
}

void main() {
  test('conversation pages validate identity, bounds and supported status', () {
    final page = ConversationPage.fromJson(chatPage());
    expect(page.messages.single.text, 'Full answer');
    expect(page.session, chatSid);
    for (final bad in [
      {...chatPage(), 'session': '../../private'},
      {
        ...chatPage(),
        'messages': [
          {
            'id': firstMessage,
            'role': 'tool',
            'text': 'hidden',
            'tools': [],
            'truncated': false,
          },
        ],
      },
      {...chatPage(), 'messages': List.filled(61, chatPage()['messages'][0])},
      {...chatPage(), 'hasEarlier': true, 'before': ''},
      {...chatPage(), 'status': 'unknown'},
    ]) {
      expect(() => ConversationPage.fromJson(bad), throwsFormatException);
    }
  });
  test(
    'native composer uses exact session binding and existing uncertainty guard',
    () async {
      final backend = ChatFixture()..failSend = true;
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      addTearDown(app.shutdown);
      await app.start(polling: false);
      final id = backend.session.key.id;
      app.select(id);
      app.updateDraft(id, 'keep this');
      expect(await app.sendDraft(id, conversationSession: chatSid), isFalse);
      expect(backend.chatSends, 1);
      expect(backend.receivedSession, chatSid);
      expect(backend.receivedText, 'keep this');
      expect(backend.composedCalls, 0);
      expect(app.layout.drafts[id], 'keep this');
      expect(app.sendStates[id]!.uncertain, isTrue);
      expect(await app.sendDraft(id, conversationSession: chatSid), isFalse);
      expect(backend.chatSends, 1);
    },
  );
  test('chat read rejects a response after connection replacement', () async {
    final backend = ChatFixture()..readHold = Completer<ConversationPage>();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    addTearDown(app.shutdown);
    await app.start(polling: false);
    app.select(backend.session.key.id);
    final pending = expectLater(
      app.readConversation(backend.session),
      throwsA(isA<SessionUnavailable>()),
    );
    await app.reconnect();
    backend.readHold!.complete(ConversationPage.fromJson(chatPage()));
    await pending;
  });
}
