import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart' show TerminalView;
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/project_files.dart';

import 'conversation_test.dart' show ChatFixture, chatPage, chatSid;

import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/project_workspace.dart';
import 'package:agentspace/src/project_file_viewer.dart';
import 'package:agentspace/src/ui_common.dart';

import 'project_files_test.dart';
import 'terminal_input_test.dart' show WidgetStore;

Widget workspace(
  AppController app,
  ProjectFixture backend, {
  Brightness brightness = Brightness.dark,
  Key? key,
}) => MaterialApp(
  theme: workspaceTheme(brightness),
  home: Scaffold(
    body: ProjectWorkspace(
      key: key,
      app: app,
      session: backend.session,
      active: true,
      builder: (toggle, visible, covered) => Column(
        children: [
          TextButton(
            onPressed: toggle,
            child: const Text('Toggle project files'),
          ),
          const Expanded(child: Center(child: Text('Terminal'))),
        ],
      ),
    ),
  ),
);

class ChatFilesFixture extends ChatFixture implements ProjectFilesBackend {
  final files = ProjectFixture();
  @override
  SessionInfo get session => const SessionInfo(
    key: SessionKey('demo', 'demo', 'server', 't1'),
    paneId: 'p1',
    title: 'Claude fixture',
    project: 'fixture',
    agent: 'claude',
    status: SessionStatus.idle,
    inputEnabled: true,
    terminalInputEnabled: true,
  );
  @override
  Future<ProjectManifest> listProjectFiles(SessionInfo s) =>
      files.listProjectFiles(s);
  @override
  Future<ProjectDocument> readProjectFile(
    SessionInfo s,
    String scope,
    String file,
  ) => files.readProjectFile(s, scope, file);
}

class PanelCountingStore extends WidgetStore {
  int writes = 0;
  @override
  Future<void> save(AppSnapshot value) async {
    writes++;
  }
}

