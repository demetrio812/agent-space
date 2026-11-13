import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/file_browser.dart';
import 'package:agentspace/src/session_file_browser.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/project_workspace.dart';
import 'package:agentspace/src/ui_common.dart';

import 'file_browser_test.dart' show browserPage;
import 'project_files_test.dart' show ProjectFixture;
import 'terminal_input_test.dart' show WidgetStore;

class BrowserFixture extends ProjectFixture implements FileBrowserBackend {
  final calls = <String>[];
  String? failPath;
  Completer<Map<String, dynamic>>? held;
  bool uploadHeld = false;
  @override
  Future<Map<String, dynamic>> fileBrowserRequest(
    SessionInfo session,
    String op,
    Map<String, dynamic> p,
  ) async {
    calls.add('$op:${p['path'] ?? ''}');
    if (op == 'fs.list') {
      if (p['path'] == failPath) throw StateError('denied');
      if (held != null) return held!.future;
      return browserPage(p['path'] == '' ? '/project' : p['path'] as String);
    }
    if (op == 'fs.begin') return {'token': 'b' * 32, 'offset': 0};
    if (op == 'fs.chunk') {
      if (uploadHeld) {
        held = Completer();
        return held!.future;
      }
      return {'offset': 1};
    }
    if (op == 'fs.finish') {
      return {
        'uploaded': true,
        'path': '/project/test.txt',
        'size': 1,
        'sha256': payloadDigest(Uint8List.fromList([65])),
      };
    }
    return {'cancelled': true};
  }
}

void main() {
  testWidgets(
    'Documents replaces curated Files and computer Files is a separate tab',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final backend = BrowserFixture();
      final controller = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      await controller.start(polling: false);
      controller.select(backend.session.key.id);
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(Brightness.dark),
            home: Scaffold(
              body: ProjectWorkspace(
                app: controller,
                session: backend.session,
                active: true,
                builder: (_, _, _) => const Text('Terminal'),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Documents'), findsOneWidget);
        expect(find.text('Specs'), findsOneWidget);
        expect(find.text('Files'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('project-tab-browser')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const ValueKey('browser-path')), findsOneWidget);
        expect(backend.calls, ['fs.list:']);
        expect(backend.input, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(controller.shutdown);
      }
    },
  );
  for (final width in [390.0, 300.0]) {
    testWidgets(
      'browse parent and session folders, keep correct location after failed navigation at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 650));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final backend = BrowserFixture(), store = WidgetStore();
        final app = AppController(
          snapshot: AppSnapshot(),
          store: store,
          backendFactory: (_) => backend,
        );
        await app.start(polling: false);
        app.select(backend.session.key.id);
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(Brightness.dark),
              home: Scaffold(
                body: SessionFileBrowser(
                  app: app,
                  session: backend.session,
                  active: true,
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('README.md'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('browser-entry-docs')));
          await tester.pump();
          expect(backend.calls.last, 'fs.list:/project/docs');
          backend.failPath = '/project';
          await tester.tap(find.byTooltip('Parent folder'));
          await tester.pump();
          expect(find.text('Could not open this folder.'), findsOneWidget);
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('browser-path')))
                .controller!
                .text,
            '/project/docs',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
        }
      },
    );
  }
  testWidgets('upload picker uses displayed folder without terminal input', (
    tester,
  ) async {
    final backend = BrowserFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
    app.select(backend.session.key.id);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionFileBrowser(
              app: app,
              session: backend.session,
              active: true,
              pickFiles: () async => [
                BrowserSource(
                  'test.txt',
                  () async => 1,
                  () async => Uint8List.fromList([65]),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Upload files'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.calls, contains('fs.begin:/project'));
      expect(backend.calls, contains('fs.finish:'));
      expect(
        find.text('Demo upload complete; no files were saved.'),
        findsOneWidget,
      );
      expect(backend.input, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
  testWidgets('cancel while preparing a file never starts transfer', (
    tester,
  ) async {
    final backend = BrowserFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
    app.select(backend.session.key.id);
    final bytes = Completer<Uint8List>();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionFileBrowser(
              app: app,
              session: backend.session,
              active: true,
              pickFiles: () async => [
                BrowserSource('test.txt', () async => 1, () => bytes.future),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Upload files'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      bytes.complete(Uint8List.fromList([65]));
      await tester.pump();
      expect(backend.calls.where((c) => c.startsWith('fs.begin')), isEmpty);
      expect(find.text('Upload cancelled.'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
  testWidgets('browser controls remain scrollable in a very short pane', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(300, 150));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final backend = BrowserFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
    app.select(backend.session.key.id);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionFileBrowser(
              app: app,
              session: backend.session,
              active: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
  testWidgets('background ignores late directory response', (tester) async {
    final backend = BrowserFixture();
    backend.held = Completer();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    await app.start(polling: false);
    app.select(backend.session.key.id);
    Widget browser(bool active) => MaterialApp(
      home: Scaffold(
        body: SessionFileBrowser(
          app: app,
          session: backend.session,
          active: active,
        ),
      ),
    );
    try {
      await tester.pumpWidget(browser(true));
      await tester.pumpWidget(browser(false));
      backend.held!.complete(browserPage('/stale'));
      await tester.pump();
      expect(find.text('/stale'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
}
