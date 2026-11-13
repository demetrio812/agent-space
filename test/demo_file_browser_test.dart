import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/demo_backend.dart';
import 'package:agentspace/src/file_browser.dart';

void main() {
  test('Demo collisions preserve listing and uploaded documents preview their own text', () async {
    final backend = DemoBackend();
    final session = (await backend.listSessions()).first;
    final page = BrowserPage.fromJson(
      await backend.fileBrowserRequest(session, 'fs.list', {'path': ''}),
    );
    final upload = BrowserUpload(
      (op, p) => backend.fileBrowserRequest(session, op, p),
    );
    await expectLater(
      upload.upload(page, 'README.md', Uint8List(0), onProgress: (_, _) {}),
      throwsA(isA<FileRequestRejected>()),
    );
    final bytes = Uint8List.fromList('# Uploaded content'.codeUnits);
    await BrowserUpload((op, p) => backend.fileBrowserRequest(session, op, p))
        .upload(page, 'new.md', bytes, onProgress: (_, _) {});
    final updated = BrowserPage.fromJson(
      await backend.fileBrowserRequest(session, 'fs.list', {'path': page.path}),
    );
    final entry = updated.entries.firstWhere((e) => e.name == 'new.md');
    final preview = BrowserPreview.fromJson(
      await backend.fileBrowserRequest(session, 'fs.read', {
        'path': updated.path,
        'scope': updated.scope,
        'name': entry.name,
        'revision': entry.revision,
      }),
      updated,
      entry,
    );
    expect(preview.document.text, '# Uploaded content');
    final root = BrowserPage.fromJson(
      await backend.fileBrowserRequest(session, 'fs.list', {'path': '/'}),
    );
    expect(
      await BrowserUpload((op, p) => backend.fileBrowserRequest(session, op, p))
          .upload(root, 'root.txt', Uint8List(0), onProgress: (_, _) {}),
      '/root.txt',
    );
    await backend.close();
  });
}
