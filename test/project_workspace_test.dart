import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
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
}
