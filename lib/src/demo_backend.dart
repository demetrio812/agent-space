import 'demo_file_browser.dart';
import 'file_browser.dart';
import 'project_files.dart';
import 'git_metadata.dart';
import 'conversation.dart';

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
        SessionManagementBackend,
        ConversationBackend,
        ProjectFilesBackend,
        FileBrowserBackend {
  late final _browser = DemoFileBrowser(listProjectFiles, readProjectFile);
  @override
  Future<Map<String, dynamic>> fileBrowserRequest(
    SessionInfo session,
    String op,
    Map<String, dynamic> payload,
  ) => _browser.request(session, op, payload);

  String _fileId(int value) => value.toRadixString(16).padLeft(64, '0');
  @override
  Future<ProjectManifest> listProjectFiles(SessionInfo session) async =>
      ProjectManifest.fromJson({
        'scope': _fileId(10),
        'folder': 'orbit-api',
        'limited': false,
        'files': [
          for (final entry in [
            (1, 'README.md', 'files', ''),
            (2, 'AGENTS.md', 'files', ''),
            (3, 'preview.html', 'files', ''),
            (4, 'requirements.md', 'specs', 'team-invitations'),
            (5, 'design.md', 'specs', 'team-invitations'),
            (6, 'tasks.md', 'specs', 'team-invitations'),
          ])
            {
              'id': _fileId(entry.$1),
              'name': entry.$2,
              'path': entry.$3 == 'specs'
                  ? '.kiro/specs/${entry.$4}/${entry.$2}'
                  : entry.$2,
              'kind': entry.$1 == 3 ? 'html' : 'markdown',
              'section': entry.$3,
              'feature': entry.$4,
              'revision': _fileId(100 + entry.$1),
            },
        ],
      });
  @override
  Future<ProjectDocument> readProjectFile(
    SessionInfo session,
    String scope,
    String file,
  ) async {
    if (scope != _fileId(10)) throw SessionUnavailable();
    final index = int.tryParse(file, radix: 16);
    final text = switch (index) {
      1 => '# Orbit API\n\nA small API for teams that work together.\n\n## Getting started\n\n```sh\nnpm install\nnpm run dev\n```\n\n## Team invitations\n\nInvite members with secure, expiring links. Read [the instructions](AGENTS.md) before changing the API.',
      2 => '# Project instructions\n\n- Read the relevant specification.\n- Keep changes focused.\n- Run tests before opening a pull request.',
      3 => '<html><head><style>body{font-family:system-ui;padding:32px;background:#f2f6f5;color:#24483d}article{padding:24px;background:white;border-radius:14px}h1{font-size:28px}a{display:block;background:#28664e;color:white;padding:12px;border-radius:6px;text-align:center}</style></head><body><h2>◉ Orbit</h2><article><h1>A place on the team.</h1><p>Sam invited you to join the Design team on Orbit.</p><a href="https://example.com">Accept invitation</a><p>This invitation expires in 48 hours.</p></article></body></html>',
      4 => '# Team invitations\n\n## Requirements\n\nWHEN an administrator invites a member, THE SYSTEM SHALL email a secure link that expires after 48 hours.',
      5 => '# Technical design\n\n## Invitation flow\n\nAdministrator → Invitation service → Email → New member\n\n## Data model\n\nStore a team identifier, recipient, hashed token and expiration date.',
      6 => '# Implementation tasks\n\n- [x] 1. Add invitation model\n- [x] 2. Create invite endpoint\n- [x] 3. Add invitation email\n- [ ] 4. Implement acceptance\n- [ ] 5. Handle expired links\n- [ ] 6. Add integration tests',
      _ => throw SessionUnavailable(),
    };
    return ProjectDocument(
      scope: scope,
      file: file,
      revision: _fileId(100 + index!),
      text: text,
    );
  }

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
  final _workspaceLabels = <String, String>{};
  final _closedWorkspaces = <String>{};
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
      workspaces:
          [
                SessionWorkspace('demo-workspace-0', 'Studio'),
                SessionWorkspace('demo-workspace-1', 'Library'),
                const SessionWorkspace('demo-workspace-2', 'AgentSpace'),
                ..._createdWorkspaces,
              ]
              .where((w) => !_closedWorkspaces.contains(w.id))
              .map(
                (w) =>
                    SessionWorkspace(w.id, _workspaceLabels[w.id] ?? w.label),
              )
              .toList(),
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
              workspaceLabel:
                  _workspaceLabels['demo-workspace-${i ~/ 4}'] ??
                  ['Studio', 'Library', 'AgentSpace'][i ~/ 4],
              terminalTitle: '${_agents[i % 3]} · ${_names[i]}',
              git: GitMetadata(
                repoUrl: 'https://github.com/example/orbit',
                branch: i % 2 == 0 ? 'feature/navigation' : 'main',
                prNumber: i % 2 == 0 ? 42 : 0,
                prState: i % 2 == 0 ? 'OPEN' : '',
              ),
              inputEnabled: true,
              terminalInputEnabled: true,
              terminalViewportEnabled: true,
            ),
          )
          .where(
            (s) =>
                !_closedSessions.contains(s.key.terminal) &&
                !_closedWorkspaces.contains(s.workspaceId),
          )
          .followedBy(
            _created
                .where(
                  (s) =>
                      !_closedSessions.contains(s.key.terminal) &&
                      !_closedWorkspaces.contains(s.workspaceId),
                )
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
                    workspaceLabel:
                        _workspaceLabels[s.workspaceId] ?? s.workspaceLabel,
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

  void _verifyWorkspace(SessionOrigin origin, SessionWorkspace workspace) {
    if (_closed ||
        !sameSessionOrigin(origin, demoOrigin) ||
        !sessionComputers.single.workspaces.any((w) => w.id == workspace.id)) {
      throw SessionUnavailable();
    }
  }

  @override
  Future<void> renameWorkspace(
    SessionOrigin origin,
    SessionWorkspace workspace,
    String title,
  ) async {
    validateSessionAction('workspace.rename', {
      'workspace': workspace.id,
      'title': title,
    });
    _verifyWorkspace(origin, workspace);
    _workspaceLabels[workspace.id] = title;
  }

  @override
  Future<void> closeWorkspace(
    SessionOrigin origin,
    SessionWorkspace workspace,
  ) async {
    _verifyWorkspace(origin, workspace);
    _closedWorkspaces.add(workspace.id);
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

  final _chatSessions = <String, String>{};
  final _chatMessages = <String, List<ConversationMessage>>{};
  String _chatId(SessionInfo session) => _chatSessions.putIfAbsent(
    session.key.id,
    () =>
        '00000000-0000-4000-8000-${(_chatSessions.length + 1).toString().padLeft(12, '0')}',
  );
  String _messageId(int index) =>
      '00000000-0000-4000-9000-${index.toString().padLeft(12, '0')}';
  List<ConversationMessage> _conversation(SessionInfo session) =>
      _chatMessages.putIfAbsent(
        session.key.id,
        () => List.generate(
          74,
          (i) => ConversationMessage(
            id: _messageId(i + 1),
            role: i.isEven ? 'user' : 'assistant',
            text: i == 73
                ? '## Native conversation preview\n\nThis is a complete response from **Demo data**. You can select its text or copy the entire answer with one tap.\n\n```dart\nfinal view = "Chat";\n```\n\nScroll up to load earlier messages. Switch to Terminal whenever you need the original interface.'
                : i.isEven
                ? 'Review example ${i ~/ 2 + 1} for the mobile interface.'
                : 'The example looks good. Keep touch targets comfortable and preserve the reader’s position when new messages arrive.',
            tools: i == 73 ? const ['Read', 'Edit'] : const [],
          ),
        ),
      );

  @override
  Future<ConversationPage> readConversation(
    SessionInfo session, {
    String conversationSession = '',
    String before = '',
  }) async {
    if (_closed) throw ConnectionFailure('Demo closed.');
    final id = _chatId(session), messages = _conversation(session);
    if (conversationSession.isNotEmpty && conversationSession != id) {
      throw SessionUnavailable();
    }
    final stop = before.isEmpty
        ? messages.length
        : messages.indexWhere((m) => m.id == before);
    if (stop < 0) throw SessionUnavailable();
    final start = (stop - 60).clamp(0, stop);
    final rows = messages.sublist(start, stop);
    return ConversationPage(
      session: id,
      status: 'available',
      messages: rows,
      before: rows.isEmpty ? '' : rows.first.id,
      hasEarlier: start > 0,
      canSend: true,
    );
  }

  @override
  Future<void> sendConversation(
    SessionInfo session,
    String conversationSession,
    String text,
  ) async {
    validateConversationPayload('chat.send', {
      'session': conversationSession,
      'text': text,
    });
    if (conversationSession != _chatId(session)) throw SessionUnavailable();
    await sendText(session, text);
    final messages = _conversation(session);
    messages.add(
      ConversationMessage(
        id: _messageId(messages.length + 1),
        role: 'user',
        text: text,
      ),
    );
    messages.add(
      ConversationMessage(
        id: _messageId(messages.length + 1),
        role: 'assistant',
        text: 'Received locally in Demo. This preview does not run an agent or execute commands.',
      ),
    );
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
    _browser.close();
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
