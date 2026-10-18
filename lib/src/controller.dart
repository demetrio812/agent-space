import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'image_attachments.dart';
import 'models.dart';
import 'protocol.dart';
import 'storage.dart';
import 'network_backend.dart';
import 'network_models.dart';

enum ConnectionState { connecting, live, stale, attention, demo }

enum TerminalState { queued, connecting, live, stale, attention, closed }

class TerminalEntry {
  final screen = TerminalScreen();
  TerminalState state = TerminalState.queued;
  String message = 'Waiting for a live preview';
  StreamSubscription<ObserveEvent>? subscription;
  SessionInfo? boundSession;
  Timer? retry, startTimer;
  int attempts = 0, generation = 0;
  int? viewportCols, viewportRows;
  bool viewportControl = false;
  Timer? viewportTimer;
  DateTime lastUsed = DateTime.now();
}

class SendState {
  bool sending = false, uncertain = false;
  bool terminalSending = false;
  String? message;
}

class _QueuedTerminalInput {
  _QueuedTerminalInput(this.input, {this.receipt, this.attachment});
  TerminalInput input;
  final Completer<void>? receipt;
  final ImageDropState? attachment;
  bool get cancelled => attachment?.cancelled == true;
  void succeed() {
    if (receipt?.isCompleted == false) receipt!.complete();
  }

  void fail(Object error) {
    if (receipt?.isCompleted == false) receipt!.completeError(error);
  }
}

class _TerminalInputQueue {
  _TerminalInputQueue(
    this.session,
    this.layout,
    this.backend,
    this.generation,
    this.state,
  );
  final SessionInfo session;
  final WorkspaceLayout layout;
  final TerminalInputBackend backend;
  final int generation;
  final SendState state;
  final settled = Completer<void>();
  Object? failure;
  final pending = <_QueuedTerminalInput>[];
  void discardPending(Object error) {
    for (final input in pending) {
      input.fail(error);
    }
    pending.clear();
    bytes = 0;
  }

  Timer? timer;
  bool running = false, cancelled = false;
  int bytes = 0;
}

