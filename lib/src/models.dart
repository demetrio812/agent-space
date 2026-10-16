import 'dart:convert';

import 'network_models.dart';

const maxCatalogBytes = 2 * 1024 * 1024;
const maxInputBytes = 16 * 1024;
final terminalIdPattern = RegExp(
  r'^[A-Za-z0-9_.:@%+/][A-Za-z0-9_.:@%+/-]{0,255}$',
);
bool validIdentity(String value) =>
    value.isNotEmpty &&
    value.length <= 512 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f]')
        .hasMatch(value);
String displayText(Object? value) {
  if (value is! String) return '';
  final limited = value.length > 4096 ? value.substring(0, 4096) : value;
  final clean = limited
      .replaceAll(
        RegExp(
          '\u001b\\[[0-?]*[ -/]*[@-~]|\u001b\\][^\u0007\u001b]*(?:\u0007|\u001b\\\\)',
        ),
        '',
      )
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.length > 256 ? clean.substring(0, 256) : clean;
}

enum SessionStatus {
  done,
  needsInput,
  idle,
  working,
  unknown;

  static SessionStatus parse(String raw) =>
      switch (raw.toLowerCase().replaceAll('-', '_')) {
        'done' || 'completed' || 'complete' => done,
        'question' ||
        'needs_input' ||
        'waiting' ||
        'attention' ||
        'waiting_for_input' => needsInput,
        'idle' => idle,
        'working' || 'running' || 'busy' || 'thinking' || 'active' => working,
        _ => unknown,
      };
  String get label => switch (this) {
    done => 'Done',
    needsInput => 'Needs input',
    idle => 'Idle',
    working => 'Working',
    unknown => 'Unknown',
  };
}

class SessionKey {
  const SessionKey(this.backend, this.profile, this.server, this.terminal);
  final String backend, profile, server, terminal;
  String get id => base64UrlEncode(
    utf8.encode(jsonEncode([backend, profile, server, terminal])),
  ).replaceAll('=', '');
  static SessionKey? decode(String value) {
    try {
      if (value.length > 8192) return null;
      final fields = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(value))),
      );
      if (fields is! List ||
          fields.length != 4 ||
          fields.any((e) => e is! String || !validIdentity(e))) {
        return null;
      }
      return SessionKey(fields[0], fields[1], fields[2], fields[3]);
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is SessionKey && id == other.id;
  @override
  int get hashCode => Object.hash(backend, profile, server, terminal);
}

class SessionInfo {
  const SessionInfo({
    required this.key,
    required this.paneId,
    required this.title,
    required this.project,
    required this.agent,
    required this.status,
    this.workspaceId = '',
    this.workspaceLabel = '',
    this.terminalTitle = '',
    this.inputEnabled = false,
    this.terminalInputEnabled = false,
    this.terminalViewportEnabled = false,
    this.imageTransferEnabled = false,
    this.available = true,
    this.origin,
  });
  final SessionKey key;
  final SessionOrigin? origin;
  String get computerId =>
      origin?.computerId ??
      SessionOrigin(
        profile: key.profile,
        machineId: 'gateway',
        machineLabel: '',
        herdrSession: 'default',
        targetHash: '',
        generation: '',
      ).computerId;
  String get workspaceFilterId =>
      origin == null ? workspaceId : scopedWorkspaceId(origin!, workspaceId);
  SessionInfo withOrigin(SessionOrigin value) => SessionInfo(
    key: originKey(value, key.terminal),
    origin: value,
    paneId: paneId,
    title: title,
    project: project,
    agent: agent,
    status: status,
    workspaceId: workspaceId,
    workspaceLabel: workspaceLabel,
    terminalTitle: terminalTitle,
    inputEnabled: inputEnabled,
    terminalInputEnabled: terminalInputEnabled,
    terminalViewportEnabled: terminalViewportEnabled,
    imageTransferEnabled: imageTransferEnabled,
    available: available,
  );
  final String paneId,
      title,
      project,
      agent,
      workspaceId,
      workspaceLabel,
      terminalTitle;
  final SessionStatus status;
  final bool inputEnabled,
      terminalInputEnabled,
      terminalViewportEnabled,
      imageTransferEnabled,
      available;
  SessionInfo unavailable() => SessionInfo(
    key: key,
    origin: origin,
    paneId: paneId,
    title: title,
    project: project,
    agent: agent,
    status: status,
    workspaceId: workspaceId,
    workspaceLabel: workspaceLabel,
    terminalTitle: terminalTitle,
    inputEnabled: false,
    available: false,
  );
  Map<String, dynamic> toJson() => {
    'id': key.id,
    'pane': paneId,
    'title': title,
    'project': project,
    'agent': agent,
    'status': status.name,
    'workspace': workspaceId,
    'workspaceLabel': workspaceLabel,
    'terminalTitle': terminalTitle,
    if (origin != null) 'origin': origin!.toJson(),
  };
  static SessionInfo? fromJson(dynamic json) {
    if (json is! Map) return null;
    final key = SessionKey.decode(json['id'] is String ? json['id'] : '');
    if (key == null) return null;
    final origin = json['origin'] == null
        ? null
        : SessionOrigin.fromJson(json['origin']);
    if ((json['origin'] != null && origin == null) ||
        (key.backend == 'herdr-peer' && origin == null)) {
      return null;
    }
    if (origin != null) {
      try {
        if (originKey(origin, key.terminal) != key) return null;
      } catch (_) {
        return null;
      }
    }
    final status =
        SessionStatus.values
            .where((s) => s.name == json['status'])
            .firstOrNull ??
        SessionStatus.unknown;
    return SessionInfo(
      key: key,
      origin: origin,
      paneId: displayText(json['pane']),
      title: displayText(json['title']),
      project: displayText(json['project']),
      agent: displayText(json['agent']),
      status: status,
      workspaceId:
          json['workspace'] is String && validIdentity(json['workspace'])
          ? json['workspace']
          : '',
      workspaceLabel: displayText(json['workspaceLabel']),
      terminalTitle: displayText(json['terminalTitle']),
      inputEnabled: false,
      available: false,
    );
  }
}

