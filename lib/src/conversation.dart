import 'dart:convert';

import 'models.dart';

final conversationIdPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

abstract interface class ConversationBackend {
  Future<ConversationPage> readConversation(
    SessionInfo session, {
    String conversationSession = '',
    String before = '',
  });
  Future<void> sendConversation(
    SessionInfo session,
    String conversationSession,
    String text,
  );
}

void validateConversationPayload(String op, Map<String, dynamic> payload) {
  final fields = op == 'chat.read'
      ? {'session', 'before'}
      : {'session', 'text'};
  if (payload.length != 2 || !fields.containsAll(payload.keys)) {
    throw ArgumentError('Invalid conversation action.');
  }
  if (op == 'chat.read') {
    for (final key in fields) {
      final value = payload[key];
      if (value is! String ||
          value.isNotEmpty && !conversationIdPattern.hasMatch(value)) {
        throw ArgumentError('Invalid conversation reference.');
      }
    }
  } else {
    if (payload['session'] is! String ||
        !conversationIdPattern.hasMatch(payload['session'] as String) ||
        payload['text'] is! String ||
        validateInput(payload['text'] as String) != null ||
        RegExp(r'^\s*[/!]').hasMatch(payload['text'] as String)) {
      throw ArgumentError(
        'Use Terminal for slash commands and shell commands.',
      );
    }
  }
}

class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.role,
    required this.text,
    this.tools = const [],
    this.truncated = false,
  });
  final String id, role, text;
  final List<String> tools;
  final bool truncated;
  static ConversationMessage fromJson(dynamic value) {
    if (value is! Map ||
        value['id'] is! String ||
        !conversationIdPattern.hasMatch(value['id']) ||
        !const {'user', 'assistant', 'system'}.contains(value['role']) ||
        value['text'] is! String ||
        value['truncated'] is! bool ||
        value['tools'] is! List ||
        (value['tools'] as List).length > 32 ||
        (value['tools'] as List).any((e) => e is! String || e.length > 64)) {
      throw const FormatException('Invalid conversation message.');
    }
    return ConversationMessage(
      id: value['id'],
      role: value['role'],
      text: value['text'],
      tools: List<String>.unmodifiable(value['tools']),
      truncated: value['truncated'],
    );
  }
}

class ConversationPage {
  const ConversationPage({
    required this.session,
    required this.status,
    required this.messages,
    this.before = '',
    this.hasEarlier = false,
    this.canSend = false,
  });
  final String session, status, before;
  final List<ConversationMessage> messages;
  final bool hasEarlier, canSend;
  bool get available => status == 'available';
  String get explanation => switch (status) {
    'unbound' => 'Herdr has not linked this pane to a Claude conversation. Open Terminal to continue.',
    'session_changed' => 'The Claude conversation changed. Reload Chat to read the current session.',
    'missing_transcript' => 'The Claude transcript is not available on this computer. Open Terminal to continue.',
    'ambiguous_transcript' => 'More than one transcript matches this session. Chat will not guess which one to use.',
    'transcript_limit' => 'This transcript exceeds the experimental reader’s size or time limit. Open Terminal to continue.',
    'unsupported_transcript' => 'This Claude transcript format is not supported yet. Open Terminal to continue.',
    _ => '',
  };
  static ConversationPage fromJson(Map<String, dynamic> value) {
    const statuses = {
      'available',
      'unbound',
      'session_changed',
      'missing_transcript',
      'ambiguous_transcript',
      'transcript_limit',
      'unsupported_transcript',
    };
    if (utf8.encode(jsonEncode(value)).length > 1024 * 1024 ||
        !statuses.contains(value['status']) ||
        value['session'] is! String ||
        (value['session'] != '' &&
            !conversationIdPattern.hasMatch(value['session'])) ||
        value['messages'] is! List ||
        (value['messages'] as List).length > 60 ||
        value['before'] is! String ||
        (value['before'] != '' &&
            !conversationIdPattern.hasMatch(value['before'])) ||
        value['hasEarlier'] is! bool ||
        value['canSend'] is! bool) {
      throw const FormatException('Invalid conversation page.');
    }
    final messages = (value['messages'] as List)
        .map(ConversationMessage.fromJson)
        .toList();
    if (messages.map((m) => m.id).toSet().length != messages.length ||
        (value['status'] != 'available' &&
            (messages.isNotEmpty || value['canSend'] == true)) ||
        (value['hasEarlier'] == true &&
            (messages.isEmpty || value['before'] != messages.first.id))) {
      throw const FormatException('Invalid conversation history cursor.');
    }
    return ConversationPage(
      session: value['session'],
      status: value['status'],
      messages: List.unmodifiable(messages),
      before: value['before'],
      hasEarlier: value['hasEarlier'],
      canSend: value['canSend'],
    );
  }
}
