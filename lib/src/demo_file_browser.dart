import 'dart:convert';
import 'dart:typed_data';

import 'backend_errors.dart';
import 'file_browser.dart';
import 'models.dart';
import 'project_files.dart';

/// Disposable in-memory files; Demo never writes to the host filesystem.
class DemoFileBrowser {
  DemoFileBrowser(this.list, this.read);
  final Future<ProjectManifest> Function(SessionInfo) list;
  final Future<ProjectDocument> Function(SessionInfo, String, String) read;
  final saved = <String, Map<String, Uint8List>>{},
      pending = <String, Map<String, dynamic>>{};
  int counter = 0;
  static const project = '/home/demo/projects/orbit-api';
  String _scope(String path) =>
      payloadDigest(Uint8List.fromList(utf8.encode(path)));
  String _child(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';
  Future<Map<String, (String, Uint8List)>> _entries(
    SessionInfo session,
    String path,
  ) async {
    final result = <String, (String, Uint8List)>{};
    void directory(String name) => result[name] = ('directory', Uint8List(0));
    void file(String name, String text) =>
        result[name] = ('file', Uint8List.fromList(utf8.encode(text)));
    final manifest = await list(session);
    if (path == project) {
      directory('docs');
      directory('.kiro');
      for (final f in manifest.files.where((f) => f.section == 'files')) {
        file(f.name, (await read(session, manifest.scope, f.id)).text);
      }
    } else if (path == '$project/docs') {
      file(
        'guide.md',
        '# Orbit guides\n\nDocumentation for the Orbit project.',
      );
    } else if (path == '$project/.kiro') {
      directory('specs');
    } else if (path == '$project/.kiro/specs') {
      for (final f in manifest.files.where((f) => f.section == 'specs')) {
        directory(f.feature);
      }
    } else if (path.startsWith('$project/.kiro/specs/')) {
      final feature = path.substring('$project/.kiro/specs/'.length);
      for (final f in manifest.files.where(
        (f) => f.section == 'specs' && f.feature == feature,
      )) {
        file(f.name, (await read(session, manifest.scope, f.id)).text);
      }
    } else if (path == '/') {
      directory('home');
    } else if (path == '/home') {
      directory('demo');
    } else if (path == '/home/demo') {
      directory('projects');
      directory('Downloads');
    } else if (path == '/home/demo/projects') {
      directory('orbit-api');
    } else if (path != '/home/demo/Downloads') {
      throw SessionUnavailable('This Demo folder does not exist.');
    }
    for (final e in (saved[path] ?? <String, Uint8List>{}).entries) {
      result[e.key] = ('file', e.value);
    }
    return result;
  }

  Future<Map<String, dynamic>> request(
    SessionInfo session,
    String op,
    Map<String, dynamic> p,
  ) async {
    validateBrowserPayload(op, p);
    if (op == 'fs.list' || op == 'fs.read' || op == 'fs.begin') {
      final raw = p['path'] as String;
      final path = Uri(
        path: raw == ''
            ? project
            : raw == '~'
            ? '/home/demo'
            : raw,
      ).normalizePath().path.replaceAll(RegExp(r'/+$'), '');
      final canonical = path.isEmpty ? '/' : path,
          scope = _scope(path.isEmpty ? '/' : path);
      final entries = await _entries(session, canonical);
      if (op == 'fs.list') {
        return {
          'path': canonical,
          'home': '/home/demo',
          'scope': scope,
          'limited': false,
          'entries': [
            for (final e in entries.entries)
              {
                'name': e.key,
                'kind': e.value.$1,
                'size': e.value.$2.length,
                'revision': payloadDigest(e.value.$2),
              },
          ],
        };
      }
      if (p['scope'] != scope) {
        throw FileRequestRejected('The Demo folder changed.');
      }
      if (op == 'fs.read') {
        final name = p['name'] as String, entry = entries[name];
        if (entry == null ||
            entry.$1 != 'file' ||
            payloadDigest(entry.$2) != p['revision']) {
          throw FileRequestRejected('The Demo file changed.');
        }
        if (entry.$2.length > 256 * 1024) {
          throw FileRequestRejected(
            'This document exceeds the 256 KiB preview limit.',
          );
        }
        String text;
        try {
          text = utf8.decode(entry.$2);
        } on FormatException {
          throw FileRequestRejected('This document is not UTF-8 text.');
        }
        final id = _scope('$scope/$name'),
            kind = RegExp(r'\.(html|htm)$', caseSensitive: false).hasMatch(name)
                ? 'html'
                : 'markdown';
        return {
          'file': {
            'id': id,
            'name': name,
            'path': name,
            'kind': kind,
            'section': 'files',
            'feature': '',
            'revision': p['revision'],
          },
          'document': {
            'scope': scope,
            'file': id,
            'revision': p['revision'],
            'text': text,
          },
        };
      }
      if (entries.containsKey(p['name'])) {
        throw FileRequestRejected('A file with this name already exists.');
      }
      final used =
          saved.values
              .expand((m) => m.values)
              .fold<int>(0, (n, b) => n + b.length) +
          pending.values.fold<int>(0, (n, m) => n + (m['size'] as int));
      if (pending.length >= 4 || used + (p['size'] as int) > 64 * 1024 * 1024) {
        throw FileRequestRejected('Demo file storage is full.');
      }
      final token = (++counter).toRadixString(16).padLeft(32, '0');
      pending[token] = {
        ...p,
        'path': canonical,
        'bytes': BytesBuilder(copy: false),
        'session': session.key.id,
      };
      return {'token': token, 'offset': 0};
    }
    final token = p['token'], item = pending[token];
    if (item != null && item['session'] != session.key.id) {
      throw SessionUnavailable();
    }
    if (op == 'fs.cancel') {
      pending.remove(token);
      return {'cancelled': true};
    }
    if (item == null) throw SessionUnavailable();
    final bytes = item['bytes'] as BytesBuilder;
    if (op == 'fs.chunk') {
      final chunk = base64Decode(p['bytes'] as String);
      if (bytes.length != p['offset'] ||
          bytes.length + chunk.length > (item['size'] as int)) {
        pending.remove(token);
        throw FileRequestRejected('Invalid Demo upload.');
      }
      bytes.add(chunk);
      return {'offset': bytes.length};
    }
    pending.remove(token);
    final data = bytes.takeBytes();
    if (data.length != item['size'] || payloadDigest(data) != item['sha256']) {
      throw FileRequestRejected('Demo upload verification failed.');
    }
    final path = item['path'] as String, name = item['name'] as String;
    if ((await _entries(session, path)).containsKey(name)) {
      throw FileRequestRejected('A file with this name already exists.');
    }
    (saved[path] ??= <String, Uint8List>{})[name] = data;
    return {
      'uploaded': true,
      'path': _child(path, name),
      'size': data.length,
      'sha256': item['sha256'],
    };
  }

  void close() {
    pending.clear();
    saved.clear();
  }
}
