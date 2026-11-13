import 'dart:convert';

import 'models.dart';

final projectHash = RegExp(r'^[0-9a-f]{64}$');
bool _hash(dynamic value) => value is String && projectHash.hasMatch(value);
bool _label(dynamic value, int limit) =>
    value is String &&
    value.isNotEmpty &&
    utf8.encode(value).length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);

abstract interface class ProjectFilesBackend {
  Future<ProjectManifest> listProjectFiles(SessionInfo session);
  Future<ProjectDocument> readProjectFile(
    SessionInfo session,
    String scope,
    String file,
  );
}

void validateProjectPayload(String op, Map<String, dynamic> value) {
  if (op == 'files.list' && value.isEmpty) return;
  if (op == 'files.read' &&
      value.length == 2 &&
      _hash(value['scope']) &&
      _hash(value['file'])) {
    return;
  }
  throw ArgumentError('Invalid project document request.');
}

class ProjectFile {
  const ProjectFile({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    required this.section,
    required this.feature,
    required this.revision,
  });
  final String id, name, path, kind, section, feature, revision;
  static ProjectFile fromJson(dynamic value) {
    if (value is! Map ||
        !_hash(value['id']) ||
        !_hash(value['revision']) ||
        !_label(value['name'], 512) ||
        !_label(value['path'], 2048) ||
        (value['path'] as String).startsWith('/') ||
        (value['path'] as String).contains('\\') ||
        (value['path'] as String)
            .split('/')
            .any((p) => p.isEmpty || p == '.' || p == '..') ||
        !const {'markdown', 'html'}.contains(value['kind']) ||
        !const {'files', 'specs'}.contains(value['section']) ||
        value['feature'] is! String ||
        (value['feature'] != '' && !_label(value['feature'], 512)) ||
        (value['section'] == 'specs' &&
            (value['kind'] != 'markdown' || value['feature'] == ''))) {
      throw const FormatException('Invalid project document.');
    }
    return ProjectFile(
      id: value['id'],
      name: value['name'],
      path: value['path'],
      kind: value['kind'],
      section: value['section'],
      feature: value['feature'],
      revision: value['revision'],
    );
  }
}

class ProjectManifest {
  const ProjectManifest({
    required this.scope,
    required this.folder,
    required this.files,
    required this.limited,
  });
  final String scope, folder;
  final List<ProjectFile> files;
  final bool limited;
  ProjectFile? file(String id) {
    for (final f in files) {
      if (f.id == id) return f;
    }
    return null;
  }

  static ProjectManifest fromJson(Map<String, dynamic> value) {
    if (!_hash(value['scope']) ||
        !_label(value['folder'], 512) ||
        value['limited'] is! bool ||
        value['files'] is! List ||
        (value['files'] as List).length > 128 ||
        utf8.encode(jsonEncode(value)).length > 1024 * 1024) {
      throw const FormatException('Invalid project file list.');
    }
    final files = (value['files'] as List).map(ProjectFile.fromJson).toList();
    if (files.map((f) => f.id).toSet().length != files.length) {
      throw const FormatException('Duplicate project document.');
    }
    return ProjectManifest(
      scope: value['scope'],
      folder: value['folder'],
      files: List.unmodifiable(files),
      limited: value['limited'],
    );
  }
}

class ProjectDocument {
  const ProjectDocument({
    required this.scope,
    required this.file,
    required this.revision,
    required this.text,
  });
  final String scope, file, revision, text;
  static ProjectDocument fromJson(Map<String, dynamic> value) {
    if (!_hash(value['scope']) ||
        !_hash(value['file']) ||
        !_hash(value['revision']) ||
        value['text'] is! String ||
        utf8.encode(value['text'] as String).length > 256 * 1024 ||
        utf8.encode(jsonEncode(value)).length > 1024 * 1024) {
      throw const FormatException('Invalid project document content.');
    }
    return ProjectDocument(
      scope: value['scope'],
      file: value['file'],
      revision: value['revision'],
      text: value['text'],
    );
  }
}

/// Preferences only. Document text belongs to the visible panel's memory.
class ProjectPanelLayout {
  ProjectPanelLayout({
    this.visible = false,
    this.width = 420,
    this.scope = '',
    List<String>? opened,
    this.active = 'files',
  }) : opened = opened ?? [];
  bool visible;
  double width;
  String scope, active;
  final List<String> opened;
  Map<String, dynamic> toJson() => {
    'visible': visible,
    'width': width,
    'scope': scope,
    'opened': opened.take(8).toList(),
    'active': active,
  };
  static ProjectPanelLayout fromJson(dynamic value) {
    if (value is! Map) return ProjectPanelLayout();
    final opened = (value['opened'] is List
        ? (value['opened'] as List)
              .whereType<String>()
              .where(_hash)
              .toSet()
              .take(8)
              .toList()
        : <String>[]);
    final active = value['active'];
    return ProjectPanelLayout(
      visible: value['visible'] == true,
      width: value['width'] is num && (value['width'] as num).isFinite
          ? (value['width'] as num).toDouble().clamp(300, 700)
          : 420,
      scope: _hash(value['scope']) ? value['scope'] : '',
      opened: opened,
      active:
          const ['files', 'specs'].contains(active) || opened.contains(active)
          ? active
          : 'files',
    );
  }
}
