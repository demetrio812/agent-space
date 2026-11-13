import 'package:agentspace/src/backend.dart';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/project_files.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/storage.dart';

import 'terminal_input_test.dart' show InputFixture, WidgetStore;

final fileScope = 'a' * 64,
    readmeId = 'b' * 64,
    htmlId = 'c' * 64,
    taskId = 'd' * 64;
Map<String, dynamic> fileEntry(
  String id,
  String name, {
  String section = 'files',
  String feature = '',
  String? path,
}) => {
  'id': id,
  'name': name,
  'path': path ?? name,
  'kind': name.endsWith('.html') ? 'html' : 'markdown',
  'section': section,
  'feature': feature,
  'revision': 'e' * 64,
};
Map<String, dynamic> projectManifest() => {
  'scope': fileScope,
  'folder': 'fixture',
  'limited': false,
  'files': [
    fileEntry(readmeId, 'README.md'),
    fileEntry(htmlId, 'preview.html'),
    fileEntry(
      taskId,
      'tasks.md',
      section: 'specs',
      feature: 'invites',
      path: '.kiro/specs/invites/tasks.md',
    ),
  ],
};

class ProjectFixture extends InputFixture implements ProjectFilesBackend {
  int lists = 0, reads = 0;
  bool failReads = false;
  Completer<ProjectManifest>? manifestHold;
  Map<String, dynamic> manifest = projectManifest();
  final texts = <String, String>{};
  @override
  Future<ProjectManifest> listProjectFiles(SessionInfo session) async {
    lists++;
    return manifestHold == null
        ? ProjectManifest.fromJson(manifest)
        : await manifestHold!.future;
  }

  @override
  Future<ProjectDocument> readProjectFile(
    SessionInfo session,
    String scope,
    String file,
  ) async {
    reads++;
    if (failReads) {
      throw SessionUnavailable('This document exceeds the preview limit.');
    }
    if (scope != fileScope) throw StateError('Wrong scope');
    return ProjectDocument.fromJson({
      'scope': scope,
      'file': file,
      'revision': 'e' * 64,
      'text': texts[file] ?? '# Complete document\n\n- [x] done\n- [ ] next',
    });
  }
}

void main() {
  test('manifest rejects paths, duplicate IDs and unbounded collections', () {
    final page = ProjectManifest.fromJson(projectManifest());
    expect(
      page.files.where((f) => f.section == 'specs').single.feature,
      'invites',
    );
    for (final bad in [
      {...projectManifest(), 'scope': '../../private'},
      {
        ...projectManifest(),
        'files': [fileEntry(readmeId, 'README.md', path: '/etc/private.md')],
      },
      {
        ...projectManifest(),
        'files': [
          fileEntry(readmeId, 'README.md'),
          fileEntry(readmeId, 'other.md'),
        ],
      },
      {
        ...projectManifest(),
        'files': List.filled(129, fileEntry(readmeId, 'README.md')),
      },
    ]) {
      expect(() => ProjectManifest.fromJson(bad), throwsFormatException);
    }
  });
  test('document validates exact identity and full UTF-8 bounds', () {
    final json = {
      'scope': fileScope,
      'file': readmeId,
      'revision': 'e' * 64,
      'text': '# café',
    };
    expect(ProjectDocument.fromJson(json).text, '# café');
    expect(
      () => ProjectDocument.fromJson({...json, 'text': 'x' * (256 * 1024 + 1)}),
      throwsFormatException,
    );
    expect(
      () => ProjectDocument.fromJson({...json, 'file': '../secret'}),
      throwsFormatException,
    );
  });
  test('panel preferences roundtrip without document contents', () {
    final layout = WorkspaceLayout();
    final key = const SessionKey('demo', 'demo', 'server', 't1').id;
    layout.projectPanels[key] = ProjectPanelLayout(
      visible: true,
      width: 510,
      scope: fileScope,
      opened: [readmeId],
      active: readmeId,
    );
    final json = layout.toJson();
    final restored = WorkspaceLayout.fromJson(json).projectPanels[key]!;
    expect(restored.visible, isTrue);
    expect(restored.width, 510);
    expect(restored.opened, [readmeId]);
    expect(restored.active, readmeId);
    expect(json.toString(), isNot(contains('Complete document')));
  });
  test('file reads reject replies after the connection is replaced', () async {
    final backend = ProjectFixture()
      ..manifestHold = Completer<ProjectManifest>();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    addTearDown(app.shutdown);
    await app.start(polling: false);
    app.select(backend.session.key.id);
    final result = expectLater(
      app.listProjectFiles(backend.session),
      throwsA(isA<Exception>()),
    );
    await app.reconnect();
    backend.manifestHold!.complete(ProjectManifest.fromJson(projectManifest()));
    await result;
  });
}
