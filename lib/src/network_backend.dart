import 'dart:convert';

import 'backend.dart';
import 'image_attachments.dart';
import 'image_transfer_backend.dart';
import 'bridge_protocol.dart';
import 'models.dart';
import 'network_models.dart';
import 'persistent_bridge.dart';
import 'protocol.dart';

abstract interface class NetworkCatalogBackend {
  Stream<NetworkUpdate> discover({
    required int epoch,
    required Set<String> priorityMachines,
  });
}

class _ComputerCatalog {
  _ComputerCatalog(this.info, this.sessions);
  ComputerInfo info;
  List<SessionInfo> sessions;
}

class NetworkHerdrBackend
    implements
        SessionBackend,
        TerminalInputBackend,
        TerminalViewportBackend,
        TerminalScrollBackend,
        NetworkCatalogBackend,
        SessionManagementBackend,
        ImageAttachmentBackend {
  NetworkHerdrBackend(this.profile, PersistentBridge bridge, {this.onClose})
    : _provider = (() async => bridge),
      _legacy = null;
  NetworkHerdrBackend._(this.profile, this._provider, this._legacy)
    : onClose = _legacy!.close;
  factory NetworkHerdrBackend.remote(
    ConnectionProfile profile,
    CredentialVault vault,
  ) {
    final remote = RemoteHerdrBackend(profile, vault);
    return NetworkHerdrBackend._(profile, remote.persistentBridge, remote);
  }
  factory NetworkHerdrBackend.local(ConnectionProfile profile) {
    final helper = HelperHerdrBackend(profile);
    return NetworkHerdrBackend(
      profile,
      helper.persistentBridge,
      onClose: helper.close,
    );
  }
  final ConnectionProfile profile;
  final Future<PersistentBridge?> Function() _provider;
  final SessionBackend? _legacy;
  final Future<void> Function()? onClose;
  PersistentBridge? _bridge;
  final _nodes = <String, _ComputerCatalog>{};
  int _epoch = 0;
  bool _closed = false;
  int _managementEpoch = 0;
  @override
  void cancelPendingSessionActions() {
    _managementEpoch++;
  }

  int _imageEpoch = 0;
  ImageTransferClient? _images;
  @override
  bool get imageAttachmentsEnabled =>
      !_closed &&
      _bridge != null &&
      (_legacy is! RemoteHerdrBackend || _legacy.ordinaryImageTransfers);
  @override
  void cancelPendingImageTransfers() {
    _imageEpoch++;
    _images?.cancelPending();
  }

  @override
  Future<String> uploadImage(
    SessionInfo session,
    PreparedImage image, {
    required bool Function() cancelled,
    required void Function(int, int) onProgress,
  }) async {
    final current = _current(session, input: true), epoch = _imageEpoch;
    if (!imageAttachmentsEnabled ||
        !current.imageTransferEnabled ||
        current.origin == null) {
      throw SessionUnavailable(
        'Image attachments are unavailable on this connection.',
      );
    }
    bool stopped() {
      if (cancelled() || _imageEpoch != epoch || _closed) return true;
      try {
        return !_current(session, input: true).imageTransferEnabled;
      } catch (_) {
        return true;
      }
    }

    return (_images ??= ImageTransferClient(_bridge!)).upload(
      current.origin!.route(current.key.terminal, current.paneId),
      image,
      cancelled: stopped,
      onProgress: onProgress,
    );
  }

  @override
  String get sourceId => profile.id;
  NetworkUpdate _snapshot(int epoch, bool complete) => NetworkUpdate(
    epoch: epoch,
    complete: complete,
    computers: List.unmodifiable(_nodes.values.map((n) => n.info)),
    sessions: List.unmodifiable(_nodes.values.expand((n) => n.sessions)),
  );
  @override
  Stream<NetworkUpdate> discover({
    required int epoch,
    required Set<String> priorityMachines,
  }) async* {
    if (_closed) throw ConnectionFailure('Connection closed.');
    if (epoch <= _epoch) throw const FormatException('Obsolete discovery.');
    _epoch = epoch;
    final bridge = await _provider();
    if (_closed || epoch != _epoch) return;
    _bridge = bridge;
    if (bridge == null) {
      final rows = await _legacy!.listSessions();
      if (_closed || epoch != _epoch) return;
      final origin = SessionOrigin(
        profile: profile.id,
        machineId: 'gateway',
        machineLabel: displayText(profile.label),
        herdrSession: 'default',
        targetHash: _gatewayTarget,
        generation: rows.isEmpty ? '' : rows.first.key.server,
      );
      final sessions = rows.map((s) => s.withOrigin(origin)).toList();
      _nodes[origin.computerId] = _ComputerCatalog(
        ComputerInfo(
          origin: origin,
          state: ComputerState.live,
          message: 'Saved computers are unavailable with this connection.',
        ),
        sessions,
      );
      yield _snapshot(epoch, true);
      return;
    }
    final seen = <String>{};
    var listFailed = false;
    await for (final event in bridge.discover(epoch, priorityMachines)) {
      if (_closed || epoch != _epoch) return;
      if (event['event'] == 'network_error') {
        listFailed = true;
        continue;
      }
      if (event['event'] != 'computer') continue;
      final row = event['value'];
      if (row is! Map ||
          row['machine'] is! String ||
          row['session'] is! String ||
          row['targetHash'] is! String) {
        throw const FormatException('Invalid computer list.');
      }
      final machine = row['machine'] as String,
          session = row['session'] as String,
          target = row['targetHash'] as String;
      if (!RegExp(r'^(gateway|[0-9a-f]{32})$').hasMatch(machine) ||
          !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(session) ||
          session == '.' ||
          session == '..' ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(target)) {
        throw const FormatException('Invalid computer origin.');
      }
      final origin = SessionOrigin(
        profile: profile.id,
        machineId: machine,
        machineLabel: machine == 'gateway'
            ? displayText(profile.label)
            : displayText(row['label']),
        herdrSession: session,
        targetHash: target,
        generation: row['generation'] is String
            ? row['generation'] as String
            : '',
      );
      final id = origin.computerId;
      seen.add(id);
      final old = _nodes[id];
      final state = ComputerState.values
          .where((s) => s.name == row['state'])
          .firstOrNull;
      if (state == null) throw const FormatException('Invalid computer state.');
      if (state == ComputerState.connecting &&
          old != null &&
          (old.info.state == ComputerState.live ||
              old.info.state == ComputerState.attention ||
              old.info.state == ComputerState.offline) &&
          old.info.origin.targetHash == target) {
        // A refresh has no new result yet. Keep confirmed status and live views.
        yield _snapshot(epoch, false);
        continue;
      }
      var info = ComputerInfo(
        origin: origin,
        state: state,
        message: _nodeMessage(row['code']),
      );
      var sessions = (old?.sessions ?? <SessionInfo>[])
          .map((s) => s.unavailable())
          .toList();
      if (state == ComputerState.live) {
        try {
          sessions = parseOriginCatalog(jsonEncode(row['catalog']), origin);
          final catalog = row['catalog'] as Map;
          info = ComputerInfo(
            origin: origin,
            state: state,
            managementEnabled:
                catalog['sessionManagementEnabled'] == true &&
                catalog['inputEnabled'] == true,
            workspaces: parseSessionWorkspaces(catalog['workspaces']),
          );
        } catch (_) {
          info = ComputerInfo(
            origin: origin,
            state: ComputerState.attention,
            message: 'This computer returned an incompatible session list.',
          );
        }
      }
      _nodes[id] = _ComputerCatalog(info, sessions);
      yield _snapshot(epoch, false);
    }
    if (_closed || epoch != _epoch) return;
    if (!listFailed) _nodes.removeWhere((id, _) => !seen.contains(id));
    yield _snapshot(epoch, true);
  }

  static const _gatewayTarget =
      '4ea5ee68fea05586106890ded5733820bb77d919cda27bc4b8139b7cd33b8889';
  String _nodeMessage(Object? code) => switch (code) {
    'auth_required' => 'Check SSH access from the connected computer.',
    'host_key' =>
      'Verify this computer’s SSH identity on the connected computer.',
    'setup_required' || 'unsupported' =>
      'This computer needs Python 3 and a compatible running Herdr.',
    'route_changed' => 'This computer changed in Herdr. Refresh its sessions.',
    'busy' => 'Live sessions are using the available connections.',
    'timeout' || 'offline' => 'This computer could not be reached.',
    _ => '',
  };
  @override
  Future<List<SessionInfo>> listSessions() async {
    NetworkUpdate? last;
    await for (final update in discover(
      epoch: _epoch + 1,
      priorityMachines: {},
    )) {
      last = update;
    }
    return last?.sessions ?? [];
  }

  SessionInfo _current(SessionInfo session, {bool input = false}) {
    if (_closed ||
        session.key.profile != profile.id ||
        !session.available ||
        (input && !session.inputEnabled)) {
      throw SessionUnavailable();
    }
    final current = _nodes.values
        .expand((n) => n.sessions)
        .where((s) => s.key == session.key)
        .firstOrNull;
    if (current == null ||
        !current.available ||
        current.paneId != session.paneId ||
        current.origin?.targetHash != session.origin?.targetHash ||
        (input && !current.inputEnabled)) {
      throw SessionUnavailable();
    }
    return current;
  }

  @override
  List<ComputerInfo> get sessionComputers =>
      List.unmodifiable(_nodes.values.map((n) => n.info));

  ComputerInfo _managementComputer(SessionOrigin origin) {
    final current = _nodes[origin.computerId]?.info;
    if (_closed ||
        !origin.valid ||
        origin.profile != profile.id ||
        current == null ||
        current.state != ComputerState.live ||
        !current.managementEnabled ||
        !sameSessionOrigin(current.origin, origin) ||
        _bridge == null) {
      throw SessionUnavailable(
        'This computer is unavailable or does not support session actions.',
      );
    }
    return current;
  }

  bool _actionCancelled(SessionOrigin origin) {
    try {
      _managementComputer(origin);
      return false;
    } catch (_) {
      return true;
    }
  }

  Future<Map<String, dynamic>> _mutate(
    String op,
    SessionOrigin origin,
    Map<String, dynamic> route,
    Map<String, dynamic> payload,
  ) async {
    validateSessionAction(op, payload);
    _managementComputer(origin);
    final epoch = _managementEpoch;
    try {
      return await _bridge!.request(
        BridgeLane.input,
        op,
        payload,
        route: route,
        timeout: const Duration(seconds: 30),
        cancelled: () => epoch != _managementEpoch || _actionCancelled(origin),
      );
    } on DeliveryUncertain {
      throw const SessionActionUncertain();
    }
  }

  @override
  Future<void> renameSession(SessionInfo session, String title) async {
    validateSessionAction('rename', {'title': title});
    final current = _current(session, input: true), origin = session.origin;
    if (origin == null) throw SessionUnavailable();
    await _mutate(
      'rename',
      origin,
      origin.route(current.key.terminal, current.paneId),
      {'title': title},
    );
  }

  @override
  Future<void> closeSession(SessionInfo session) async {
    final current = _current(session, input: true), origin = session.origin;
    if (origin == null) throw SessionUnavailable();
    await _mutate(
      'close',
      origin,
      origin.route(current.key.terminal, current.paneId),
      {},
    );
  }

  @override
  Future<SessionInfo> createSession(
    SessionOrigin origin,
    SessionWorkspace workspace, {
    String title = '',
    String cwd = '',
  }) async {
    final payload = {'workspace': workspace.id, 'title': title, 'cwd': cwd};
    validateSessionAction('create', payload);
    final computer = _managementComputer(origin);
    if (!computer.workspaces.any((w) => w.id == workspace.id)) {
      throw SessionUnavailable('This workspace is no longer available.');
    }
    final result = await _mutate(
      'create',
      origin,
      origin.computerRoute,
      payload,
    );
    try {
      final created = result['created'];
      if (created is! Map ||
          created['workspace'] != workspace.id ||
          created['terminal'] is! String ||
          created['pane'] is! String) {
        throw const FormatException();
      }
      final sessions = await listSessions();
      _managementComputer(origin);
      return sessions.singleWhere(
        (s) =>
            s.available &&
            s.origin != null &&
            sameSessionOrigin(s.origin!, origin) &&
            s.key.terminal == created['terminal'] &&
            s.paneId == created['pane'] &&
            s.workspaceId == workspace.id,
      );
    } catch (_) {
      throw const SessionActionUncertain();
    }
  }

  @override
  Future<SessionInfo> createWorkspace(
    SessionOrigin origin, {
    required String title,
    String cwd = '',
  }) async {
    final result = await _mutate(
      'workspace.create',
      origin,
      origin.computerRoute,
      {'title': title, 'cwd': cwd},
    );
    try {
      final created = result['created'];
      if (created is! Map ||
          created['workspace'] is! String ||
          !terminalIdPattern.hasMatch(created['workspace'] as String) ||
          created['terminal'] is! String ||
          created['pane'] is! String) {
        throw const FormatException();
      }
      final sessions = await listSessions();
      final computer = _managementComputer(origin);
      if (!computer.workspaces.any((w) => w.id == created['workspace'])) {
        throw const FormatException();
      }
      return sessions.singleWhere(
        (s) =>
            s.available &&
            s.origin != null &&
            sameSessionOrigin(s.origin!, origin) &&
            s.key.terminal == created['terminal'] &&
            s.paneId == created['pane'] &&
            s.workspaceId == created['workspace'],
      );
    } catch (_) {
      throw const SessionActionUncertain();
    }
  }

  @override
  Future<void> sendText(SessionInfo session, String text) async {
    final current = _current(session, input: true);
    final bridge = _bridge;
    if (bridge == null) {
      await _legacy!.sendText(current, text);
      return;
    }
    await bridge.request(
      BridgeLane.input,
      'send',
      {'text': text},
      route: current.origin!.route(current.key.terminal, current.paneId),
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Future<void> sendTerminalInput(
    SessionInfo session,
    TerminalInput input,
  ) async {
    final current = _current(session, input: true);
    if (!current.terminalInputEnabled) throw SessionUnavailable();
    final bridge = _bridge;
    final cell = input.clickCell;
    if (cell != null) {
      if (bridge == null || !current.terminalViewportEnabled) {
        throw SessionUnavailable();
      }
      await bridge.click(
        current.origin!.route(current.key.terminal, current.paneId),
        cell.column,
        cell.row,
      );
      return;
    }
    if (bridge == null) {
      await (_legacy as TerminalInputBackend).sendTerminalInput(current, input);
      return;
    }
    await bridge.request(
      BridgeLane.input,
      'input',
      input.toJson(),
      route: current.origin!.route(current.key.terminal, current.paneId),
      timeout: const Duration(seconds: 30),
    );
  }

  @override
  Stream<ObserveEvent> observe(SessionInfo session) {
    final current = _current(session), bridge = _bridge;
    if (bridge == null) return _legacy!.observe(current);
    return bridge.observe(
      current.origin!.route(current.key.terminal, current.paneId),
    );
  }

  @override
  Stream<ObserveEvent> observeViewport(
    SessionInfo session,
    int cols,
    int rows,
  ) {
    final current = _current(session), bridge = _bridge;
    if (!current.terminalViewportEnabled) throw SessionUnavailable();
    if (bridge == null) {
      return (_legacy as TerminalViewportBackend).observeViewport(
        current,
        cols,
        rows,
      );
    }
    return bridge.observe(
      current.origin!.route(current.key.terminal, current.paneId),
      cols: cols,
      rows: rows,
    );
  }

  @override
  Future<void> resizeViewport(SessionInfo session, int cols, int rows) async {
    final current = _current(session), bridge = _bridge;
    if (bridge == null) {
      await (_legacy as TerminalViewportBackend).resizeViewport(
        current,
        cols,
        rows,
      );
      return;
    }
    await bridge.resize(
      current.origin!.route(current.key.terminal, current.paneId),
      cols,
      rows,
    );
  }

  @override
  bool get terminalScrollEnabled => _bridge != null && !_closed;

  @override
  Future<void> scrollTerminal(SessionInfo session, int lines) async {
    final current = _current(session), bridge = _bridge;
    if (!current.terminalViewportEnabled || bridge == null) {
      throw SessionUnavailable(
        'Terminal scrolling is unavailable with this connection.',
      );
    }
    await bridge.scroll(
      current.origin!.route(current.key.terminal, current.paneId),
      lines,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    cancelPendingImageTransfers();
    _closed = true;
    await _images?.drainCancelled();
    await _bridge?.close();
    await onClose?.call();
  }
}
