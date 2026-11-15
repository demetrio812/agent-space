import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/git_changes.dart';
import 'package:agentspace/src/session_changes.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/backend_errors.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/project_files.dart';
import 'package:agentspace/src/project_workspace.dart';
import 'package:agentspace/src/network_backend.dart';
import 'package:agentspace/src/persistent_bridge.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/ui_common.dart';

import 'project_files_test.dart';
import 'terminal_input_test.dart' show WidgetStore;
import 'fixtures/fake_bridge.dart';
import 'fixtures/network_fixture.dart';

Map<String, dynamic> changePage() => {
  'repository': true,
  'scope': 'a' * 64,
  'folder': 'fixture',
  'branch': 'feature/example',
  'limited': false,
  'entries': [
    {
      'id': 'b' * 64,
      'path': 'src/main.dart',
      'oldPath': '',
      'section': 'staged',
      'status': 'M',
    },
    {
      'id': 'c' * 64,
      'path': 'README.md',
      'oldPath': '',
      'section': 'untracked',
      'status': '?',
    },
  ],
};

class ChangesFixture extends ProjectFixture implements GitChangesBackend {
  int changeLists = 0;
  Completer<GitDiff>? diffHold;
  bool fail = false;
  @override
  Future<GitChangePage> listGitChanges(SessionInfo s) async {
    changeLists++;
    if (fail) throw SessionUnavailable('Cannot refresh changes.');
    return GitChangePage.fromJson(changePage());
  }

  @override
  Future<GitDiff> readGitDiff(SessionInfo s, String scope, String file) async =>
      diffHold == null
      ? GitDiff.fromJson({
          'scope': scope,
          'file': file,
          'text': '--- a/src/main.dart\n+++ b/src/main.dart\n@@ -1 +1 @@\n-old\n+new\n',
          'notice': '',
        })
      : diffHold!.future;
}

class TreeChangesFixture extends ChangesFixture {
  bool hideWidgets = false;
  @override
  Future<GitChangePage> listGitChanges(SessionInfo s) async {
    changeLists++;
    return GitChangePage.fromJson({
      ...changePage(),
      'entries': [
        for (final row in [
          (1, 'src/api/client.dart', 'unstaged'),
          (2, 'src/api/request.dart', 'unstaged'),
          (3, 'src/widgets/button.dart', 'unstaged'),
          (4, 'README.md', 'unstaged'),
          (5, 'src/api/client.dart', 'staged'),
        ])
          if (!hideWidgets || row.$2 != 'src/widgets/button.dart')
            {
              'id': row.$1.toRadixString(16).padLeft(64, '0'),
              'path': row.$2,
              'oldPath': '',
              'section': row.$3,
              'status': 'M',
            },
      ],
    });
  }
}

