import 'backend_errors.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'project_files.dart';

const maxUploadBytes = 32 * 1024 * 1024;
typedef BrowserRequest = Future<Map<String, dynamic>> Function(
  String op,
  Map<String, dynamic> payload,
);

abstract interface class FileBrowserBackend {
  Future<Map<String, dynamic>> fileBrowserRequest(
    SessionInfo session,
    String op,
    Map<String, dynamic> payload,
  );
}

bool browserName(Object? name) =>
    name is String &&
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains('\\') &&
    utf8.encode(name).length <= 255 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(name);
bool browserPath(Object? path, {bool initial = false}) =>
    path is String &&
    (path.startsWith('/') || initial && {'', '~'}.contains(path)) &&
    utf8.encode(path).length <= 4096 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(path);
bool _hash(Object? value) => value is String && projectHash.hasMatch(value);
bool browserFolderName(Object? value) =>
    browserName(value) &&
    (value as String).trim().isNotEmpty &&
    !value.startsWith('.agentspace-upload-');
String payloadDigest(Uint8List bytes) => sha256.convert(bytes).toString();
void validateBrowserPayload(String op, Map<String, dynamic> p) {
  final fields = switch (op) {
    'fs.list' => {'path'},
    'fs.download' => {'path', 'scope', 'name', 'revision', 'offset'},
    'fs.mkdir' => {'path', 'scope', 'name'},
    'fs.read' => {'path', 'scope', 'name', 'revision'},
    'fs.begin' => {'path', 'scope', 'name', 'size', 'sha256'},
    'fs.chunk' => {'token', 'offset', 'bytes'},
    'fs.finish' || 'fs.cancel' => {'token'},
    _ => throw ArgumentError('Unsupported file action.'),
  };
  bool bad() => p.length != fields.length || !fields.every(p.containsKey);
  if (bad()) throw ArgumentError('Invalid file request.');
  if ({
    'fs.list',
    'fs.read',
    'fs.begin',
    'fs.mkdir',
    'fs.download',
  }.contains(op)) {
    if (!browserPath(p['path'], initial: op == 'fs.list')) {
      throw ArgumentError('Choose an absolute folder path.');
    }
    if (op != 'fs.list' && (!browserName(p['name']) || !_hash(p['scope']))) {
      throw ArgumentError('Invalid file destination.');
    }
    if (op == 'fs.mkdir' && !browserFolderName(p['name'])) {
      throw ArgumentError('Choose a folder name without slashes.');
    }
    if ((op == 'fs.read' || op == 'fs.download') && !_hash(p['revision'])) {
      throw ArgumentError('Invalid file revision.');
    }
    if (op == 'fs.download' &&
        (p['offset'] is! int ||
            p['offset'] < 0 ||
            p['offset'] > maxUploadBytes)) {
      throw ArgumentError('Invalid download offset.');
    }
    if (op == 'fs.begin' &&
        (p['size'] is! int ||
            p['size'] < 0 ||
            p['size'] > maxUploadBytes ||
            !_hash(p['sha256']))) {
      throw ArgumentError('Choose files up to 32 MiB each.');
    }
  } else {
    if (p['token'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(p['token'] as String)) {
      throw ArgumentError('Invalid upload token.');
    }
    if (op == 'fs.chunk') {
      if (p['offset'] is! int ||
          p['offset'] < 0 ||
          p['offset'] > maxUploadBytes ||
          p['bytes'] is! String ||
          (p['bytes'] as String).length > 349528) {
        throw ArgumentError('Invalid upload chunk.');
      }
      try {
        final bytes = base64Decode(p['bytes'] as String);
        if (bytes.isEmpty ||
            bytes.length > 262144 ||
            base64Encode(bytes) != p['bytes']) {
          throw const FormatException();
        }
      } on FormatException {
        throw ArgumentError('Invalid upload chunk.');
      }
    }
  }
}

class BrowserEntry {
  const BrowserEntry(this.name, this.kind, this.size, this.revision);
  final String name, kind, revision;
  final int size;
  bool get previewable =>
      kind == 'file' &&
      RegExp(r'\.(md|markdown|html|htm)$', caseSensitive: false).hasMatch(name);
  static BrowserEntry fromJson(dynamic p) {
    if (p is! Map ||
        !browserName(p['name']) ||
        !{'directory', 'file', 'link', 'other'}.contains(p['kind']) ||
        p['size'] is! int ||
        p['size'] < 0 ||
        p['size'] > 9007199254740991 ||
        !_hash(p['revision'])) {
      throw const FormatException('Invalid folder entry.');
    }
    return BrowserEntry(p['name'], p['kind'], p['size'], p['revision']);
  }
}

class BrowserPage {
  const BrowserPage(
    this.path,
    this.home,
    this.scope,
    this.entries,
    this.limited,
  );
  final String path, home, scope;
  final List<BrowserEntry> entries;
  final bool limited;
  static BrowserPage fromJson(Map<String, dynamic> p) {
    if (!browserPath(p['path']) ||
        !browserPath(p['home']) ||
        !_hash(p['scope']) ||
        p['entries'] is! List ||
        (p['entries'] as List).length > 1000 ||
        p['limited'] is! bool ||
        utf8.encode(jsonEncode(p)).length > 512 * 1024) {
      throw const FormatException('Invalid folder list.');
    }
    final entries = (p['entries'] as List).map(BrowserEntry.fromJson).toList();
    if (entries.map((e) => e.name).toSet().length != entries.length) {
      throw const FormatException('Duplicate folder entry.');
    }
    return BrowserPage(
      p['path'],
      p['home'],
      p['scope'],
      List.unmodifiable(entries),
      p['limited'],
    );
  }

  String child(String name) => path == '/' ? '/$name' : '$path/$name';
  String get parent {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }
}

class BrowserPreview {
  const BrowserPreview(this.file, this.document);
  final ProjectFile file;
  final ProjectDocument document;
  static BrowserPreview fromJson(
    Map<String, dynamic> p,
    BrowserPage page,
    BrowserEntry entry,
  ) {
    final file = ProjectFile.fromJson(p['file']);
    if (p['document'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid file preview.');
    }
    final doc = ProjectDocument.fromJson(p['document'] as Map<String, dynamic>);
    if (doc.scope != page.scope ||
        doc.file != file.id ||
        doc.revision != entry.revision ||
        file.revision != entry.revision ||
        file.name != entry.name ||
        file.path != entry.name ||
        !entry.previewable) {
      throw const FormatException('The file changed. Refresh the folder.');
    }
    return BrowserPreview(file, doc);
  }
}

class FileRequestRejected extends SessionUnavailable {
  FileRequestRejected(super.message);
}

class UploadCancelled implements Exception {
  const UploadCancelled();
}

class UploadUncertain implements Exception {
  const UploadUncertain();
}

class BrowserUpload {
  BrowserUpload(this.request);
  final BrowserRequest request;
  bool _cancelled = false, _busy = false;
  String? _token;
  Future<void>? _cancelTask;
  Future<void> _cancelToken() async {
    final token = _token;
    if (token == null) return;
    try {
      await request('fs.cancel', {'token': token});
    } catch (_) {}
  }

  void cancel() {
    _cancelled = true;
    _cancelTask ??= _cancelToken();
  }

  void _check() {
    if (_cancelled) throw const UploadCancelled();
  }

  Future<String> upload(
    BrowserPage destination,
    String name,
    Uint8List bytes, {
    required void Function(int, int) onProgress,
  }) async {
    if (_busy) throw StateError('An upload is already in progress.');
    final metadata = {
      'path': destination.path,
      'scope': destination.scope,
      'name': name,
      'size': bytes.length,
      'sha256': payloadDigest(bytes),
    };
    validateBrowserPayload('fs.begin', metadata);
    _busy = true;
    bool finished = false, finishing = false;
    try {
      _check();
      final start = await request('fs.begin', metadata);
      final token = start['token'];
      if (token is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(token) ||
          start['offset'] != 0) {
        throw const FormatException('Invalid upload acknowledgement.');
      }
      _token = token;
      _check();
      for (var offset = 0; offset < bytes.length;) {
        _check();
        final end = (offset + 262144).clamp(0, bytes.length);
        final result = await request('fs.chunk', {
          'token': token,
          'offset': offset,
          'bytes': base64Encode(bytes.sublist(offset, end)),
        });
        _check();
        if (result['offset'] != end) {
          throw const FormatException('Invalid upload progress.');
        }
        offset = end;
        onProgress(offset, bytes.length);
      }
      _check();
      finishing = true;
      final result = await request('fs.finish', {'token': token});
      if (result['uploaded'] != true ||
          result['path'] != destination.child(name) ||
          result['size'] != bytes.length ||
          result['sha256'] != metadata['sha256']) {
        throw const FormatException('Invalid upload receipt.');
      }
      finished = true;
      onProgress(bytes.length, bytes.length);
      return result['path'] as String;
    } catch (e) {
      if (finishing && e is! FileRequestRejected) throw const UploadUncertain();
      rethrow;
    } finally {
      if (!finished && _token != null) {
        await _cancelTask;
        await _cancelToken();
      }
      _token = null;
      _busy = false;
    }
  }
}

class FolderCreationUncertain implements Exception {
  const FolderCreationUncertain();
}

Future<String> createBrowserFolder(
  BrowserRequest request,
  BrowserPage parent,
  String name,
) async {
  final payload = {'path': parent.path, 'scope': parent.scope, 'name': name};
  validateBrowserPayload('fs.mkdir', payload);
  try {
    final result = await request('fs.mkdir', payload);
    if (result['created'] != true || result['path'] != parent.child(name)) {
      throw const FormatException('Invalid folder receipt.');
    }
    return result['path'] as String;
  } on FileRequestRejected {
    rethrow;
  } catch (_) {
    throw const FolderCreationUncertain();
  }
}

Future<Uint8List> downloadBrowserFile(
  BrowserRequest request,
  BrowserPage parent,
  BrowserEntry entry, {
  bool Function()? isCurrent,
}) async {
  if (entry.kind != 'file' || entry.size > maxUploadBytes) {
    throw const FormatException(
      'Choose regular files up to 32 MiB to download.',
    );
  }
  final data = BytesBuilder(copy: false);
  do {
    if (isCurrent?.call() == false) {
      throw const FormatException(
        'Download cancelled because the session changed.',
      );
    }
    final offset = data.length;
    final r = await request('fs.download', {
      'path': parent.path,
      'scope': parent.scope,
      'name': entry.name,
      'revision': entry.revision,
      'offset': offset,
    });
    if (isCurrent?.call() == false) {
      throw const FormatException(
        'Download cancelled because the session changed.',
      );
    }
    if (r['bytes'] is! String ||
        (r['bytes'] as String).length > 349528 ||
        r['size'] != entry.size ||
        r['offset'] != offset ||
        r['eof'] is! bool) {
      throw const FormatException('Invalid download response.');
    }
    final bytes = base64Decode(r['bytes'] as String);
    if (base64Encode(bytes) != r['bytes'] ||
        bytes.length > 262144 ||
        data.length + bytes.length > entry.size ||
        (bytes.isEmpty && r['eof'] != true)) {
      throw const FormatException('Invalid download response.');
    }
    data.add(bytes);
    if (r['eof'] == true) {
      if (data.length != entry.size) {
        throw const FormatException('The file download was incomplete.');
      }
      return data.takeBytes();
    }
    if (data.length == entry.size) {
      throw const FormatException('Invalid download response.');
    }
  } while (true);
}
