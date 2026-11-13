import 'dart:io';

import 'package:agentspace/src/project_files.dart';
import 'package:agentspace/src/file_browser.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'image_attachments_test.dart' show AttachmentFixture, png;
import 'project_files_test.dart' show ProjectFixture, fileScope;
import 'session_file_browser_test.dart' show BrowserFixture;
import 'terminal_input_test.dart' show WidgetStore;

class CombinedDropFixture extends AttachmentFixture
    implements ProjectFilesBackend, FileBrowserBackend {
  final docs = ProjectFixture(), files = BrowserFixture();
  @override
  Future<ProjectManifest> listProjectFiles(SessionInfo s) =>
      docs.listProjectFiles(s);
  @override
  Future<ProjectDocument> readProjectFile(
    SessionInfo s,
    String scope,
    String file,
  ) => docs.readProjectFile(s, scope, file);
  @override
  Future<Map<String, dynamic>> fileBrowserRequest(
    SessionInfo s,
    String op,
    Map<String, dynamic> p,
  ) => files.fileBrowserRequest(s, op, p);
}

void main() {
  testWidgets(
    'raw Finder image drop on narrow Files never reaches covered terminal',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.binding.setSurfaceSize(const Size(390, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final b = CombinedDropFixture(), snapshot = AppSnapshot();
      snapshot
          .layoutFor('demo')
          .projectPanels[b.session.key.id] = ProjectPanelLayout(
        visible: true,
        scope: fileScope,
        active: 'browser',
      );
      final app = AppController(
        snapshot: snapshot,
        store: WidgetStore(),
        backendFactory: (_) => b,
      );
      await app.start(polling: false);
      app.select(b.session.key.id);
      final folder = Directory.systemTemp.createTempSync('ag-browser-drop-');
      final file = File('${folder.path}/file.png')..writeAsBytesSync(png);
      const codec = StandardMethodCodec();
      Future<void> event(String method, Object args) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'desktop_drop',
          codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalPane(app: app, session: b.session, compact: true),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('project-tab-browser')),
        );
        await tester.tap(find.byKey(const ValueKey('project-tab-browser')));
        await tester.pump();
        final point = tester.getCenter(
          find.byKey(const ValueKey('browser-entry-README.md')),
        );
        await event('entered', [point.dx, point.dy]);
        await event('performOperation_macos', [
          {'path': file.path, 'isDirectory': false},
        ]);
        for (
          var i = 0;
          i < 100 && !b.files.calls.any((c) => c.startsWith('fs.begin'));
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(b.uploads, 0);
        expect(b.input, isEmpty);
        expect(b.files.calls, contains('fs.begin:/project'));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
        folder.deleteSync(recursive: true);
        debugDefaultTargetPlatformOverride=null;
      }
    },
  );
}
