import 'dart:convert';

import 'models.dart';
import 'network_models.dart';

const sessionManagementOperations = {'rename', 'close', 'create'};

abstract interface class SessionManagementBackend {
  void cancelPendingSessionActions();
  List<ComputerInfo> get sessionComputers;
  Future<void> renameSession(SessionInfo session, String title);
  Future<void> closeSession(SessionInfo session);
  Future<SessionInfo> createSession(
    SessionOrigin origin,
    SessionWorkspace workspace, {
    String title = '',
    String cwd = '',
  });
}

class SessionActionState {
  bool pending = false;
  String? error;
}

class SessionActionRecord {
  const SessionActionRecord(this.operation, this.origin);
  final String operation;
  final SessionOrigin origin;
  Map<String, dynamic> toJson() => {
    'operation': operation,
    'origin': origin.toJson(),
  };
  static SessionActionRecord? fromJson(Object? value) {
    if (value is! Map ||
        !sessionManagementOperations.contains(value['operation'])) {
      return null;
    }
    final origin = SessionOrigin.fromJson(value['origin']);
    return origin == null
        ? null
        : SessionActionRecord(value['operation'] as String, origin);
  }
}

void validateSessionAction(String op, Map<String, dynamic> payload) {
  final fields = switch (op) {
    'rename' => {'title'},
    'close' => <String>{},
    'create' => {'workspace', 'title', 'cwd'},
    _ => throw ArgumentError('Unsupported session action.'),
  };
  if (payload.length != fields.length || !fields.containsAll(payload.keys)) {
    throw ArgumentError('Invalid session action.');
  }
  void bounded(Object? value, int limit) {
    if (value is! String ||
        utf8.encode(value).length > limit ||
        value.runes.any((c) => c < 32 || c >= 127 && c < 160)) {
      throw ArgumentError(
        'Use text without control characters and within the length limit.',
      );
    }
  }

  if (op != 'close') bounded(payload['title'], 128);
  if (op == 'create') {
    if (payload['workspace'] is! String ||
        !terminalIdPattern.hasMatch(payload['workspace'] as String)) {
      throw ArgumentError('Choose a workspace.');
    }
    bounded(payload['cwd'], 4096);
    final cwd = payload['cwd'] as String;
    if (cwd.isNotEmpty && !cwd.startsWith('/') && !cwd.startsWith('~/')) {
      throw ArgumentError('Folder must start with / or ~/.');
    }
  }
}

void validateSessionActionRoute(String op, Map<String, dynamic>? route) {
  final fields = {
    'machine',
    'session',
    'targetHash',
    'generation',
    if (op != 'create') ...['terminal', 'pane'],
  };
  if (route == null ||
      route.length != fields.length ||
      !fields.containsAll(route.keys) ||
      route['machine'] is! String ||
      !RegExp(r'^(gateway|[0-9a-f]{32})$')
          .hasMatch(route['machine'] as String) ||
      route['session'] is! String ||
      !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(route['session'] as String) ||
      const ['.', '..'].contains(route['session']) ||
      ['targetHash', 'generation'].any(
        (k) =>
            route[k] is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(route[k] as String),
      ) ||
      op != 'create' &&
          ['terminal', 'pane'].any(
            (k) =>
                route[k] is! String ||
                !terminalIdPattern.hasMatch(route[k] as String),
          )) {
    throw ArgumentError('This session has no verified computer.');
  }
}

bool sameSessionOrigin(SessionOrigin a, SessionOrigin b) =>
    a.profile == b.profile &&
    a.machineId == b.machineId &&
    a.herdrSession == b.herdrSession &&
    a.targetHash == b.targetHash &&
    a.generation == b.generation;
