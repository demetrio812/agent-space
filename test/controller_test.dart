import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';
import 'package:agentspace/src/storage.dart';

SessionInfo item(
  String terminal, {
  String profile = 'demo',
  String generation = 'a',
}) => SessionInfo(
  key: SessionKey('herdr', profile, generation, terminal),
  paneId: 'p$terminal',
  title: 'Task $terminal',
  project: 'sample',
  agent: 'claude',
  status: SessionStatus.idle,
  workspaceId: 'w1',
  workspaceLabel: 'Work',
  inputEnabled: true,
);

class FakeBackend implements SessionBackend {
  FakeBackend(this.sourceId, this.sessions);
  @override
  final String sourceId;
  List<SessionInfo> sessions;
  final observers = <String, StreamController<ObserveEvent>>{};
  int observationStarts = 0, cancels = 0, sends = 0, catalogs = 0;
  bool uncertain = false;
  Object? catalogError;
  @override
  Future<List<SessionInfo>> listSessions() async {
    catalogs++;
    if (catalogError != null) throw catalogError!;
    return sessions;
  }

  @override
  Stream<ObserveEvent> observe(SessionInfo session) {
    final stream = StreamController<ObserveEvent>(
      onListen: () => observationStarts++,
      onCancel: () => cancels++,
    );
    observers[session.key.id] = stream;
    return stream.stream;
  }

  @override
  Future<void> sendText(SessionInfo session, String text) async {
    sends++;
    if (uncertain) throw DeliveryUncertain();
  }

