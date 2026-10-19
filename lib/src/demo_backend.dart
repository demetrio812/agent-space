import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'backend.dart';
import 'models.dart';
import 'protocol.dart';
import 'network_models.dart';

class DemoBackend
    implements
        SessionBackend,
        TerminalInputBackend,
        TerminalViewportBackend,
        SessionManagementBackend {
  @override
  String get sourceId => 'demo';
  final _streams = <String, StreamController<ObserveEvent>>{};
  final _timers = <String, Timer>{};
  final _messages = <String, List<String>>{};
  final _sequence = <String, int>{};
  final _typing = <String, String>{};
  final _sizes = <String, (int, int)>{};
  bool _closed = false;
  int _managementEpoch = 0;
  @override
  void cancelPendingSessionActions() {
    _managementEpoch++;
  }

  final _renamed = <String, String>{}, _closedSessions = <String>{};
  final _created = <SessionInfo>[];
  int _createdCount = 0;
  final _createdWorkspaces = <SessionWorkspace>[];
  static const demoOrigin = SessionOrigin(
    profile: 'demo',
    machineId: 'gateway',
    machineLabel: 'Demo computer',
    herdrSession: 'default',
    targetHash:
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
    generation:
        'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  );
  @override
  List<ComputerInfo> get sessionComputers => [
    ComputerInfo(
      origin: demoOrigin,
      state: ComputerState.live,
      managementEnabled: true,
      workspaces: [
        SessionWorkspace('demo-workspace-0', 'Studio'),
        SessionWorkspace('demo-workspace-1', 'Library'),
        const SessionWorkspace('demo-workspace-2', 'AgentSpace'),
        ..._createdWorkspaces,
      ],
    ),
  ];
  static const _names = [
    'Build navigation',
    'Review API changes',
    'Fix keyboard focus',
    'Write release notes',
    'Index the library',
    'Compare layouts',
    'Add search filters',
    'Audit dependencies',
    'Tidy the workspace',
    'Check terminal menus',
    'Polish the mobile view',
    'Plan the next release',
  ];
  static const _agents = ['Claude', 'Codex', 'Gemini'];
  @override
  Future<List<SessionInfo>> listSessions() async =>
      List.generate(
            12,
            (i) => SessionInfo(
              key: SessionKey('demo', 'demo', 'sample-v1', 'session-${i + 1}'),
              origin: demoOrigin,
              paneId: 'pane-${i + 1}',
              title: _renamed['session-${i + 1}'] ?? _names[i],
              project: i < 4
                  ? 'studio'
                  : i < 8
                  ? 'library'
                  : 'agentspace',
              agent: _agents[i % 3],
              status: [
                SessionStatus.working,
                SessionStatus.needsInput,
                SessionStatus.done,
                SessionStatus.idle,
              ][i % 4],
              workspaceId: 'demo-workspace-${i ~/ 4}',
              workspaceLabel: ['Studio', 'Library', 'AgentSpace'][i ~/ 4],
              terminalTitle: '${_agents[i % 3]} · ${_names[i]}',
              inputEnabled: true,
              terminalInputEnabled: true,
              terminalViewportEnabled: true,
            ),
          )
          .where((s) => !_closedSessions.contains(s.key.terminal))
          .followedBy(
            _created
                .where((s) => !_closedSessions.contains(s.key.terminal))
                .map(
                  (s) => SessionInfo(
                    key: s.key,
                    paneId: s.paneId,
                    origin: s.origin,
                    title: _renamed[s.key.terminal] ?? s.title,
                    project: s.project,
                    agent: s.agent,
                    status: s.status,
                    workspaceId: s.workspaceId,
                    workspaceLabel: s.workspaceLabel,
                    terminalTitle: s.terminalTitle,
                    inputEnabled: true,
                    terminalInputEnabled: true,
                    terminalViewportEnabled: true,
                  ),
                ),
          )
          .toList();

  Future<void> _verify(SessionInfo session) async {
    if (_closed ||
        !sameSessionOrigin(session.origin ?? demoOrigin, demoOrigin) ||
        !(await listSessions()).any(
          (s) => s.key == session.key && s.paneId == session.paneId,
        )) {
      throw SessionUnavailable();
    }
  }

  @override
  Future<void> renameSession(SessionInfo session, String title) async {
    final epoch = _managementEpoch;
    validateSessionAction('rename', {'title': title});
    await _verify(session);
    if (epoch != _managementEpoch) {
      throw SessionUnavailable('Session action cancelled.');
    }
    _renamed[session.key.terminal] = title.isEmpty ? 'Shell' : title;
  }

  @override
  Future<void> closeSession(SessionInfo session) async {
    final epoch = _managementEpoch;
    await _verify(session);
    if (epoch != _managementEpoch) {
      throw SessionUnavailable('Session action cancelled.');
    }
    _closedSessions.add(session.key.terminal);
  }

  @override
  Future<SessionInfo> createSession(
    SessionOrigin origin,
    SessionWorkspace workspace, {
    String title = '',
    String cwd = '',
  }) async {
    validateSessionAction('create', {
      'workspace': workspace.id,
      'title': title,
      'cwd': cwd,
    });
    if (_closed ||
        !sameSessionOrigin(origin, demoOrigin) ||
        !sessionComputers.single.workspaces.any((w) => w.id == workspace.id)) {
      throw SessionUnavailable();
    }
    final number = ++_createdCount;
    final session = SessionInfo(
      key: SessionKey('demo', 'demo', 'sample-v1', 'created-$number'),
      origin: demoOrigin,
      paneId: 'created-pane-$number',
      title: title.isEmpty ? 'Shell' : title,
      project: cwd.isEmpty ? 'Home' : cwd.split('/').last,
      agent: 'terminal',
      status: SessionStatus.idle,
      workspaceId: workspace.id,
      workspaceLabel: workspace.label,
      terminalTitle: 'Shell',
      inputEnabled: true,
      terminalInputEnabled: true,
      terminalViewportEnabled: true,
    );
    _created.add(session);
    return session;
  }

  @override
  Future<SessionInfo> createWorkspace(
    SessionOrigin origin, {
    required String title,
    String cwd = '',
  }) async {
    validateSessionAction('workspace.create', {'title': title, 'cwd': cwd});
    if (_closed || !sameSessionOrigin(origin, demoOrigin)) {
      throw SessionUnavailable();
    }
    final workspace = SessionWorkspace(
      'created-workspace-${_createdWorkspaces.length + 1}',
      title,
    );
    _createdWorkspaces.add(workspace);
    return createSession(origin, workspace, cwd: cwd);
  }

  TerminalFrame _frame(SessionInfo session) {
    final (cols, rows) = _sizes[session.key.id] ?? (100, 26);
    final n = int.tryParse(session.key.terminal.split('-').last) ?? 1;
    final lines = <String>[
      '\u001b[36m${session.agent}\u001b[0m  /  ${session.project}',
      '',
      '\u001b[1m${session.title}\u001b[0m',
      '',
      'This is a synthetic session. No real agents are connected.',
      '',
      '\u001b[90mInspecting the workspace…\u001b[0m',
      '  ✓ Read project instructions',
      '  ✓ Loaded ${8 + n} source files',
      '  ✓ Checked the current changes',
      '',
      if (session.status == SessionStatus.done)
        '\u001b[32m✓ Complete. The changes are ready for review.\u001b[0m'
      else if (session.status == SessionStatus.needsInput)
        '\u001b[33m? Which option would you like to use?\u001b[0m'
      else if (session.status == SessionStatus.idle)
        'Waiting for your next message.'
      else
        'Working through the next step…',
      '',
      ...?_messages[session.key.id],
    ];
    final text =
        '\u001b[2J\u001b[H${lines.take((rows - 4).clamp(0, 22)).join('\r\n')}\u001b[${(rows - 1).clamp(1, 256)};1H\u001b[90mDemo mode · ${session.status.label} · UTF-8: café 日本語\u001b[0m\u001b[$rows;1H› ';
    final seq = _sequence.update(
      session.key.id,
      (v) => v + 1,
      ifAbsent: () => 0,
    );
    return TerminalFrame(
      cols,
      rows,
      seq,
      true,
      Uint8List.fromList(utf8.encode(text)),
    );
  }

  @override
  Stream<ObserveEvent> observe(SessionInfo session) {
    late StreamController<ObserveEvent> stream;
    stream = StreamController<ObserveEvent>(
      onListen: () {
        if (_closed) {
          unawaited(stream.close());
          return;
        }
        _streams[session.key.id] = stream;
        stream.add(_frame(session));
        _timers[session.key.id] = Timer.periodic(const Duration(seconds: 2), (
          _,
        ) {
          if (!stream.isClosed) stream.add(_frame(session));
        });
      },
      onCancel: () {
        _timers.remove(session.key.id)?.cancel();
        if (_streams[session.key.id] == stream) _streams.remove(session.key.id);
      },
    );
    return stream.stream;
  }

  @override
  Stream<ObserveEvent> observeViewport(
    SessionInfo session,
    int cols,
    int rows,
  ) {
    if (!validViewport(cols, rows)) {
      throw ArgumentError('Invalid terminal dimensions.');
    }
    _sizes[session.key.id] = (cols, rows);
    return observe(session);
  }

  @override
  Future<void> resizeViewport(SessionInfo session, int cols, int rows) async {
    if (!validViewport(cols, rows)) {
      throw ArgumentError('Invalid terminal dimensions.');
    }
    _sizes[session.key.id] = (cols, rows);
    final stream = _streams[session.key.id];
    if (stream != null && !stream.isClosed) stream.add(_frame(session));
  }

  @override
  Future<void> sendText(SessionInfo session, String text) async {
    final invalid = validateInput(text);
    if (invalid != null) throw ArgumentError(invalid);
    if (_closed) throw ConnectionFailure('Demo closed.');
    final safe = text.replaceAll('\n', ' ').trim();
    _messages[session.key.id] = [
      '› ${safe.length > 85 ? '${safe.substring(0, 85)}…' : safe}',
      '\u001b[32mReceived locally. This demo does not run commands.\u001b[0m',
    ];
    final stream = _streams[session.key.id];
    if (stream != null && !stream.isClosed) stream.add(_frame(session));
  }

  @override
  Future<void> sendTerminalInput(
    SessionInfo session,
    TerminalInput input,
  ) async {
    final invalid = input.validationError;
    if (invalid != null) throw ArgumentError(invalid);
    if (_closed) throw ConnectionFailure('Demo closed.');
    if (input.textValue != null) {
      final value = '${_typing[session.key.id] ?? ''}${input.textValue!}';
      _typing[session.key.id] = value.length > 85
          ? value.substring(value.length - 85)
          : value;
    }
    _messages[session.key.id] = [
      '› ${_typing[session.key.id] ?? ''}',
      if (input.keyNames != null)
        'Keys received: ${input.keyNames!.join(', ')}',
      'Demo input stays on this device.',
    ];
    final stream = _streams[session.key.id];
    if (stream != null && !stream.isClosed) stream.add(_frame(session));
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final stream in _streams.values) {
      unawaited(stream.close());
    }
    _streams.clear();
  }
}