class AppController extends ChangeNotifier {
  AppController({
    required this.snapshot,
    required this.store,
    required this.backendFactory,
  });
  final AppSnapshot snapshot;
  final LayoutStore store;
  final SessionBackend Function(String) backendFactory;
  WorkspaceLayout get layout => snapshot.layoutFor(snapshot.activeSource);
  String get source => snapshot.activeSource;
  List<SessionInfo> sessions = [];
  List<ComputerInfo> computers = [];
  StreamSubscription<NetworkUpdate>? _networkSubscription;
  Completer<void>? _networkFirst;
  int _discoveryEpoch = 0;
  ConnectionState connectionState = ConnectionState.connecting;
  String connectionMessage = 'Connecting…';
  String search = '';
  final terminals = <String, TerminalEntry>{};
  final sendStates = <String, SendState>{};
  final imageDrops = <String, ImageDropState>{};
  final sessionActionStates = <String, SessionActionState>{};
  final externalTargets = <String, Set<String>>{};
  final _previewTargets = <String>[];
  final _terminalInput = <String, _TerminalInputQueue>{};
  final _terminalDispatches = <String, _TerminalInputQueue>{};
  final _composedDispatches = <String, SendState>{};
  SessionBackend? _backend;
  Timer? _poll, _saveTimer, _renderTimer;
  int _generation = 0;
  bool _polling = true, _active = true, _disposed = false;
  int? _refreshGeneration;
  Future<void>? _shutdownFuture;
  Timer? _backgroundTimer;
  Future<void>? _suspending;
  bool get isActive => _active;
  SessionInfo? get selectedSession =>
      layout.selectedId == null ? null : sessionById(layout.selectedId!);
  SessionInfo? sessionById(String id) =>
      sessions.where((s) => s.key.id == id).firstOrNull ??
      layout.favourites[id]?.unavailable() ??
      layout.retained[id]?.unavailable();
  List<SessionInfo> sessionsForFilter(String filter) {
    if (filter == 'recent') {
      // Resolve against the current catalog, not retained metadata: closed
      // sessions can remain in favourites but must disappear from Recent.
      final current = {for (final session in sessions) session.key.id: session};
      return layout.recentSessions
          .map((id) => current[id])
          .whereType<SessionInfo>()
          .toList();
    }
    Iterable<SessionInfo> rows;
    if (filter == 'favourites') {
      rows = layout.favourites.keys.map(sessionById).whereType<SessionInfo>();
    } else if (filter.startsWith('group:')) {
      final group = layout.groups
          .where((g) => g.id == filter.substring(6))
          .firstOrNull;
      rows = (group?.sessions ?? <String>[])
          .map(sessionById)
          .whereType<SessionInfo>();
    } else {
      rows = sessions.isEmpty
          ? {
              ...layout.retained,
              ...layout.favourites,
            }.values.map((s) => s.unavailable())
          : sessions;
      if (filter.startsWith('computer:')) {
        rows = rows.where((s) => s.computerId == filter.substring(9));
      } else if (filter != 'all') {
        rows = rows.where((s) => s.workspaceFilterId == filter);
      }
    }
    final result = rows.toList();
    if (!filter.startsWith('group:')) {
      final order = filter == 'favourites' && layout.favouriteOrder.isNotEmpty
          ? layout.favouriteOrder
          : layout.tabOrder;
      final ranks = <String, int>{
        for (var i = 0; i < order.length; i++) order[i]: i,
      };
      result.sort((a, b) {
        final rank = (ranks[a.key.id] ?? 999999).compareTo(
          ranks[b.key.id] ?? 999999,
        );
        return rank != 0
            ? rank
            : a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    }
    return result;
  }

  List<SessionInfo> get visibleSessions {
    final rows = sessionsForFilter(layout.filter)
        .where(
          (s) =>
              search.isEmpty ||
              '${s.title} ${s.project} ${s.agent} ${s.workspaceLabel} ${s.origin?.machineLabel ?? ''} ${s.origin?.herdrSession ?? ''}'
                  .toLowerCase()
                  .contains(search.toLowerCase()),
        )
        .toList();
    if (layout.filter == 'recent' || layout.gridSort == SessionSort.custom) {
      return rows;
    }
    int compareText(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    int recentRank(SessionInfo s) {
      final index = layout.recentSessions.indexOf(s.key.id);
      return index < 0 ? 999999 : index;
    }

    int statusRank(SessionInfo s) => !s.available
        ? 5
        : switch (s.status) {
            SessionStatus.needsInput => 0,
            SessionStatus.working => 1,
            SessionStatus.done => 2,
            SessionStatus.idle => 3,
            SessionStatus.unknown => 4,
          };
    rows.sort((a, b) {
      final primary = switch (layout.gridSort) {
        SessionSort.custom => 0,
        SessionSort.name => compareText(a.title, b.title),
        SessionSort.recent => recentRank(a).compareTo(recentRank(b)),
        SessionSort.status => statusRank(a).compareTo(statusRank(b)),
        SessionSort.computer => compareText(
          computerLabel(a.computerId, origin: a.origin),
          computerLabel(b.computerId, origin: b.origin),
        ),
        SessionSort.workspace => compareText(
          a.workspaceLabel,
          b.workspaceLabel,
        ),
      };
      if (primary != 0) return primary;
      final title = compareText(a.title, b.title);
      return title != 0 ? title : a.key.id.compareTo(b.key.id);
    });
    return rows;
  }

  void setGridSort(SessionSort value) {
    layout.gridSort = value;
    _scheduleSave();
    notifyListeners();
  }

  Map<String, String> get workspaces {
    final result = <String, String>{};
    final origins = <String, Set<String>>{};
    for (final session in sessions) {
      (origins[session.workspaceLabel] ??= <String>{}).add(session.computerId);
    }
    for (final session in sessions) {
      if (session.workspaceId.isNotEmpty) {
        final colliding = origins[session.workspaceLabel]!.length > 1;
        result[session.workspaceFilterId] = colliding
            ? '${session.workspaceLabel} · ${computerLabel(session.computerId, origin: session.origin)}'
            : session.workspaceLabel;
      }
    }
    return result;
  }

  /// A workspace belongs to one computer, so navigating into it keeps
  /// that computer's workspace list visible in the sidebar.
  String? get selectedComputerId {
    final filter = layout.filter;
    if (filter.startsWith('computer:')) return filter.substring(9);
    if (filter == 'all' ||
        filter == 'recent' ||
        filter == 'favourites' ||
        filter.startsWith('group:')) {
      return null;
    }
    return [...sessions, ...layout.retained.values, ...layout.favourites.values]
        .where((session) => session.workspaceFilterId == filter)
        .firstOrNull
        ?.computerId;
  }

  Map<String, String> get sidebarWorkspaces {
    final computerId = selectedComputerId;
    final result = workspaces;
    if (computerId == null) return result;
    final workspaceIds = sessions
        .where((session) => session.computerId == computerId)
        .map((session) => session.workspaceFilterId)
        .toSet();
    result.removeWhere((id, _) => !workspaceIds.contains(id));
    return result;
  }

  String computerLabel(String id, {SessionOrigin? origin}) {
    final current =
        computers.where((c) => c.origin.computerId == id).firstOrNull?.origin ??
        origin;
    if (current == null) return 'Connected computer';
    final label = current.machineLabel.isEmpty
        ? 'Computer'
        : current.machineLabel;
    final duplicates = computers
        .where(
          (c) => c.origin.machineLabel.toLowerCase() == label.toLowerCase(),
        )
        .toList();
    var result = label;
    if (current.herdrSession != 'default' || duplicates.length > 1) {
      result += ' · ${current.herdrSession}';
    }
    if (duplicates
            .where((c) => c.origin.herdrSession == current.herdrSession)
            .length >
        1) {
      result +=
          ' · ${current.machineId == 'gateway' ? 'connected' : current.machineId.substring(0, 6)}';
    }
    return result;
  }

  String get filterLabel {
    final filter = layout.filter;
    if (filter == 'all') return 'All sessions';
    if (filter == 'recent') return 'Recent';
    if (filter == 'favourites') return 'Favourites';
    if (filter.startsWith('computer:')) {
      return computerLabel(filter.substring(9));
    }
    if (filter.startsWith('group:')) {
      return layout.groups
              .where((g) => 'group:${g.id}' == filter)
              .firstOrNull
              ?.name ??
          'Group';
    }
    return workspaces[filter] ?? 'Workspace';
  }

  Future<void> start({bool polling = true}) async {
    _polling = polling;
    await switchSource(source);
  }

  void _cancelSessionActions() {
    final backend = _backend;
    if (backend is SessionManagementBackend) {
      (backend as SessionManagementBackend).cancelPendingSessionActions();
    }
  }

  Future<void> switchSource(String target) async {
    if (_disposed) return;
    _cancelSessionActions();
    _cancelTerminalInput();
    final generation = ++_generation;
    _cancelDiscovery();
    _poll?.cancel();
    _saveTimer?.cancel();
    _renderTimer?.cancel();
    final old = _backend;
    _backend = null;
    final stopping = terminals.values.map(_stopEntry).toList();
    terminals.clear();
    sendStates.clear();
    sessions = [];
    computers = [];
    _previewTargets.clear();
    externalTargets.clear();
    search = '';
    snapshot.activeSource = target;
    for (final id in layout.uncertainDeliveries) {
      sendStates[id] = SendState()
        ..uncertain = true
        ..message =
            'Delivery is uncertain. Check the terminal before sending again.';
    }
    connectionState = ConnectionState.connecting;
    connectionMessage = 'Connecting…';
    notifyListeners();
    await Future.wait(stopping);
    await old?.close();
    if (generation != _generation || _disposed) return;
    try {
      _backend = backendFactory(target);
    } catch (_) {
      connectionState = ConnectionState.attention;
      connectionMessage =
          'This connection is unavailable. Choose another source in Settings.';
      notifyListeners();
      return;
    }
    await refresh();
    if (generation == _generation &&
        !_disposed &&
        _active &&
        _polling &&
        connectionState != ConnectionState.attention) {
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(refresh()),
      );
    }
    _scheduleSave();
  }

  Future<void> refresh() async {
    final generation = _generation;
    if (_disposed ||
        !_active ||
        _backend == null ||
        _refreshGeneration == generation) {
      return;
    }
    _refreshGeneration = generation;
    final backend = _backend;
    if (backend is NetworkCatalogBackend) {
      await _refreshNetwork(backend as NetworkCatalogBackend, generation);
      return;
    }
    try {
      final result = await _backend!.listSessions();
      if (generation != _generation || _disposed) return;
      sessions = result;
      if (backend is SessionManagementBackend) {
        computers = (backend as SessionManagementBackend).sessionComputers;
      }
      connectionState = source == 'demo'
          ? ConnectionState.demo
          : ConnectionState.live;
      connectionMessage = source == 'demo'
          ? 'Demo · synthetic sessions'
          : 'Connected';
      final live = {for (final s in sessions) s.key.id: s};
      for (final id in layout.favourites.keys.toList()) {
        layout.favourites[id] =
            live[id] ?? layout.favourites[id]!.unavailable();
      }
      for (final id in layout.retained.keys.toList()) {
        layout.retained[id] = live[id] ?? layout.retained[id]!.unavailable();
      }
      final selected = layout.selectedId;
      if (selected != null && live[selected] != null) {
        layout.retained[selected] = live[selected]!;
      }
      _syncStreams();
      _scheduleSave();
    } catch (error) {
      if (generation != _generation || _disposed) return;
      final permanent =
          error is FormatException ||
          error is ConnectionFailure && error.permanent;
      connectionState = permanent
          ? ConnectionState.attention
          : ConnectionState.stale;
      connectionMessage = _message(error);
      if (permanent) _poll?.cancel();
    } finally {
      if (_refreshGeneration == generation) _refreshGeneration = null;
      if (generation == _generation && !_disposed) notifyListeners();
    }
  }

  Future<void> _cancelDiscovery() {
    if (_networkSubscription != null ||
        _networkFirst != null ||
        _discoveryEpoch != 0) {
      _discoveryEpoch++;
    }
    final subscription = _networkSubscription;
    _networkSubscription = null;
    final stopping = subscription?.cancel() ?? Future<void>.value();
    if (_networkFirst?.isCompleted == false) _networkFirst!.complete();
    _networkFirst = null;
    _refreshGeneration = null;
    return stopping;
  }

  Future<void> _refreshNetwork(
    NetworkCatalogBackend backend,
    int generation,
  ) async {
    final epoch = ++_discoveryEpoch, first = Completer<void>();
    _networkFirst = first;
    bool current() =>
        generation == _generation &&
        epoch == _discoveryEpoch &&
        !_disposed &&
        _active;
    final priority = <String>{
      if (selectedSession?.origin?.isGateway == false)
        selectedSession!.origin!.machineId,
      ..._previewTargets
          .map(sessionById)
          .whereType<SessionInfo>()
          .map((s) => s.origin)
          .whereType<SessionOrigin>()
          .where((o) => !o.isGateway)
          .map((o) => o.machineId),
    }.take(16).toSet();
    void failed(Object error) {
      if (!current()) return;
      // Discovery's own failure cannot revoke an independently live terminal.
      final live = terminals.values.any((e) => e.state == TerminalState.live);
      if (live && error is! ConnectionFailure ||
          live && error is ConnectionFailure && !error.permanent) {
        connectionState = ConnectionState.live;
        connectionMessage = 'Connected · Session refresh paused';
      } else {
        connectionState = error is ConnectionFailure && error.permanent
            ? ConnectionState.attention
            : ConnectionState.stale;
        connectionMessage = _message(error);
      }
      if (!first.isCompleted) first.complete();
      notifyListeners();
    }

    _networkSubscription = backend
        .discover(epoch: epoch, priorityMachines: priority)
        .listen(
          (update) {
            if (!current() || update.epoch != epoch) return;
            applyNetworkUpdate(update, generation);
            if (!first.isCompleted) first.complete();
          },
          onError: failed,
          onDone: () {
            if (!current()) return;
            _networkSubscription = null;
            _refreshGeneration = null;
            if (!first.isCompleted) {
              failed(ConnectionFailure('No computer catalog was received.'));
            }
            if (identical(_networkFirst, first)) _networkFirst = null;
          },
        );
    await first.future;
  }

  void applyNetworkUpdate(NetworkUpdate update, int sourceGeneration) {
    if (_disposed ||
        !_active ||
        sourceGeneration != _generation ||
        update.epoch != _discoveryEpoch) {
      return;
    }
    computers = update.computers;
    final old = {for (final s in sessions) s.key.id: s};
    sessions = update.sessions;
    final live = {for (final s in sessions) s.key.id: s};
    for (final id in _terminalInput.keys.toList()) {
      final queue = _terminalInput[id]!;
      final now = live[id];
      if (now == null ||
          !now.available ||
          now.paneId != queue.session.paneId ||
          now.origin?.targetHash != queue.session.origin?.targetHash) {
        queue.cancelled = true;
        queue.timer?.cancel();
        queue.discardPending(SessionUnavailable());
        _terminalInput.remove(id);
        if (!queue.running && !queue.settled.isCompleted) {
          queue.settled.complete();
        }
      }
    }
    for (final row in imageDrops.entries.toList()) {
      if (row.value.busy && !_imageCurrent(row.key, row.value)) {
        cancelImageDrop(row.key);
      }
    }
    for (final row in terminals.entries) {
      final before = old[row.key], now = live[row.key];
      if (before != null &&
          now != null &&
          (before.paneId != now.paneId ||
              before.origin?.targetHash != now.origin?.targetHash)) {
        unawaited(_stopEntry(row.value));
        row.value.state = TerminalState.queued;
      }
    }
    for (final id in layout.favourites.keys.toList()) {
      layout.favourites[id] = live[id] ?? layout.favourites[id]!.unavailable();
    }
    for (final id in layout.retained.keys.toList()) {
      layout.retained[id] = live[id] ?? layout.retained[id]!.unavailable();
    }
    final selected = layout.selectedId;
    if (selected != null && live[selected] != null) {
      layout.retained[selected] = live[selected]!;
    }
    final filter = layout.filter;
    if (filter != 'all' &&
        filter != 'recent' &&
        filter != 'favourites' &&
        !filter.startsWith('group:') &&
        !filter.startsWith('computer:') &&
        !filter.startsWith('workspace:')) {
      final gateway = sessions
          .where((s) => s.origin?.isGateway == true && s.workspaceId == filter)
          .firstOrNull;
      if (gateway != null) layout.filter = gateway.workspaceFilterId;
    }
    connectionState = ConnectionState.live;
    connectionMessage = 'Connected';
    _syncStreams();
    _scheduleSave();
    notifyListeners();
  }

  static String _message(Object error) => error is ConnectionFailure
      ? error.message
      : error is DeliveryUncertain
      ? error.message
      : error is FormatException
      ? error.message
      : 'Connection interrupted. Reconnect to try again.';
  void toggleFavourite(SessionInfo session) {
    final id = session.key.id;
    final order = sessionsForFilter('favourites').map((s) => s.key.id).toList();
    if (layout.favourites.containsKey(id)) {
      layout.favourites.remove(id);
      order.remove(id);
    } else if (layout.favourites.length < 256) {
      layout.favourites[id] = session;
      order.add(id);
    }
    layout.favouriteOrder
      ..clear()
      ..addAll(order);
    layout.gridSort = SessionSort.custom;
    _scheduleSave();
    notifyListeners();
  }

  bool isFavourite(String id) => layout.favourites.containsKey(id);
  void setFilter(String filter) {
    _cancelTerminalInput();
    layout.filter = filter;
    layout.selectedId = null;
    search = '';
    _previewTargets.clear();
    _syncStreams();
    _scheduleSave();
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  void select(String id) {
    final session = sessionById(id);
    if (session == null) return;
    if (layout.selectedId != id) _cancelTerminalInput();
    layout.selectedId = id;
    layout.recentSessions
      ..remove(id)
      ..insert(0, id);
    if (layout.recentSessions.length > 256) layout.recentSessions.removeLast();
    layout.retained[id] = session;
    _previewTargets.clear();
    _syncStreams();
    _scheduleSave();
    notifyListeners();
  }

  void overview() {
    _cancelTerminalInput();
    layout.selectedId = null;
    _syncStreams();
    _scheduleSave();
    notifyListeners();
  }

  void setPreviewTargets(List<String> ids) {
    final next = ids.take(48).toList();
    if (listEquals(next, _previewTargets)) return;
    _previewTargets
      ..clear()
      ..addAll(next);
    _syncStreams();
  }

  void watchExternal(String window, List<String> ids) {
    externalTargets[window] = ids.toSet();
    _syncStreams();
  }

  void unwatchExternal(String window) {
    externalTargets.remove(window);
    _syncStreams();
  }

  void _syncStreams() {
    if (_disposed) return;
    final requested = <String>{
      if (layout.selectedId != null) layout.selectedId!,
      ...externalTargets.values.expand((s) => s),
      ..._previewTargets,
    };
    final targets = _active
        ? requested
              .where((id) => sessionById(id)?.available == true)
              .take(16)
              .toSet()
        : <String>{};
    for (final row in terminals.entries.toList()) {
      if (row.value.viewportControl && row.key != layout.selectedId) {
        row.value.viewportControl = false;
        row.value.viewportCols = null;
        row.value.viewportRows = null;
        unawaited(_stopEntry(row.value));
      }
      if (!targets.contains(row.key)) {
        unawaited(_stopEntry(row.value));
        if (row.value.state == TerminalState.live ||
            row.value.state == TerminalState.connecting) {
          row.value.state = TerminalState.stale;
          row.value.message = 'Preview paused';
        }
      }
    }
    var startIndex = 0;
    for (final id in targets) {
      final entry = terminals.putIfAbsent(id, TerminalEntry.new)
        ..lastUsed = DateTime.now();
      if (id == layout.selectedId && entry.startTimer != null) {
        entry.startTimer!.cancel();
        entry.startTimer = null;
      }
      if (entry.subscription == null &&
          entry.retry == null &&
          entry.startTimer == null &&
          entry.state != TerminalState.closed &&
          entry.state != TerminalState.attention) {
        if (startIndex++ == 0) {
          _startStream(id, entry);
        } else {
          entry.startTimer = Timer(
            Duration(milliseconds: 120 * startIndex),
            () {
              entry.startTimer = null;
              if (!_disposed && _active && targets.contains(id)) {
                _startStream(id, entry);
              }
            },
          );
        }
      }
    }
    if (terminals.length > 48) {
      final inactive =
          terminals.entries.where((e) => !requested.contains(e.key)).toList()
            ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));
      for (final entry in inactive.take(terminals.length - 48)) {
        unawaited(_stopEntry(entry.value));
        terminals.remove(entry.key);
      }
    }
  }

  void _startStream(String id, TerminalEntry entry) {
    final session = sessionById(id);
    final backend = _backend;
    if (!_active ||
        _disposed ||
        session == null ||
        !session.available ||
        backend == null) {
      return;
    }
    final generation = _generation, entryGeneration = ++entry.generation;
    entry.boundSession = session;
    entry.state = TerminalState.connecting;
    entry.message = 'Connecting terminal…';
    entry.screen.beginStream();
    bool current() =>
        !_disposed &&
        generation == _generation &&
        entryGeneration == entry.generation;
    void failure(Object error) {
      if (!current()) return;
      final subscription = entry.subscription;
      entry.subscription = null;
      unawaited(subscription?.cancel());
      final permanent =
          error is FormatException && error is! FrameContinuityException ||
          error is ConnectionFailure && error.permanent;
      entry.state = permanent ? TerminalState.attention : TerminalState.stale;
      entry.message = _message(error);
      if (!permanent && _active) {
        entry.attempts++;
        final seconds = (2 << (entry.attempts - 1).clamp(0, 4)).clamp(2, 30);
        entry.retry = Timer(Duration(seconds: seconds), () {
          entry.retry = null;
          _syncStreams();
        });
      }
      _renderSoon();
    }

    final stream =
        entry.viewportControl &&
            id == layout.selectedId &&
            session.terminalViewportEnabled &&
            backend is TerminalViewportBackend
        ? (backend as TerminalViewportBackend).observeViewport(
            session,
            entry.viewportCols!,
            entry.viewportRows!,
          )
        : backend.observe(session);
    entry.subscription = stream.listen(
      (event) {
        if (!current()) return;
        if (event is TerminalClosed) {
          entry.state = TerminalState.closed;
          entry.message = displayText(event.reason);
          _renderSoon();
        } else if (event is TerminalFrame) {
          try {
            entry.screen.accept(event);
            entry.state = TerminalState.live;
            entry.message = 'Live';
            entry.attempts = 0;
            _renderSoon(immediate: event.full);
          } catch (error) {
            failure(error);
          }
        }
      },
      onError: (Object error) => failure(error),
      onDone: () {
        if (current() &&
            entry.state != TerminalState.closed &&
            entry.state != TerminalState.attention &&
            entry.retry == null) {
          failure(ConnectionFailure('Terminal stream disconnected.'));
        }
      },
    );
  }

  Future<void> _stopEntry(TerminalEntry entry) async {
    entry.generation++;
    entry.viewportTimer?.cancel();
    entry.viewportTimer = null;
    entry.retry?.cancel();
    entry.retry = null;
    entry.startTimer?.cancel();
    entry.startTimer = null;
    final subscription = entry.subscription;
    entry.subscription = null;
    await subscription?.cancel();
  }

  bool canResizeViewport(String id) =>
      !_disposed &&
      _active &&
      layout.selectedId == id &&
      _backend is TerminalViewportBackend &&
      sessionById(id)?.terminalViewportEnabled == true &&
      sessionById(id)?.available == true &&
      connectionState != ConnectionState.attention &&
      connectionState != ConnectionState.stale &&
      terminals[id]?.state != TerminalState.closed;

  bool canScrollTerminal(String id) =>
      canResizeViewport(id) &&
      _backend is TerminalScrollBackend &&
      (_backend as TerminalScrollBackend).terminalScrollEnabled &&
      terminals[id]?.viewportControl == true &&
      terminals[id]?.state == TerminalState.live;

  Future<void> scrollTerminal(String id, int lines) async {
    if (!canScrollTerminal(id) || lines == 0 || lines.abs() > 40) return;
    final entry = terminals[id]!, generation = _generation;
    try {
      await (_backend! as TerminalScrollBackend).scrollTerminal(
        sessionById(id)!,
        lines,
      );
    } catch (_) {
      if (!_disposed &&
          generation == _generation &&
          identical(terminals[id], entry)) {
        entry.message = 'Terminal scroll failed. Reconnect the terminal.';
        notifyListeners();
      }
    }
  }

  void updateViewport(String id, int cols, int rows) {
    if (!canResizeViewport(id) || !validViewport(cols, rows)) return;
    final entry = terminals[id];
    if (entry == null ||
        (entry.viewportCols == cols &&
            entry.viewportRows == rows &&
            (entry.viewportTimer != null ||
                entry.viewportControl && entry.subscription != null))) {
      return;
    }
    entry.viewportCols = cols;
    entry.viewportRows = rows;
    entry.viewportTimer?.cancel();
    final generation = _generation;
    entry.viewportTimer = Timer(const Duration(milliseconds: 120), () async {
      entry.viewportTimer = null;
      if (generation != _generation || !canResizeViewport(id)) return;
      try {
        if (!entry.viewportControl || entry.subscription == null) {
          final transition = entry.generation + 1;
          // Cancellation is initiated synchronously; a read-only observer's
          // teardown must not stall acquiring the selected viewport.
          unawaited(_stopEntry(entry));
          if (generation != _generation ||
              entry.generation != transition ||
              !canResizeViewport(id)) {
            return;
          }
          entry.viewportControl = true;
          _startStream(id, entry);
        } else {
          await (_backend! as TerminalViewportBackend).resizeViewport(
            sessionById(id)!,
            entry.viewportCols!,
            entry.viewportRows!,
          );
        }
      } catch (_) {
        if (generation == _generation &&
            layout.selectedId == id &&
            !_disposed) {
          entry.message = 'Terminal resize failed. Reconnect the terminal.';
          notifyListeners();
        }
      }
    });
  }

  Future<void> reconnectTerminal(String id) async {
    _cancelTerminalInput();
    final entry = terminals[id];
    if (entry != null) {
      await _stopEntry(entry);
      entry.state = TerminalState.queued;
      entry.attempts = 0;
    }
    _syncStreams();
    if (!_disposed) notifyListeners();
  }

  Future<void> reconnect() async {
    if (_disposed) return;
    _cancelSessionActions();
    _cancelTerminalInput();
    _cancelDiscovery();
    _generation++;
    for (final entry in terminals.values) {
      await _stopEntry(entry);
      if (entry.state != TerminalState.closed) {
        entry.state = TerminalState.queued;
      }
    }
    final old = _backend;
    _backend = backendFactory(source);
    await old?.close();
    connectionState = ConnectionState.connecting;
    notifyListeners();
    await refresh();
    if (_active && _polling && connectionState != ConnectionState.attention) {
      _poll?.cancel();
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(refresh()),
      );
    }
  }

