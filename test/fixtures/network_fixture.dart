import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/network_models.dart';
import 'package:agentspace/src/network_backend.dart';
import 'package:agentspace/src/protocol.dart';
import 'package:agentspace/src/storage.dart';

const fixtureGeneration =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fixtureTarget =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const fixtureMachineA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fixtureMachineB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, dynamic> wireCatalog(String title) => {
  'serverIdentity': fixtureGeneration,
  'inputEnabled': true,
  'terminalInputEnabled': true,
  'terminalViewportEnabled': true,
  'catalog': {
    'result': {
      'agents': <Map<String, dynamic>>[
        {
          'terminal_id': 't1',
          'pane_id': 'p1',
          'workspace_id': 'w1',
          'tab_id': 'tab1',
          'terminal_title': title,
          'agent_status': 'idle',
        },
      ],
    },
  },
  'workspaces': <Map<String, dynamic>>[
    {'workspace_id': 'w1', 'label': 'Workbench'},
  ],
  'tabs': [],
};
Map<String, dynamic> wireComputer(
  String machine,
  String label, {
  String session = 'default',
  String state = 'live',
  String targetHash = fixtureTarget,
}) => {
  'machine': machine,
  'label': label,
  'session': session,
  'targetHash': targetHash,
  'generation': fixtureGeneration,
  'state': state,
  'code': state == 'attention' ? 'auth_required' : '',
  if (state == 'live') 'catalog': wireCatalog('Session $label'),
};

class NetworkFixture extends SessionBackend
    implements
        NetworkCatalogBackend,
        TerminalInputBackend,
        TerminalViewportBackend {
  @override
  String get sourceId => 'remote';
  List<SessionInfo> initial = [];
  bool completeInitially = true;
  bool holdFirst = false;
  bool closed = false;
  int epoch = 0, stops = 0, observations = 0;
  final inputs = <Map<String, dynamic>>[];
  final streams = <StreamController<ObserveEvent>>[];
  final discovery = <int, StreamController<NetworkUpdate>>{};
  SessionInfo session({
    required String machine,
    String label = 'Mac',
    String herdrSession = 'default',
    String generation = fixtureGeneration,
    String terminal = 't1',
    String workspace = 'w1',
    String targetHash = fixtureTarget,
  }) {
    final origin = SessionOrigin(
      profile: 'remote',
      machineId: machine,
      machineLabel: label,
      herdrSession: herdrSession,
      targetHash: targetHash,
      generation: generation,
    );
    return SessionInfo(
      key: originKey(origin, terminal),
      origin: origin,
      paneId: 'p1',
      title: 'Session $label',
      project: 'project',
      agent: 'terminal',
      status: SessionStatus.idle,
      workspaceId: workspace,
      workspaceLabel: 'Workbench',
      inputEnabled: true,
      terminalInputEnabled: true,
      terminalViewportEnabled: true,
    );
  }

  AppController controller(
    Directory directory, {
    AppSnapshot? snapshot,
    LayoutStore? store,
  }) {
    final state = snapshot ?? AppSnapshot();
    state.activeSource = 'remote';
    if (!state.profiles.any((p) => p.id == 'remote')) {
      state.profiles.add(
        ConnectionProfile(
          id: 'remote',
          label: 'Gateway',
          kind: ConnectionKind.ssh,
        ),
      );
    }
    return AppController(
      snapshot: state,
      store: store ?? LayoutStore(directory.path),
      backendFactory: (_) => this,
    );
  }

  List<ComputerInfo> computersFor(List<SessionInfo> sessions) => {
    for (final session in sessions)
      session.computerId: ComputerInfo(
        origin: session.origin!,
        state: ComputerState.live,
      ),
  }.values.toList();
  @override
  Stream<NetworkUpdate> discover({
    required int epoch,
    required Set<String> priorityMachines,
  }) {
    this.epoch = epoch;
    closed = false;
    late StreamController<NetworkUpdate> controller;
    controller = StreamController(
      onListen: () {
        if (!holdFirst) {
          scheduleMicrotask(
            () => emit(
              NetworkUpdate(
                epoch: epoch,
                computers: computersFor(initial),
                sessions: initial,
                complete: completeInitially,
              ),
            ),
          );
        }
      },
    );
    discovery[epoch] = controller;
    return controller.stream;
  }

  void emit(NetworkUpdate update) {
    final target = discovery[epoch];
    if (target == null || target.isClosed) return;
    target.add(update);
    if (update.complete && update.epoch == epoch) unawaited(target.close());
  }

  @override
  Future<List<SessionInfo>> listSessions() async => initial;
  @override
  Stream<ObserveEvent> observe(SessionInfo session) {
    observations++;
    late StreamController<ObserveEvent> stream;
    stream = StreamController(
      onListen: () => stream.add(
        TerminalFrame(
          90,
          30,
          0,
          true,
          Uint8List.fromList(utf8.encode('fixture')),
        ),
      ),
      onCancel: () {
        stops++;
      },
    );
    streams.add(stream);
    return stream.stream;
  }

  @override
  Stream<ObserveEvent> observeViewport(
    SessionInfo session,
    int cols,
    int rows,
  ) => observe(session);
  @override
  Future<void> resizeViewport(SessionInfo session, int cols, int rows) async {}
  @override
  Future<void> sendText(SessionInfo session, String text) async {
    inputs.add({'session': session, 'text': text});
  }

  @override
  Future<void> sendTerminalInput(
    SessionInfo session,
    TerminalInput input,
  ) async {
    inputs.add({'session': session, 'input': input});
  }

  @override
  Future<void> close() async {
    closed = true;
    for (final stream in discovery.values) {
      if (!stream.isClosed) unawaited(stream.close());
    }
    for (final stream in streams) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}