void main() {
  testWidgets(
    'Files and Specs stay separate while document tabs are deduplicated and closable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = ProjectFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(workspace(app, backend));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('README.md'), findsOneWidget);
        expect(find.text('invites'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('project-tab-specs')));
        await tester.pump();
        expect(find.text('README.md'), findsNothing);
        expect(find.text('invites'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('project-file-$taskId')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Complete document'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('project-tab-specs')));
        await tester.pump();
        await tester.tap(find.byKey(ValueKey('project-file-$taskId')));
        await tester.pump();
        expect(find.byKey(ValueKey('project-tab-$taskId')), findsOneWidget);
        expect(backend.reads, 1);
        await tester.tap(find.byTooltip('Close tasks.md'));
        await tester.pump();
        expect(find.text('invites'), findsOneWidget);
        expect(find.byKey(ValueKey('project-tab-$taskId')), findsNothing);
        expect(backend.input, isEmpty);
        expect(backend.composedCalls, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  for (final size in [const Size(390, 600), const Size(844, 390)]) {
    testWidgets(
      'closing the narrow panel persists and stops discovery at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final backend = ProjectFixture();
        final app = AppController(
          snapshot: AppSnapshot(),
          store: WidgetStore(),
          backendFactory: (_) => backend,
        );
        try {
          await app.start(polling: false);
          app.select(backend.session.key.id);
          await tester.pumpWidget(
            workspace(app, backend, brightness: Brightness.light),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.byTooltip('Back to session'));
          await tester.pump();
          final calls = backend.lists;
          await tester.pump(const Duration(seconds: 20));
          expect(backend.lists, calls);
          await tester.pumpWidget(
            workspace(app, backend, key: const ValueKey('recreated')),
          );
          await tester.pump(const Duration(seconds: 6));
          expect(find.text('README.md'), findsNothing);
          expect(backend.lists, calls);
          await tester.tap(find.text('Toggle project files'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('README.md'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
        }
      },
    );
  }
  testWidgets(
    'backgrounded panels stop refreshing and reject obsolete content',
    (tester) async {
      final backend = ProjectFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(workspace(app, backend));
        await tester.pump(const Duration(milliseconds: 300));
        final calls = backend.lists;
        await app.setActive(false);
        await tester.pump(const Duration(seconds: 15));
        expect(backend.lists, calls);
        await app.setActive(true);
        await tester.pump(const Duration(milliseconds: 300));
        expect(backend.lists, calls + 1);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  test('HTML preview restricts resources before untrusted markup and disables navigation', () {
    final html = prepareProjectHtml(
      '<script>fetch("https://example.com")</script><h1>Preview</h1>',
    );
    expect(
      html.indexOf('Content-Security-Policy'),
      lessThan(html.indexOf('<script>')),
    );
    expect(html, contains("default-src 'none'"));
    expect(html, contains("script-src 'none'"));
    expect(html, contains("form-action 'none'"));
    expect(projectPreviewNavigationAllowed('https://example.com'), isFalse);
    expect(projectPreviewNavigationAllowed('file:///etc/private'), isFalse);
  });
  testWidgets('a narrow file overlay blocks app-wide Send until closed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = ProjectFixture()..allowComposed = true;
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      app.updateDraft(backend.session.key.id, 'retained message');
      await tester.pumpWidget(workspace(app, backend));
      await tester.pump(const Duration(milliseconds: 300));
      expect(await app.sendDraft(backend.session.key.id), isFalse);
      expect(backend.composedCalls, 0);
      await tester.tap(find.byTooltip('Back to session'));
      await tester.pump();
      expect(await app.sendDraft(backend.session.key.id), isTrue);
      expect(backend.composedCalls, 1);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
  testWidgets('file lists remain usable in a very short pane', (tester) async {
    await tester.binding.setSurfaceSize(const Size(844, 210));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = ProjectFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(workspace(app, backend));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
  testWidgets(
    'Files toggles preserve the pinned Chat conversation and its draft',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = ChatFilesFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.layout.projectPanels[backend.session.key.id] = ProjectPanelLayout(
          visible: false,
        );
        app.updateDraft(backend.session.key.id, 'original draft');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalPane(
                app: app,
                session: backend.session,
                compact: false,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byTooltip('Chat view (experimental)'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(backend.expectedSessions, ['']);
        backend.page = {
          ...chatPage(),
          'session': '44444444-4444-4444-8444-444444444444',
        };
        await tester.tap(find.byTooltip('Show project files'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 2));
        expect(backend.expectedSessions.skip(1), everyElement(chatSid));
        await tester.tap(find.byTooltip('Close project files'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(backend.expectedSessions.skip(1), everyElement(chatSid));
        expect(app.layout.drafts[backend.session.key.id], 'original draft');
        expect(backend.chatSends, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );

  testWidgets(
    'passive panel clicks and explicit opening take keyboard ownership',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = ProjectFixture()..allowComposed = true;
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
              body: TerminalPane(
                app: app,
                session: backend.session,
                compact: false,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byType(TerminalView));
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          tester
              .widget<TerminalView>(find.byType(TerminalView))
              .focusNode!
              .hasFocus,
          isTrue,
        );
        await tester.tap(find.text('Project files'));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 100));
        expect(backend.input, isEmpty);
        await tester.tap(find.byTooltip('Close project files'));
        await tester.pump();
        await tester.tap(find.byTooltip('Show project files'));
        await tester.pump();
        app.updateDraft(backend.session.key.id, 'kept draft');
        expect(await app.sendDraft(backend.session.key.id), isFalse);
        expect(backend.composedCalls, 0);
        await tester.tap(find.byType(TerminalView));
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 350));
        expect(backend.input.length, 1);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  test('task progress handles long blank runs without quadratic work', () {
    final text = '- [x] done\n- [ ] next\n${'\n' * 16000}';
    final watch = Stopwatch()..start();
    expect(projectTaskProgress(text), (1, 2));
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(500));
  });
  testWidgets(
    'rebinding a terminal to a new pane clears the previous document immediately',
    (tester) async {
      final backend = ProjectFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      Widget view(SessionInfo session) => MaterialApp(
        home: Scaffold(
          body: ProjectWorkspace(
            app: app,
            session: session,
            active: true,
            builder: (_, _, _) => const SizedBox.expand(),
          ),
        ),
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(view(backend.session));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(ValueKey('project-file-$readmeId')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Complete document'), findsOneWidget);
        final changed = SessionInfo(
          key: backend.session.key,
          paneId: 'p2',
          title: 'New pane',
          project: 'fixture',
          agent: 'fixture',
          status: SessionStatus.idle,
        );
        await tester.pumpWidget(view(changed));
        await tester.pump();
        expect(find.text('Complete document'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  testWidgets(
    'a failed reread clearly labels retained text as the last readable version',
    (tester) async {
      final backend = ProjectFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(workspace(app, backend));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(ValueKey('project-file-$readmeId')));
        await tester.pump(const Duration(milliseconds: 100));
        backend.failReads = true;
        backend.manifest = {
          ...projectManifest(),
          'files': [fileEntry(readmeId, 'README.md')..['revision'] = 'f' * 64],
        };
        await tester.pump(const Duration(seconds: 6));
        expect(find.text('Complete document'), findsOneWidget);
        expect(find.textContaining('last readable version'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );

  testWidgets('unchanged visible refreshes do not rewrite saved preferences', (
    tester,
  ) async {
    final backend = ProjectFixture(), store = PanelCountingStore();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: store,
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(workspace(app, backend));
      await tester.pump(const Duration(seconds: 1));
      final writes = store.writes;
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      expect(backend.lists, greaterThan(1));
      expect(store.writes, writes);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
}