bool failedResponse(Map<dynamic, dynamic> value) =>
    value['error'] != null || value['ok'] == false || value['success'] == false;
List<SessionInfo> parseCatalog(String json, String profile) {
  try {
    if (utf8.encode(json).length > maxCatalogBytes || !validIdentity(profile)) {
      throw const FormatException();
    }
    final root = jsonDecode(json);
    if (root is! Map ||
        failedResponse(root) ||
        root['serverIdentity'] is! String ||
        !validIdentity(root['serverIdentity'])) {
      throw const FormatException();
    }
    final catalog = root['catalog'];
    if (catalog is! Map ||
        failedResponse(catalog) ||
        catalog['result'] is! Map ||
        failedResponse(catalog['result'])) {
      throw const FormatException();
    }
    final agents = catalog['result']['agents'];
    if (agents is! List || agents.length > 4096) throw const FormatException();
    final workspaces = root['workspaces'] ?? [];
    final tabs = root['tabs'] ?? [];
    if (workspaces is! List ||
        tabs is! List ||
        workspaces.length > 4096 ||
        tabs.length > 4096) {
      throw const FormatException();
    }
    final workspaceNames = <String, String>{};
    for (final row in workspaces.whereType<Map>()) {
      final id = row['workspace_id'];
      final name = displayText(row['label']);
      if (id is String && validIdentity(id) && name.isNotEmpty) {
        workspaceNames[id] = name;
      }
    }
    final tabNames = <String, String>{};
    for (final row in tabs.whereType<Map>()) {
      final workspace = row['workspace_id'];
      final tab = row['tab_id'];
      final label = displayText(row['label']);
      if (workspace is String &&
          tab is String &&
          validIdentity(workspace) &&
          validIdentity(tab) &&
          label.isNotEmpty &&
          label != row['number']?.toString()) {
        tabNames[jsonEncode([workspace, tab])] = label;
      }
    }
    final seen = <String>{};
    final result = <SessionInfo>[];
    for (final item in agents.whereType<Map>()) {
      final terminal = item['terminal_id'];
      if (terminal is! String ||
          !terminalIdPattern.hasMatch(terminal) ||
          !seen.add(terminal)) {
        continue;
      }
      final title =
          [
            item['terminal_title_stripped'],
            item['terminal_title'],
            item['name'],
          ].map(displayText).where((s) => s.isNotEmpty).firstOrNull ??
          terminal;
      final cwd =
          (item['foreground_cwd'] is String &&
                      (item['foreground_cwd'] as String).isNotEmpty
                  ? item['foreground_cwd']
                  : item['cwd'])
              as String? ??
          '';
      final project = displayText(
        cwd.replaceAll(RegExp(r'/+$'), '').split('/').last,
      );
      final workspace =
          item['workspace_id'] is String && validIdentity(item['workspace_id'])
          ? item['workspace_id'] as String
          : '';
      result.add(
        SessionInfo(
          key: SessionKey('herdr', profile, root['serverIdentity'], terminal),
          paneId: displayText(item['pane_id']),
          title: displayText(item['title']).isNotEmpty
              ? displayText(item['title'])
              : tabNames[jsonEncode([workspace, item['tab_id']])] ?? title,
          project: project.isEmpty ? 'Unknown project' : project,
          agent: displayText(item['agent']).isEmpty
              ? 'terminal'
              : displayText(item['agent']),
          status: SessionStatus.parse(displayText(item['agent_status'])),
          workspaceId: workspace,
          workspaceLabel:
              workspaceNames[workspace] ??
              (project.isEmpty ? 'Ungrouped' : project),
          terminalTitle: title,
          inputEnabled: root['inputEnabled'] == true,
          terminalInputEnabled:
              root['inputEnabled'] == true &&
              root['terminalInputEnabled'] == true,
          imageTransferEnabled:
              root['inputEnabled'] == true &&
              root['imageTransferEnabled'] == true,
          terminalViewportEnabled:
              root['inputEnabled'] == true &&
              root['terminalViewportEnabled'] == true,
        ),
      );
    }
    return result;
  } catch (_) {
    throw const FormatException('Herdr returned an invalid or failed catalog.');
  }
}

