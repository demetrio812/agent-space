import 'dart:convert';

import 'models.dart';
import 'project_files.dart' show projectHash;

abstract interface class GitChangesBackend {
  Future<GitChangePage> listGitChanges(SessionInfo session);
  Future<GitDiff> readGitDiff(SessionInfo session, String scope, String file);
}

bool _hash(dynamic v) => v is String && projectHash.hasMatch(v);
bool _label(dynamic v, int max) =>
    v is String &&
    utf8.encode(v).length <= max &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(v);
bool _path(dynamic v, {bool empty = false}) =>
    _label(v, 2048) &&
    (empty && v == '' ||
        (v as String).isNotEmpty &&
            !v.startsWith('/') &&
            !v.contains('\\') &&
            !v.split('/').any((p) => p.isEmpty || p == '.' || p == '..'));

void validateChangesPayload(String op, Map<String, dynamic> payload) {
  if (op == 'changes.list' && payload.isEmpty) return;
  if (op == 'changes.read' &&
      payload.length == 2 &&
      _hash(payload['scope']) &&
      _hash(payload['file'])) {
    return;
  }
  throw ArgumentError('Invalid Git changes request.');
}

class GitChange {
  const GitChange({
    required this.id,
    required this.path,
    required this.oldPath,
    required this.section,
    required this.status,
  });
  final String id, path, oldPath, section, status;
  factory GitChange.fromJson(dynamic v) {
    if (v is! Map ||
        !_hash(v['id']) ||
        !_path(v['path']) ||
        !_path(v['oldPath'], empty: true) ||
        !const {'staged', 'unstaged', 'untracked'}.contains(v['section']) ||
        !const {'M', 'A', 'D', 'R', 'C', 'U', 'T', '?'}.contains(v['status'])) {
      throw const FormatException('Invalid Git change.');
    }
    return GitChange(
      id: v['id'],
      path: v['path'],
      oldPath: v['oldPath'],
      section: v['section'],
      status: v['status'],
    );
  }
  String get label => switch (status) {
    'A' => 'Added',
    'D' => 'Deleted',
    'R' => 'Renamed',
    'C' => 'Copied',
    'U' => 'Conflict',
    'T' => 'Type changed',
    '?' => 'Untracked',
    _ => 'Modified',
  };
}

class GitChangePage {
  const GitChangePage({
    required this.scope,
    required this.repository,
    required this.folder,
    required this.branch,
    required this.entries,
    required this.limited,
  });
  final String scope, folder, branch;
  final bool repository, limited;
  final List<GitChange> entries;
  factory GitChangePage.fromJson(Map<String, dynamic> v) {
    if (!_hash(v['scope']) ||
        v['repository'] is! bool ||
        !_label(v['folder'], 512) ||
        !_label(v['branch'], 1024) ||
        v['limited'] is! bool ||
        v['entries'] is! List ||
        (v['entries'] as List).length > 500 ||
        utf8.encode(jsonEncode(v)).length > 1024 * 1024) {
      throw const FormatException('Invalid Git changes list.');
    }
    final entries = (v['entries'] as List).map(GitChange.fromJson).toList();
    if (entries.map((e) => e.id).toSet().length != entries.length ||
        v['repository'] == false && entries.isNotEmpty) {
      throw const FormatException('Invalid Git changes list.');
    }
    return GitChangePage(
      scope: v['scope'],
      repository: v['repository'],
      folder: v['folder'],
      branch: v['branch'],
      entries: List.unmodifiable(entries),
      limited: v['limited'],
    );
  }
}

class GitDiff {
  const GitDiff({
    required this.scope,
    required this.file,
    required this.text,
    required this.notice,
  });
  final String scope, file, text, notice;
  factory GitDiff.fromJson(Map<String, dynamic> v) {
    if (!_hash(v['scope']) ||
        !_hash(v['file']) ||
        v['text'] is! String ||
        utf8.encode(v['text'] as String).length > 256 * 1024 ||
        !_label(v['notice'], 512)) {
      throw const FormatException('Invalid Git diff.');
    }
    return GitDiff(
      scope: v['scope'],
      file: v['file'],
      text: v['text'],
      notice: v['notice'],
    );
  }
}
