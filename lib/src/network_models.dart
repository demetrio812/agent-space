import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

String _scopeHash(List<String> fields) =>
    sha256.convert(utf8.encode(jsonEncode(fields))).toString();
final _machineId = RegExp(r'^(?:gateway|[0-9a-f]{32})$');
final _sessionName = RegExp(r'^[A-Za-z0-9_.-]{1,64}$');
final _generation = RegExp(r'^[0-9a-f]{64}$');

class SessionOrigin {
  const SessionOrigin({
    required this.profile,
    required this.machineId,
    required this.machineLabel,
    required this.herdrSession,
    required this.targetHash,
    required this.generation,
  });
  final String profile,
      machineId,
      machineLabel,
      herdrSession,
      targetHash,
      generation;
  bool get isGateway => machineId == 'gateway';
  String get computerId => _scopeHash([profile, machineId, herdrSession]);
  bool get valid =>
      validIdentity(profile) &&
      _machineId.hasMatch(machineId) &&
      _sessionName.hasMatch(herdrSession) &&
      herdrSession != '.' &&
      herdrSession != '..' &&
      _generation.hasMatch(targetHash) &&
      _generation.hasMatch(generation);
  Map<String, dynamic> toJson() => {
    'profile': profile,
    'machineId': machineId,
    'machineLabel': machineLabel,
    'herdrSession': herdrSession,
    'targetHash': targetHash,
    'generation': generation,
  };
  static SessionOrigin? fromJson(Object? value) {
    if (value is! Map ||
        [
          'profile',
          'machineId',
          'herdrSession',
          'targetHash',
          'generation',
        ].any((k) => value[k] is! String)) {
      return null;
    }
    final origin = SessionOrigin(
      profile: value['profile'],
      machineId: value['machineId'],
      machineLabel: displayText(value['machineLabel']),
      herdrSession: value['herdrSession'],
      targetHash: value['targetHash'],
      generation: value['generation'],
    );
    return origin.valid ? origin : null;
  }

  Map<String, dynamic> get computerRoute => {
    'machine': machineId,
    'session': herdrSession,
    'targetHash': targetHash,
    'generation': generation,
  };

  Map<String, dynamic> route(String terminal, String pane) => {
    'machine': machineId,
    'session': herdrSession,
    'targetHash': targetHash,
    'generation': generation,
    'terminal': terminal,
    'pane': pane,
  };
}

SessionKey originKey(SessionOrigin origin, String terminal) {
  if (!origin.valid || !terminalIdPattern.hasMatch(terminal)) {
    throw const FormatException('Session has no verified origin.');
  }
  if (origin.isGateway) {
    return SessionKey('herdr', origin.profile, origin.generation, terminal);
  }
  return SessionKey(
    'herdr-peer',
    origin.profile,
    _scopeHash([
      origin.machineId,
      origin.herdrSession,
      origin.targetHash,
      origin.generation,
    ]),
    terminal,
  );
}

String scopedWorkspaceId(SessionOrigin origin, String workspace) =>
    'workspace:${_scopeHash([origin.computerId, workspace])}';

List<SessionInfo> parseOriginCatalog(String raw, SessionOrigin origin) {
  final catalog = jsonDecode(raw);
  if (!origin.valid ||
      catalog is! Map ||
      catalog['serverIdentity'] != origin.generation) {
    throw const FormatException('Catalog origin changed.');
  }
  return parseCatalog(
    raw,
    origin.profile,
  ).map((s) => s.withOrigin(origin)).toList();
}

enum ComputerState { connecting, live, offline, attention, disabled }

class SessionWorkspace {
  const SessionWorkspace(this.id, this.label);
  final String id, label;
}

List<SessionWorkspace> parseSessionWorkspaces(Object? value) {
  if (value is! List || value.length > 4096) return [];
  final seen = <String>{};
  return [
    for (final row in value)
      if (row is Map &&
          row['workspace_id'] is String &&
          terminalIdPattern.hasMatch(row['workspace_id'] as String) &&
          seen.add(row['workspace_id'] as String))
        SessionWorkspace(
          row['workspace_id'] as String,
          displayText(row['label']),
        ),
  ];
}

class ComputerInfo {
  const ComputerInfo({
    required this.origin,
    required this.state,
    this.message = '',
    this.managementEnabled = false,
    this.workspaces = const [],
  });
  final bool managementEnabled;
  final List<SessionWorkspace> workspaces;
  final SessionOrigin origin;
  final ComputerState state;
  final String message;
  String get stateLabel => switch (state) {
    ComputerState.connecting => 'Connecting…',
    ComputerState.live => 'Connected',
    ComputerState.offline => 'Unavailable',
    ComputerState.attention => 'Needs attention',
    ComputerState.disabled => 'Disabled in Herdr',
  };
}

class NetworkUpdate {
  const NetworkUpdate({
    required this.epoch,
    required this.computers,
    required this.sessions,
    required this.complete,
  });
  final int epoch;
  final List<ComputerInfo> computers;
  final List<SessionInfo> sessions;
  final bool complete;
}