String? validateInput(String text) {
  if (text.trim().isEmpty) return 'Write a message first.';
  if (utf8.encode(text).length > maxInputBytes) {
    return 'Keep the message under 16 KiB.';
  }
  if (RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]').hasMatch(text)) {
    return 'The message contains a terminal control character.';
  }
  if (utf8.decode(utf8.encode(text)) != text) {
    return 'The message contains invalid Unicode.';
  }
  return null;
}

bool validTerminalKey(String key) {
  if (key.length > 40) return false;
  final parts = key.split('+');
  final name = parts.removeLast();
  if (parts.toSet().length != parts.length ||
      parts.any((p) => !const {'ctrl', 'alt', 'shift', 'cmd'}.contains(p))) {
    return false;
  }
  return RegExp(
    r'^(?:[a-z0-9]|up|down|left|right|enter|esc|tab|backspace|delete|insert|home|end|pageup|pagedown|space|f[1-9]|f1[0-2])$',
  ).hasMatch(name);
}

/// Literal typing and logical keys never implicitly append Enter.
class TerminalInput {
  const TerminalInput.text(String value)
    : isPaste = false,
      textValue = value,
      keyNames = null,
      clickCell = null;
  const TerminalInput.paste(String value)
    : isPaste = true,
      textValue = value,
      keyNames = null,
      clickCell = null;
  TerminalInput.keys(List<String> values)
    : isPaste = false,
      textValue = null,
      keyNames = List.unmodifiable(values),
      clickCell = null;
  const TerminalInput.click(int column, int row)
    : isPaste = false,
      textValue = null,
      keyNames = null,
      clickCell = (column: column, row: row);
  final ({int column, int row})? clickCell;
  int get estimatedBytes => textValue != null
      ? utf8.encode(textValue!).length
      : clickCell != null
      ? 64
      : keyNames!.length * 40;
  final bool isPaste;
  final String? textValue;
  final List<String>? keyNames;
  Map<String, dynamic> toJson() => textValue != null
      ? {isPaste ? 'paste' : 'text': textValue}
      : clickCell != null
      ? {
          'click': {'column': clickCell!.column, 'row': clickCell!.row},
        }
      : {'keys': keyNames};
  String? get validationError {
    final cell = clickCell;
    if (cell != null) {
      return cell.column >= 0 &&
              cell.column < 512 &&
              cell.row >= 0 &&
              cell.row < 256
          ? null
          : 'Invalid terminal click.';
    }
    final text = textValue;
    if (text != null) {
      if (text.isEmpty || utf8.encode(text).length > maxInputBytes) {
        return 'Keep terminal typing under 16 KiB per batch.';
      }
      if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text) ||
          utf8.decode(utf8.encode(text)) != text) {
        return 'Invalid terminal text.';
      }
    } else if (keyNames == null ||
        keyNames!.isEmpty ||
        keyNames!.length > 32 ||
        keyNames!.any((k) => !validTerminalKey(k))) {
      return 'Unsupported terminal key.';
    }
    return null;
  }
}

enum ConnectionKind { local, ssh }

class ConnectionProfile {
  ConnectionProfile({
    required this.id,
    required this.label,
    this.kind = ConnectionKind.local,
    this.executable = '',
    this.socketPath = '',
    this.host = '',
    this.port = 22,
    this.username = '',
    this.privateKeyPath = '',
    this.hostFingerprint = '',
  });
  final String id;
  String label,
      executable,
      socketPath,
      host,
      username,
      privateKeyPath,
      hostFingerprint;
  ConnectionKind kind;
  int port;
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'kind': kind.name,
    'executable': executable,
    'socketPath': socketPath,
    'host': host,
    'port': port,
    'username': username,
    'privateKeyPath': privateKeyPath,
    'hostFingerprint': hostFingerprint,
  };
  static ConnectionProfile? fromJson(dynamic j) {
    if (j is! Map || j['id'] is! String || !validIdentity(j['id'])) return null;
    String s(String k) => j[k] is String ? j[k] : '';
    return ConnectionProfile(
      id: s('id'),
      label: displayText(j['label']),
      kind: j['kind'] == 'ssh' ? ConnectionKind.ssh : ConnectionKind.local,
      executable: s('executable'),
      socketPath: s('socketPath'),
      host: s('host'),
      port: j['port'] is int && j['port'] > 0 && j['port'] <= 65535
          ? j['port']
          : 22,
      username: s('username'),
      privateKeyPath: s('privateKeyPath'),
      hostFingerprint: s('hostFingerprint'),
    );
  }
}