  Future<void> _releaseBackgroundConnection() async {
    if (_backend is NetworkCatalogBackend) {
      connectionState = ConnectionState.stale;
      connectionMessage = 'Connection paused';
    }
    await _cancelDiscovery();
    await Future.wait(terminals.values.map(_stopEntry));
    if (_backend is NetworkCatalogBackend) {
      final old = _backend;
      _backend = null;
      await old?.close();
    }
  }

  Future<void> setActive(
    bool active, {
    Duration gracePeriod = const Duration(seconds: 20),
  }) async {
    if (_disposed || _active == active) return;
    _active = active;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    if (!active) {
      _cancelSessionActions();
      _cancelTerminalInput();
      _poll?.cancel();
      final discoveryStopping = _cancelDiscovery();
      // Brief app switches keep their transport and terminal subscriptions.
      // Input is disabled immediately, regardless of this grace period.
      if (gracePeriod == Duration.zero) {
        await (_suspending = _releaseBackgroundConnection());
      } else {
        _backgroundTimer = Timer(gracePeriod, () {
          _backgroundTimer = null;
          _suspending = _releaseBackgroundConnection();
          unawaited(_suspending!.catchError((Object _) {}));
        });
      }
      await discoveryStopping;
      await flush();
      return;
    }
    // A slow close must finish before its replacement is created.
    try {
      await _suspending;
    } catch (_) {
      // Refresh below reports the current connection state.
    }
    _suspending = null;
    if (_disposed || !_active) return;
    try {
      _backend ??= backendFactory(source);
    } catch (_) {
      connectionState = ConnectionState.attention;
      connectionMessage = 'This connection is unavailable. Reconnect or choose another source in Settings.';
      notifyListeners();
      return;
    }
    // Keep cached sessions, screens, search, drafts and selection visible.
    // switchSource would discard all of them even though the source is unchanged.
    await refresh();
    if (_disposed || !_active) return;
    _syncStreams();
    if (_polling && connectionState != ConnectionState.attention) {
      _poll?.cancel();
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(refresh()),
      );
    }
    notifyListeners();
  }

  void updateDraft(String id, String text) {
    if (SessionKey.decode(id) == null) return;
    if (text.isEmpty) {
      layout.drafts.remove(id);
    } else {
      layout.drafts[id] = text;
    }
    final session = sessionById(id);
    if (session != null) layout.retained[id] = session;
    _scheduleSave();
  }

  Future<void> sendDraft(String id) async {
    final state = sendStates.putIfAbsent(id, SendState.new);
    if (terminalInputPending(id) ||
        state.sending ||
        state.uncertain ||
        layout.uncertainDeliveries.contains(id) ||
        _disposed) {
      return;
    }
    final session = sessionById(id);
    final backend = _backend;
    final ownerLayout = layout;
    final text = ownerLayout.drafts[id] ?? '';
    final invalid = validateInput(text);
    if (invalid != null) {
      state.message = invalid;
      notifyListeners();
      return;
    }
    if (session == null ||
        !session.available ||
        !session.inputEnabled ||
        backend == null ||
        connectionState == ConnectionState.attention ||
        connectionState == ConnectionState.stale ||
        terminals[id]?.state == TerminalState.closed) {
      state.message = 'Input is unavailable for this session. Check the connection and pairing.';
      notifyListeners();
      return;
    }
    if (!_deliveryMarkerFits(ownerLayout, id)) {
      state.message =
          'Check previous unconfirmed deliveries before sending more input.';
      notifyListeners();
      return;
    }
    state.sending = true;
    _composedDispatches[id] = state;
    state.message = null;
    notifyListeners();
    var submitted = false;
    try {
      // Save a pending delivery marker before crossing the input boundary.
      // An interrupted app must require a user check before another send.
      ownerLayout.uncertainDeliveries.add(id);
      await store.save(snapshot);
      submitted = true;
      await backend.sendText(session, text);
      ownerLayout.uncertainDeliveries.remove(id);
      if (ownerLayout.drafts[id] == text) ownerLayout.drafts.remove(id);
      state.message = session.key.backend == 'demo'
          ? 'Sent to the demo session.'
          : 'Text + Enter sent.';
    } catch (error) {
      state.uncertain =
          error is DeliveryUncertain ||
          (submitted && error is! ConnectionFailure && error is! ArgumentError);
      if (state.uncertain) {
        ownerLayout.uncertainDeliveries.add(id);
      } else {
        ownerLayout.uncertainDeliveries.remove(id);
      }
      state.message = !submitted
          ? 'The message was not sent because the layout could not be saved.'
          : error is ArgumentError
          ? error.message?.toString()
          : _message(error);
    } finally {
      state.sending = false;
      if (identical(_composedDispatches[id], state)) {
        _composedDispatches.remove(id);
      }
      if (identical(ownerLayout, layout)) {
        final currentState = sendStates.putIfAbsent(id, SendState.new);
        currentState.uncertain = state.uncertain;
        currentState.message = state.message;
      }
      _scheduleSave();
      if (!_disposed) notifyListeners();
    }
  }

  bool terminalInputPending(String id) =>
      _terminalInput.containsKey(id) ||
      _terminalDispatches.containsKey(id) ||
      _composedDispatches.containsKey(id);

  bool _deliveryMarkerFits(WorkspaceLayout value, String id) =>
      value.uncertainDeliveries.contains(id) ||
      value.uncertainDeliveries.length < maxUncertainDeliveries;

  bool canSendTerminalInput(String id) {
    final session = sessionById(id), state = sendStates[id];
    return !_disposed &&
        _active &&
        layout.selectedId == id &&
        _backend is TerminalInputBackend &&
        !_composedDispatches.containsKey(id) &&
        (!_terminalDispatches.containsKey(id) ||
            identical(_terminalDispatches[id], _terminalInput[id])) &&
        session?.available == true &&
        session?.inputEnabled == true &&
        session?.terminalInputEnabled == true &&
        state?.sending != true &&
        state?.uncertain != true &&
        (!layout.uncertainDeliveries.contains(id) ||
            state?.terminalSending == true) &&
        connectionState != ConnectionState.stale &&
        connectionState != ConnectionState.attention &&
        terminals[id]?.state != TerminalState.closed;
  }

  void _cancelTerminalInput() {
    for (final row in imageDrops.entries.toList()) {
      if (row.value.busy) cancelImageDrop(row.key, force: true);
    }

    for (final queue in _terminalInput.values) {
      queue.cancelled = true;
      queue.timer?.cancel();
      queue.discardPending(SessionUnavailable());
      if (!queue.running && !queue.settled.isCompleted) {
        queue.settled.complete();
      }
    }
    _terminalInput.clear();
  }

  void sendTerminalInput(String id, TerminalInput input) {
    _enqueueTerminalInput(id, input);
  }

  _QueuedTerminalInput? _enqueueTerminalInput(
    String id,
    TerminalInput input, {
    Completer<void>? receipt,
    ImageDropState? attachment,
  }) {
    if (!canSendTerminalInput(id)) return null;
    final state = sendStates.putIfAbsent(id, SendState.new);
    final invalid = input.validationError;
    if (invalid != null) {
      state.message = invalid;
      notifyListeners();
      return null;
    }
    if (!_deliveryMarkerFits(layout, id)) {
      state.message =
          'Check previous unconfirmed deliveries before sending more input.';
      notifyListeners();
      return null;
    }
    final queue = _terminalInput.putIfAbsent(
      id,
      () => _TerminalInputQueue(
        sessionById(id)!,
        layout,
        _backend! as TerminalInputBackend,
        _generation,
        state,
      ),
    );
    final cost = input.estimatedBytes;
    if (queue.bytes + cost > 65536 || queue.pending.length >= 128) {
      state.uncertain = true;
      state.message = 'Terminal input stopped because the queue was full. Some keys were not sent. Check the terminal before typing again.';
      queue.layout.uncertainDeliveries.add(id);
      queue.cancelled = true;
      queue.discardPending(SessionUnavailable());
      queue.timer?.cancel();
      if (!queue.running) {
        _terminalInput.remove(id);
        if (!queue.settled.isCompleted) queue.settled.complete();
      }
      _scheduleSave();
      notifyListeners();
      return null;
    }
    final previous = queue.pending.lastOrNull;
    final last = receipt == null && previous?.receipt == null
        ? previous?.input
        : null;
    final queued = _QueuedTerminalInput(
      input,
      receipt: receipt,
      attachment: attachment,
    );
    if (last?.textValue != null &&
        !last!.isPaste &&
        !input.isPaste &&
        input.textValue != null &&
        utf8.encode(last.textValue! + input.textValue!).length <=
            maxInputBytes) {
      previous!.input = TerminalInput.text(last.textValue! + input.textValue!);
    } else if (last?.keyNames != null &&
        input.keyNames != null &&
        last!.keyNames!.length + input.keyNames!.length <= 32) {
      previous!.input = TerminalInput.keys([
        ...last.keyNames!,
        ...input.keyNames!,
      ]);
    } else {
      queue.pending.add(queued);
    }
    queue.bytes += cost;
    if (!queue.running && queue.timer == null) {
      queue.timer = Timer(const Duration(milliseconds: 8), () {
        queue.timer = null;
        unawaited(_pumpTerminalInput(id, queue));
      });
    }
    notifyListeners();
    return queued;
  }

  Future<void> _pumpTerminalInput(String id, _TerminalInputQueue queue) async {
    queue.running = true;
    _terminalDispatches[id] = queue;
    queue.state.terminalSending = true;
    bool current() =>
        !queue.cancelled &&
        !_disposed &&
        _active &&
        queue.generation == _generation &&
        identical(_backend, queue.backend) &&
        layout.selectedId == id;
    try {
      while (queue.pending.isNotEmpty && current()) {
        final queued = queue.pending.removeAt(0), input = queued.input;
        queue.bytes -= input.estimatedBytes;
        if (queued.cancelled) {
          queued.fail(SessionUnavailable());
          continue;
        }
        var submitted = false;
        if (!_deliveryMarkerFits(queue.layout, id)) {
          queued.fail(SessionUnavailable());
          queue.failure = SessionUnavailable();
          queue.state.message = 'Check previous unconfirmed deliveries before sending more input.';
          queue.discardPending(SessionUnavailable());
          break;
        }
        queue.layout.uncertainDeliveries.add(id);
        try {
          // Persist before dispatch; key input is never replayed after uncertainty.
          await store.save(snapshot);
          if (!current() || queued.cancelled) {
            if (!queue.state.uncertain) {
              queue.layout.uncertainDeliveries.remove(id);
            }
            queued.fail(SessionUnavailable());
            if (!current()) break;
            continue;
          }
          if (queued.attachment != null) {
            queued.attachment!.inputDispatched = true;
            notifyListeners();
          }
          if (!current() || queued.cancelled) {
            if (!queue.state.uncertain) {
              queue.layout.uncertainDeliveries.remove(id);
            }
            queued.fail(SessionUnavailable());
            if (!current()) break;
            continue;
          }
          submitted = true;
          await queue.backend.sendTerminalInput(queue.session, input);
          queued.succeed();
          if (!queue.state.uncertain) {
            queue.layout.uncertainDeliveries.remove(id);
            queue.state.message = null;
          }
        } catch (error) {
          queue.failure = error;
          queue.state.uncertain =
              queue.state.uncertain ||
              error is DeliveryUncertain ||
              (submitted &&
                  error is! ConnectionFailure &&
                  error is! ArgumentError);
          if (queue.state.uncertain) {
            queue.layout.uncertainDeliveries.add(id);
          } else {
            queue.layout.uncertainDeliveries.remove(id);
          }
          queued.fail(
            queue.state.uncertain ? DeliveryUncertain() : SessionUnavailable(),
          );
          queue.state.message = queue.state.uncertain
              ? 'Terminal input delivery is uncertain. Check the terminal before typing again.'
              : !submitted
              ? 'Terminal input was not sent because the layout could not be saved.'
              : _message(error);
          queue.discardPending(SessionUnavailable());
          break;
        } finally {
          _scheduleSave();
        }
      }
    } finally {
      queue.discardPending(SessionUnavailable());
      queue.state.terminalSending = false;
      queue.running = false;
      if (!queue.settled.isCompleted) queue.settled.complete();
      if (identical(_terminalDispatches[id], queue)) {
        _terminalDispatches.remove(id);
      }
      if (identical(_terminalInput[id], queue)) _terminalInput.remove(id);
      if (identical(queue.layout, layout)) {
        final currentState = sendStates.putIfAbsent(id, SendState.new);
        currentState.uncertain = queue.state.uncertain;
        currentState.message = queue.state.message;
      }
      if (!_disposed) notifyListeners();
    }
  }

  bool _imageCurrent(String id, ImageDropState state) {
    final current = sessionById(id), before = state.session;
    return !state.cancelled &&
        identical(imageDrops[id], state) &&
        canSendTerminalInput(id) &&
        current?.key == before.key &&
        current?.paneId == before.paneId &&
        current?.origin?.targetHash == before.origin?.targetHash &&
        current?.imageTransferEnabled == true;
  }

  String? imageDropUnavailableReason(String id) {
    if (sendStates[id]?.uncertain == true ||
        (layout.uncertainDeliveries.contains(id) &&
            sendStates[id]?.terminalSending != true)) {
      return 'Input is paused after an unconfirmed delivery. Check the terminal, then choose “I’ve checked” below before adding images.';
    }
    if (!canSendTerminalInput(id)) {
      return 'Images can be added when this terminal is connected and ready for input.';
    }
    if (_backend is! ImageAttachmentBackend ||
        !(_backend as ImageAttachmentBackend).imageAttachmentsEnabled ||
        sessionById(id)?.imageTransferEnabled != true) {
      return 'Image attachments are unavailable for this connection.';
    }
    if (imageDrops[id]?.busy == true) {
      return 'An image attachment is already in progress.';
    }
    return null;
  }

  bool canDropImages(String id) => imageDropUnavailableReason(id) == null;
  void cancelImageDrop(String id, {bool force = false}) {
    final state = imageDrops[id];
    if (state == null ||
        !state.busy ||
        (!force &&
            state.phase == ImageDropPhase.attaching &&
            state.inputDispatched)) {
      return;
    }
    state.cancelled = true;
    final queue = _terminalInput[id];
    if (queue != null) {
      final pending = queue.pending
          .where((input) => identical(input.attachment, state))
          .toList();
      for (final input in pending) {
        queue.pending.remove(input);
        queue.bytes -= input.input.estimatedBytes;
        input.fail(SessionUnavailable());
      }
    }
    state.phase = ImageDropPhase.cancelled;
    state.message = 'Image attachment cancelled.';
    state.prepared.clear();
    if (_backend is ImageAttachmentBackend) {
      (_backend as ImageAttachmentBackend).cancelPendingImageTransfers();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> dropImages(String id, List<ImageSource> sources) async {
    if (!canDropImages(id)) return;
    final state = ImageDropState(
      sessionById(id)!,
      sources.map((s) => s.name).toList(),
    );
    imageDrops[id] = state;
    try {
      if (sources.isEmpty || sources.length > 4) {
        throw const FormatException('Drop up to four images at a time.');
      }
      notifyListeners();
      for (final source in sources) {
        if (!_imageCurrent(id, state)) throw SessionUnavailable();
        final bytes = await source.read();
        if (!_imageCurrent(id, state)) throw SessionUnavailable();
        state.prepared.add(PreparedImage.prepare(source.name, bytes));
      }
      await _uploadImages(id, state);
    } catch (error) {
      _imageError(id, state, error);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> retryImageDrop(String id) async {
    final state = imageDrops[id];
    if (state == null ||
        state.phase != ImageDropPhase.failed ||
        state.prepared.length != state.names.length ||
        !canDropImages(id)) {
      return;
    }
    try {
      await _uploadImages(id, state);
    } catch (error) {
      _imageError(id, state, error);
    }
    if (!_disposed) notifyListeners();
  }

  void _imageError(String id, ImageDropState state, Object error) {
    if (error is DeliveryUncertain || sendStates[id]?.uncertain == true) {
      state.phase = ImageDropPhase.uncertain;
      state.message = 'Check the terminal before attaching again.';
      state.prepared.clear();
    } else if (state.cancelled || !_imageCurrent(id, state)) {
      state.phase = ImageDropPhase.cancelled;
      state.message =
          'Image attachment cancelled because its destination changed.';
      state.prepared.clear();
    } else {
      state.phase = ImageDropPhase.failed;
      state.message = error is FormatException
          ? error.message
          : _message(error);
    }
  }

  Future<void> _uploadImages(String id, ImageDropState state) async {
    final backend = _backend! as ImageAttachmentBackend;
    while (state.nextIndex < state.prepared.length) {
      if (!_imageCurrent(id, state)) throw SessionUnavailable();
      state.phase = ImageDropPhase.uploading;
      state.message = null;
      state.bytesSent = 0;
      state.total = state.prepared[state.nextIndex].bytes.length;
      notifyListeners();
      final path = await backend.uploadImage(
        state.session,
        state.prepared[state.nextIndex],
        cancelled: () => !_imageCurrent(id, state),
        onProgress: (sent, total) {
          if (_imageCurrent(id, state)) {
            state.bytesSent = sent;
            state.total = total;
            notifyListeners();
          }
        },
      );
      if (!_imageCurrent(id, state)) throw SessionUnavailable();
      state.inputDispatched = false;
      state.phase = ImageDropPhase.attaching;
      notifyListeners();
      await insertAttachmentPath(id, path, attachment: state);
      state.nextIndex++;
      if (!_imageCurrent(id, state)) throw SessionUnavailable();
    }
    state.phase = ImageDropPhase.complete;
    state.message = 'Images added to the prompt. Press Enter when ready.';
    state.prepared.clear();
  }

  Future<void> insertAttachmentPath(
    String id,
    String path, {
    ImageDropState? attachment,
  }) async {
    if (!canSendTerminalInput(id)) throw SessionUnavailable();
    // Validate the destination; a paste carries the path without shell quoting.
    quoteAttachmentPath(path);
    final receipt = Completer<void>();
    final queued = _enqueueTerminalInput(
      id,
      TerminalInput.paste(path),
      receipt: receipt,
      attachment: attachment,
    );
    if (queued == null) {
      throw SessionUnavailable('Attachment input could not be queued.');
    }
    await receipt.future;
  }

  List<ComputerInfo> get manageableComputers => computers
      .where(
        (c) =>
            c.state == ComputerState.live &&
            c.managementEnabled &&
            c.origin.valid,
      )
      .toList();

  bool canManageComputer(SessionOrigin origin) =>
      origin.profile == source &&
      !_disposed &&
      _active &&
      _backend is SessionManagementBackend &&
      sessionActionStates[origin.computerId]?.pending != true &&
      !layout.uncertainActions.containsKey(origin.computerId) &&
      computers.any(
        (c) =>
            c.state == ComputerState.live &&
            c.managementEnabled &&
            sameSessionOrigin(c.origin, origin),
      );
  bool canManageSession(SessionInfo session) =>
      session.available &&
      session.inputEnabled &&
      session.origin != null &&
      canManageComputer(session.origin!) &&
      sessions.any(
        (s) =>
            s.key == session.key &&
            s.available &&
            s.paneId == session.paneId &&
            s.origin != null &&
            sameSessionOrigin(s.origin!, session.origin!),
      );

  Future<T> _sessionAction<T>(
    String op,
    SessionOrigin origin,
    Future<T> Function(SessionManagementBackend) run, {
    void Function(T)? applied,
  }) async {
    if (layout.uncertainActions.length >= 256 || !canManageComputer(origin)) {
      throw SessionUnavailable(
        'Check this computer and any unconfirmed action before trying again.',
      );
    }
    final capturedLayout = layout,
        generation = _generation,
        backend = _backend! as SessionManagementBackend;
    final state = sessionActionStates.putIfAbsent(
      origin.computerId,
      SessionActionState.new,
    );
    state.pending = true;
    state.error = null;
    capturedLayout.uncertainActions[origin.computerId] = SessionActionRecord(
      op,
      origin,
    );
    notifyListeners();
    var submitted = false;
    try {
      // Journal before crossing the mutation boundary so app termination cannot lose the inspection gate.
      await store.save(snapshot);
      if (_disposed ||
          !_active ||
          generation != _generation ||
          !identical(_backend, backend) ||
          !computers.any(
            (c) =>
                c.state == ComputerState.live &&
                c.managementEnabled &&
                sameSessionOrigin(c.origin, origin),
          )) {
        throw SessionUnavailable('The selected connection changed.');
      }
      submitted = true;
      final result = await run(backend);
      if (!_disposed &&
          generation == _generation &&
          identical(layout, capturedLayout)) {
        applied?.call(result);
        _cancelDiscovery();
        await refresh();
      }
      capturedLayout.uncertainActions.remove(origin.computerId);
      return result;
    } catch (error) {
      if (error is! SessionActionUncertain) {
        capturedLayout.uncertainActions.remove(origin.computerId);
      }
      state.error = error is SessionActionUncertain
          ? error.toString()
          : submitted
          ? 'The session action could not be completed. $error'
          : 'The session action did not start. $error';
      rethrow;
    } finally {
      state.pending = false;
      try {
        await store.save(snapshot);
      } catch (_) {
        store.warning = 'Session action state could not be saved.';
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> renameSession(SessionInfo session, String title) async {
    validateSessionAction('rename', {'title': title});
    if (!canManageSession(session)) throw SessionUnavailable();
    await _sessionAction(
      'rename',
      session.origin!,
      (backend) => backend.renameSession(session, title),
    );
  }

  Future<void> closeSession(SessionInfo session) async {
    if (!canManageSession(session)) throw SessionUnavailable();
    await _sessionAction(
      'close',
      session.origin!,
      (backend) => backend.closeSession(session),
      applied: (_) {
        sessions = sessions.where((s) => s.key != session.key).toList();
        if (layout.favourites.containsKey(session.key.id)) {
          layout.favourites[session.key.id] = session.unavailable();
        }
        if (layout.retained.containsKey(session.key.id)) {
          layout.retained[session.key.id] = session.unavailable();
        }
        final entry = terminals.remove(session.key.id);
        if (entry != null) unawaited(_stopEntry(entry));
        if (layout.selectedId == session.key.id) layout.selectedId = null;
      },
    );
  }

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
    return _sessionAction(
      'create',
      origin,
      (backend) =>
          backend.createSession(origin, workspace, title: title, cwd: cwd),
      applied: (created) {
        if (created.origin == null ||
            !sameSessionOrigin(created.origin!, origin) ||
            created.workspaceId != workspace.id) {
          throw const SessionActionUncertain();
        }
        sessions = [...sessions.where((s) => s.key != created.key), created];
        layout.filter = 'all';
        search = '';
        select(created.key.id);
      },
    );
  }

  void acknowledgeSessionAction(String computerId) {
    if (sessionActionStates[computerId]?.pending == true) return;
    layout.uncertainActions.remove(computerId);
    sessionActionStates[computerId]?.error = null;
    _scheduleSave();
    notifyListeners();
  }

  void acknowledgeDelivery(String id) {
    if (terminalInputPending(id)) return;
    final state = sendStates[id];
    if (state != null) {
      state.uncertain = false;
      layout.uncertainDeliveries.remove(id);
      state.message = 'Delivery checked. You can edit or send the draft.';
      _scheduleSave();
      notifyListeners();
    }
  }

  TabGroup createGroup(String name, List<String> ids) {
    final group = TabGroup(
      'g${DateTime.now().microsecondsSinceEpoch}',
      displayText(name).isEmpty ? 'New group' : displayText(name),
      [],
    );
    if (layout.groups.length >= 32) return layout.groups.last;
    layout.groups.add(group);
    for (final id in ids.take(256)) {
      _move(id, group);
    }
    _scheduleSave();
    notifyListeners();
    return group;
  }

  void _move(String id, TabGroup target) {
    final session = sessionById(id);
    if (session == null) return;
    for (final group in layout.groups) {
      group.sessions.remove(id);
    }
    if (target.sessions.length < 256) target.sessions.add(id);
    layout.retained[id] = session;
  }

  void moveToGroup(String id, String groupId) {
    final group = layout.groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null) return;
    _move(id, group);
    _scheduleSave();
    notifyListeners();
  }

  void removeFromGroup(String id, String groupId) {
    final group = layout.groups.where((g) => g.id == groupId).firstOrNull;
    group?.sessions.remove(id);
    _scheduleSave();
    notifyListeners();
  }

  void renameGroup(String groupId, String name) {
    final clean = displayText(name).trim();
    final group = layout.groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null || clean.isEmpty || clean == group.name) return;
    group.name = clean;
    _scheduleSave();
    notifyListeners();
  }

  void deleteGroup(String groupId) {
    layout.groups.removeWhere((g) => g.id == groupId);
    if (layout.filter == 'group:$groupId') setFilter('all');
    _scheduleSave();
    notifyListeners();
  }

  bool get canReorderGrid =>
      layout.filter != 'recent' &&
      (layout.gridSort == SessionSort.custom || layout.filter == 'favourites');

  void reorderFavourite(String id, String targetId) {
    if (layout.filter == 'favourites') reorderGridSession(id, targetId);
  }

  void reorderGridSession(String id, String targetId) {
    if (!canReorderGrid || id == targetId) return;
    final visible = visibleSessions.map((s) => s.key.id).toList();
    final oldIndex = visible.indexOf(id), newIndex = visible.indexOf(targetId);
    if (oldIndex < 0 || newIndex < 0) return;
    visible.insert(newIndex, visible.removeAt(oldIndex));
    _saveSessionOrder(visible);
    layout.gridSort = SessionSort.custom;
    _scheduleSave();
    notifyListeners();
  }

  void _saveSessionOrder(List<String> reordered) {
    final List<String> destination;
    final List<String> base;
    if (layout.filter.startsWith('group:')) {
      final group = layout.groups
          .where((g) => 'group:${g.id}' == layout.filter)
          .firstOrNull;
      if (group == null) return;
      destination = group.sessions;
      base = List.of(destination);
    } else if (layout.filter == 'favourites') {
      destination = layout.favouriteOrder;
      base = sessionsForFilter('favourites').map((s) => s.key.id).toList();
    } else {
      destination = layout.tabOrder;
      base = {
        ...destination,
        ...sessionsForFilter('all').map((s) => s.key.id),
      }.toList();
    }
    // Reorder only visible slots, preserving other computers, workspaces and
    // sessions excluded by search, including temporarily unavailable entries.
    final ids = reordered.toSet(), sequence = reordered.iterator;
    final result = base.map((id) {
      if (!ids.contains(id)) return id;
      sequence.moveNext();
      return sequence.current;
    }).toList();
    destination
      ..clear()
      ..addAll(result);
  }

  void reorderTabs(int oldIndex, int newIndex) {
    if (layout.filter == 'recent') return;
    final rows = sessionsForFilter(layout.filter).map((s) => s.key.id).toList();
    if (oldIndex < 0 ||
        oldIndex >= rows.length ||
        newIndex < 0 ||
        newIndex >= rows.length) {
      return;
    }
    rows.insert(newIndex, rows.removeAt(oldIndex));
    _saveSessionOrder(rows);
    _scheduleSave();
    notifyListeners();
  }

  void setAppearance(String value) {
    if (!['system', 'light', 'dark'].contains(value) ||
        snapshot.appearance == value) {
      return;
    }
    snapshot.appearance = value;
    _scheduleSave();
    notifyListeners();
  }

  void setZoom(double value) {
    layout.zoom = value.clamp(0.5, 3);
    _scheduleSave();
    notifyListeners();
  }

  void setTileWidth(double value) {
    layout.tileWidth = value.clamp(240, 480);
    _scheduleSave();
    notifyListeners();
  }

  void _renderSoon({bool immediate = false}) {
    if (_disposed) return;
    if (immediate) {
      _renderTimer?.cancel();
      _renderTimer = null;
      notifyListeners();
      return;
    }
    _renderTimer ??= Timer(const Duration(milliseconds: 400), () {
      _renderTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(flush()),
    );
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    try {
      await store.save(snapshot);
    } catch (_) {
      store.warning =
          'Changes could not be saved. Check the data folder is writable.';
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    if (_disposed) return;
    _disposed = true;
    _backgroundTimer?.cancel();
    try {
      await _suspending;
    } catch (_) {}
    _cancelSessionActions();
    _cancelTerminalInput();
    _generation++;
    await _cancelDiscovery();
    _poll?.cancel();
    _saveTimer?.cancel();
    _renderTimer?.cancel();
    await Future.wait(terminals.values.map(_stopEntry));
    await _backend?.close();
    await flush();
    super.dispose();
  }
}