void main() {
  testWidgets(
    'collapsed ancestors survive compact folder paths changing after refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = TreeChangesFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SessionChanges(
                app: app,
                session: backend.session,
                active: true,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('changes-folder-unstaged-src')),
        );
        await tester.pump();
        backend.hideWidgets = true;
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text('request.dart'), findsNothing);
        final compact = find.byKey(
          const ValueKey('changes-folder-unstaged-src/api'),
        );
        expect(compact, findsOneWidget);
        await tester.tap(compact);
        await tester.pump();
        expect(find.text('request.dart'), findsOneWidget);
        expect(backend.input, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  testWidgets(
    'Changes groups folders, keeps collapse through refresh and expands filtered matches',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = TreeChangesFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(Brightness.dark),
            home: Scaffold(
              body: SessionChanges(
                app: app,
                session: backend.session,
                active: true,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('api'), findsOneWidget);
        expect(find.text('client.dart'), findsNWidgets(2));
        expect(find.text('request.dart'), findsOneWidget);
        expect(find.text('src/api/client.dart'), findsNothing);
        final folder = find.byKey(
          const ValueKey('changes-folder-unstaged-src'),
        );
        await tester.tap(folder);
        await tester.pump();
        expect(find.text('request.dart'), findsNothing);
        expect(
          find.text('client.dart'),
          findsOneWidget,
        ); // Staged tree stays open.
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(find.text('request.dart'), findsNothing);
        await tester.enterText(find.byType(TextField), 'request');
        await tester.pump();
        expect(find.text('request.dart'), findsOneWidget);
        expect(find.text('button.dart'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('changes-folder-unstaged-src/api')),
        );
        await tester.pump();
        expect(find.text('request.dart'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('changes-folder-unstaged-src/api')),
        );
        await tester.pump();
        expect(find.text('request.dart'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(find.text('request.dart'), findsNothing);
        await tester.tap(folder);
        await tester.pump();
        await tester.tap(find.text('request.dart'));
        await tester.pump();
        expect(find.text('src/api/request.dart'), findsOneWidget);
        expect(find.byType(SelectableText), findsOneWidget);
        await tester.tap(find.byTooltip('Back to changes'));
        await tester.pump();
        expect(find.text('request.dart'), findsOneWidget);
        expect(backend.input, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  test(
    'network Changes uses only discovery and the selected peer route',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [
          wireComputer(fixtureMachineA, 'A'),
          wireComputer(fixtureMachineB, 'B'),
        ];
      wire.resultFor = (row) => switch (row['op']) {
        'changes.list' => changePage(),
        'changes.read' => {
          'scope': 'a' * 64,
          'file': 'b' * 64,
          'text': '+peer B\n',
          'notice': '',
        },
        _ => null,
      };
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      final updates = await backend
          .discover(epoch: 1, priorityMachines: {})
          .toList();
      final selected = updates.last.sessions.singleWhere(
        (s) => s.origin!.machineId == fixtureMachineB,
      );
      final page = await backend.listGitChanges(selected);
      final diff = await backend.readGitDiff(
        selected,
        page.scope,
        page.entries.first.id,
      );
      expect(diff.text, '+peer B\n');
      final requests = wire.requests
          .where((r) => (r['op'] as String).startsWith('changes.'))
          .toList();
      expect(requests, hasLength(2));
      for (final r in requests) {
        expect(r['lane'], 'discovery');
        expect(r['route']['machine'], fixtureMachineB);
        expect(r['route']['generation'], fixtureGeneration);
      }
      expect(wire.sentInputs, isEmpty);
      expect(
        () => validateChangesPayload('changes.read', {
          'scope': 'a' * 64,
          'file': 'b' * 64,
          'path': '/tmp',
        }),
        throwsArgumentError,
      );
    },
  );

  test('diff from a replaced connection is rejected', () async {
    final backend = ChangesFixture()..diffHold = Completer<GitDiff>();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    addTearDown(app.shutdown);
    await app.start(polling: false);
    app.select(backend.session.key.id);
    final result = expectLater(
      app.readGitDiff(backend.session, 'a' * 64, 'b' * 64),
      throwsA(isA<SessionUnavailable>()),
    );
    await app.reconnect();
    backend.diffHold!.complete(
      GitDiff(
        scope: 'a' * 64,
        file: 'b' * 64,
        text: 'old private diff',
        notice: '',
      ),
    );
    await result;
  });
  testWidgets(
    'Changes is reachable in the project panel and remembers its tab',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = ChangesFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProjectWorkspace(
                app: app,
                session: backend.session,
                active: true,
                builder: (_, _, _) => const Text('Terminal'),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('project-tab-changes')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('feature/example'), findsOneWidget);
        expect(
          app.layout.projectPanels[backend.session.key.id]!.active,
          'changes',
        );
        await app.setActive(false);
        await tester.pump();
        final count = backend.changeLists;
        await tester.pump(const Duration(seconds: 10));
        expect(backend.changeLists, count);
        await app.setActive(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(backend.changeLists, greaterThan(count));
        expect(backend.input, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  test('changes reject traversal, invalid groups, duplicate identities and oversized diffs', () {
    expect(
      GitChangePage.fromJson(changePage()).entries.first.path,
      'src/main.dart',
    );
    for (final fields in [
      {'path': '../private'},
      {'path': '/etc/private'},
      {'section': 'write'},
      {'status': 'X'},
    ]) {
      final page = changePage();
      page['entries'] = [
        {...(page['entries'] as List).first as Map, ...fields},
      ];
      expect(() => GitChangePage.fromJson(page), throwsFormatException);
    }
    final duplicate = changePage();
    duplicate['entries'] = List.filled(2, (duplicate['entries'] as List).first);
    expect(() => GitChangePage.fromJson(duplicate), throwsFormatException);
    expect(
      () => GitDiff.fromJson({
        'scope': 'a' * 64,
        'file': 'b' * 64,
        'text': 'x' * (256 * 1024 + 1),
        'notice': '',
      }),
      throwsFormatException,
    );
    expect(
      ProjectPanelLayout.fromJson({'active': 'changes'}).active,
      'changes',
    );
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'Changes list opens selectable read-only diff and returns in $brightness',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final backend = ChangesFixture();
        final app = AppController(
          snapshot: AppSnapshot(),
          store: WidgetStore(),
          backendFactory: (_) => backend,
        );
        try {
          await app.start(polling: false);
          app.select(backend.session.key.id);
          await tester.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(brightness),
              home: Scaffold(
                body: SessionChanges(
                  app: app,
                  session: backend.session,
                  active: true,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('feature/example'), findsOneWidget);
          expect(find.text('Staged · 1'), findsOneWidget);
          expect(find.text('Untracked · 1'), findsOneWidget);
          await tester.tap(find.text('main.dart'));
          await tester.pump();
          expect(find.byType(SelectableText), findsOneWidget);
          expect(find.textContaining('+new', findRichText: true), findsWidgets);
          await tester.tap(find.byTooltip('Back to changes'));
          await tester.pump();
          expect(find.text('README.md'), findsOneWidget);
          expect(backend.input, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
        }
      },
    );
  }
  testWidgets('hidden Changes stops polling and discards a late diff', (
    tester,
  ) async {
    final backend = ChangesFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    Widget view(bool active) => MaterialApp(
      home: Scaffold(
        body: SessionChanges(
          key: const ValueKey('changes'),
          app: app,
          session: backend.session,
          active: active,
        ),
      ),
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(view(true));
      await tester.pump();
      backend.diffHold = Completer<GitDiff>();
      await tester.tap(find.text('main.dart'));
      await tester.pump();
      await tester.pumpWidget(view(false));
      final count = backend.changeLists;
      backend.diffHold!.complete(
        GitDiff.fromJson({
          'scope': 'a' * 64,
          'file': 'b' * 64,
          'text': 'LATE PRIVATE DIFF',
          'notice': '',
        }),
      );
      await tester.pump(const Duration(seconds: 10));
      expect(backend.changeLists, count);
      expect(find.textContaining('LATE PRIVATE DIFF'), findsNothing);
      backend.diffHold = null;
      await tester.pumpWidget(view(true));
      await tester.pump();
      expect(backend.changeLists, greaterThan(count));
      expect(backend.input, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
}