  @override
  Future<void> close() async {
    for (final stream in observers.values) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}

void main() {
  late Directory dir;
  late FakeBackend backend;
  late AppController app;
  test('all shutdown callers await the final saved snapshot', () async {
    final store = _DelayedStore();
    final controller = AppController(
      snapshot: AppSnapshot(),
      store: store,
      backendFactory: (_) => FakeBackend('demo', []),
    );
    final first = controller.shutdown();
    await store.entered.future;
    var completed = false;
    final second = controller.shutdown().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    try {
      expect(completed, isFalse);
    } finally {
      store.release.complete();
      await Future.wait([first, second]);
    }
  });
  test(
    'permanent connection failures stop polling until explicit reconnect',
    () async {
      final failed = FakeBackend('demo', [])
        ..catalogError = ConnectionFailure(
          'Wrong host identity',
          permanent: true,
        );
      final controller = AppController(
        snapshot: AppSnapshot(),
        store: LayoutStore(dir.path),
        backendFactory: (_) => failed,
      );
      try {
        await controller.start();
        expect(failed.catalogs, 1);
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(failed.catalogs, 1);
        await controller.reconnect();
        expect(failed.catalogs, 2);
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(failed.catalogs, 2);
      } finally {
        await controller.shutdown();
      }
    },
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agentspace-controller-');
    backend = FakeBackend('demo', [item('one'), item('two')]);
    app = AppController(
      snapshot: AppSnapshot(),
      store: LayoutStore(dir.path),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
  });
  tearDown(() async {
    await app.shutdown();
    await dir.delete(recursive: true);
  });
  test(
    'favourite filter updates immediately and keeps offline placeholders',
    () async {
      app.toggleFavourite(backend.sessions.first);
      app.setFilter('favourites');
      expect(app.visibleSessions, hasLength(1));
      expect(app.visibleSessions.single.title, 'Task one');
      backend.sessions = [];
      await app.refresh();
      expect(app.visibleSessions.single.available, isFalse);
      app.toggleFavourite(app.visibleSessions.single);
      expect(app.visibleSessions, isEmpty);
    },
  );
  test(
    'selection and preview share one observer and background releases it',
    () async {
      final session = backend.sessions.first;
      app.setPreviewTargets([session.key.id]);
      app.select(session.key.id);
      await Future<void>.delayed(Duration.zero);
      expect(backend.observationStarts, 1);
      backend.observers[session.key.id]!.add(
        TerminalFrame(80, 24, 0, true, Uint8List.fromList('live'.codeUnits)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.terminals[session.key.id]!.screen.text, contains('live'));
      await app.setActive(false, gracePeriod: Duration.zero);
      expect(backend.cancels, 1);
    },
  );
  test(
    'dictation targets selected session and preserves existing draft',
    () async {
      final session = backend.sessions.first;
      app.select(session.key.id);
      final generation = app.dictationGeneration;
      app.updateDraft(session.key.id, 'Unsent draft');
      expect(
        await app.sendDictation(session, generation, 'Dictated message'),
        isTrue,
      );
      expect(backend.sends, 1);
      expect(app.layout.drafts[session.key.id], 'Unsent draft');
      app.select(backend.sessions.last.key.id);
      expect(
        await app.sendDictation(session, generation, 'Wrong target'),
        isFalse,
      );
      expect(backend.sends, 1);
      app.select(session.key.id);
      await app.setActive(false, gracePeriod: Duration.zero);
      expect(
        await app.sendDictation(session, generation, 'Background'),
        isFalse,
      );
      expect(backend.sends, 1);
    },
  );
  test('dictation uncertain delivery is not replayed', () async {
    final session = backend.sessions.first;
    app.select(session.key.id);
    backend.uncertain = true;
    expect(
      await app.sendDictation(session, app.dictationGeneration, 'Message'),
      isFalse,
    );
    expect(
      await app.sendDictation(session, app.dictationGeneration, 'Message'),
      isFalse,
    );
    expect(backend.sends, 1);
  });
  test('uncertain send retains draft and refuses automatic replay', () async {
    final id = backend.sessions.first.key.id;
    app.updateDraft(id, 'Please review');
    backend.uncertain = true;
    await app.sendDraft(id);
    expect(app.layout.drafts[id], 'Please review');
    expect(app.sendStates[id]!.uncertain, isTrue);
    await app.sendDraft(id);
    expect(backend.sends, 1);
    backend.uncertain = false;
    app.acknowledgeDelivery(id);
    await app.sendDraft(id);
    expect(backend.sends, 2);
    expect(app.layout.drafts[id], isNull);
  });
  test(
    'uncertain delivery warning survives saved layout and relaunch',
    () async {
      final id = backend.sessions.first.key.id;
      app.updateDraft(id, 'Please review');
      backend.uncertain = true;
      await app.sendDraft(id);
      await app.flush();
      final restored = AppController(
        snapshot: await LayoutStore(dir.path).load(),
        store: LayoutStore(dir.path),
        backendFactory: (_) => backend,
      );
      try {
        await restored.start(polling: false);
        expect(restored.sendStates[id]?.uncertain, isTrue);
        await restored.sendDraft(id);
        expect(backend.sends, 1);
        restored.acknowledgeDelivery(id);
        backend.uncertain = false;
        await restored.sendDraft(id);
        expect(backend.sends, 2);
      } finally {
        await restored.shutdown();
      }
    },
  );
  test(
    'new generation never reassigns favourite or selected saved view',
    () async {
      final old = backend.sessions.first;
      app.toggleFavourite(old);
      app.select(old.key.id);
      backend.sessions = [item('one', generation: 'b')];
      await app.refresh();
      expect(app.selectedSession!.available, isFalse);
      expect(app.selectedSession!.key.server, 'a');
      app.setFilter('favourites');
      expect(app.visibleSessions.single.key.server, 'a');
    },
  );
  test('catalog outage retains current sessions and separates stale transport from agent status', () async {
    backend.catalogError = ConnectionFailure('offline');
    await app.refresh();
    expect(app.sessions, hasLength(2));
    expect(app.connectionState, ConnectionState.stale);
    expect(app.sessions.first.status, SessionStatus.idle);
  });
  test(
    'group transfer removes duplicate ownership and preserves tab order',
    () {
      final first = backend.sessions.first.key.id,
          second = backend.sessions.last.key.id;
      final a = app.createGroup('Review', [first, second]);
      final b = app.createGroup('Focus', []);
      app.moveToGroup(first, b.id);
      expect(a.sessions, [second]);
      expect(b.sessions, [first]);
      app.setFilter('group:${b.id}');
      expect(app.visibleSessions.single.key.id, first);
    },
  );
  test(
    'group rename and deletion persist without touching session state',
    () async {
      final session = backend.sessions.first;
      app.toggleFavourite(session);
      app.updateDraft(session.key.id, 'keep this draft');
      final group = app.createGroup('Review', [session.key.id]);
      app.setFilter('group:${group.id}');
      app.renameGroup(group.id, '  Focus  ');
      app.renameGroup(group.id, ' \n ');
      expect(group.name, 'Focus');
      expect(app.filterLabel, 'Focus');
      await app.shutdown();
      final stored = await LayoutStore(dir.path).load();
      final saved = stored.layoutFor('demo');
      expect(saved.groups.single.name, 'Focus');
      expect(saved.groups.single.sessions, [session.key.id]);
      final reopened = AppController(
        snapshot: stored,
        store: LayoutStore(dir.path),
        backendFactory: (_) => FakeBackend('demo', backend.sessions),
      );
      await reopened.start(polling: false);
      reopened.deleteGroup(group.id);
      expect(reopened.layout.filter, 'all');
      expect(reopened.sessions.map((s) => s.key.id), contains(session.key.id));
      await reopened.shutdown();
      final deleted = (await LayoutStore(dir.path).load()).layoutFor('demo');
      expect(deleted.groups, isEmpty);
      expect(deleted.favourites, contains(session.key.id));
      expect(deleted.drafts[session.key.id], 'keep this draft');
    },
  );
  test('tab reorder uses the destination index after removal', () {
    final first = backend.sessions.first.key.id,
        second = backend.sessions.last.key.id;
    app.reorderTabs(0, 1);
    expect(app.visibleSessions.map((s) => s.key.id), [second, first]);
  });
  test(
    'valid sequence loss retries a fresh stream and replaces the old screen',
    () async {
      final id = backend.sessions.first.key.id;
      app.select(id);
      await Future<void>.delayed(Duration.zero);
      backend.observers[id]!.add(
        TerminalFrame(
          80,
          24,
          0,
          true,
          Uint8List.fromList('old screen'.codeUnits),
        ),
      );
      backend.observers[id]!.add(
        TerminalFrame(80, 24, 2, false, Uint8List.fromList('lost'.codeUnits)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.terminals[id]!.state, TerminalState.stale);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(backend.observationStarts, 2);
      backend.observers[id]!.add(
        TerminalFrame(
          100,
          26,
          0,
          true,
          Uint8List.fromList('fresh screen'.codeUnits),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(app.terminals[id]!.screen.text, contains('fresh screen'));
      expect(app.terminals[id]!.screen.text, isNot(contains('old screen')));
    },
  );
}

class _DelayedStore extends LayoutStore {
  _DelayedStore() : super('unused-shutdown-store');
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> save(AppSnapshot value) async {
    entered.complete();
    await release.future;
  }
}
