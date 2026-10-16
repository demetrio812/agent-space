import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';

const maxImageBytes = 16 * 1024 * 1024;

class ImageSource {
  const ImageSource({required this.name, required this.read});
  final String name;
  final Future<Uint8List> Function() read;
}

class PreparedImage {
  factory PreparedImage({
    required String name,
    required String extension,
    required Uint8List bytes,
    required String sha256,
  }) {
    if (bytes.isEmpty ||
        bytes.length > maxImageBytes ||
        !imageSignature(bytes, extension) ||
        sha256 != _digest(bytes)) {
      throw const FormatException(
        'Choose a PNG, JPEG, GIF, WebP or BMP image up to 16 MiB.',
      );
    }
    return PreparedImage._(
      name,
      extension,
      Uint8List.fromList(bytes).asUnmodifiableView(),
      sha256,
    );
  }
  PreparedImage._(this.name, this.extension, this.bytes, this.sha256);
  factory PreparedImage.prepare(String name, Uint8List bytes) => PreparedImage(
    name: name,
    extension: name.split('.').last.toLowerCase(),
    bytes: bytes,
    sha256: _digest(bytes),
  );
  final String name, extension, sha256;
  final Uint8List bytes;
}

String _digest(Uint8List bytes) => sha256.convert(bytes).toString();
bool imageSignature(Uint8List bytes, String extension) {
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      Iterable<int>.generate(signature.length)
          .every((i) => bytes[i] == signature[i]);
  return switch (extension) {
    'png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
    'jpg' || 'jpeg' => starts([255, 216, 255]),
    'gif' => starts('GIF87a'.codeUnits) || starts('GIF89a'.codeUnits),
    'webp' =>
      bytes.length >= 12 &&
          starts('RIFF'.codeUnits) &&
          String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP',
    'bmp' => starts([66, 77]),
    _ => false,
  };
}

abstract interface class ImageAttachmentBackend {
  bool get imageAttachmentsEnabled;
  Future<String> uploadImage(
    SessionInfo session,
    PreparedImage image, {
    required bool Function() cancelled,
    required void Function(int sent, int total) onProgress,
  });
  void cancelPendingImageTransfers();
}

enum ImageDropPhase {
  preparing,
  uploading,
  attaching,
  complete,
  failed,
  uncertain,
  cancelled,
}

class ImageDropState {
  ImageDropState(this.session, this.names);
  final SessionInfo session;
  final List<String> names;
  final prepared = <PreparedImage>[];
  ImageDropPhase phase = ImageDropPhase.preparing;
  int nextIndex = 0, bytesSent = 0, total = 0;
  String? message;
  bool cancelled = false, inputDispatched = false;
  bool get busy => const [
    ImageDropPhase.preparing,
    ImageDropPhase.uploading,
    ImageDropPhase.attaching,
  ].contains(phase);
}

String quoteAttachmentPath(String path) {
  if (!path.startsWith('/') ||
      path.length > 4096 ||
      path.runes.any((c) => c < 32 || (c >= 127 && c < 160))) {
    throw const FormatException('Invalid attachment destination.');
  }
  return "'${path.replaceAll("'", "'\"'\"'")}' ";
}

void validateImagePayload(String op, Map<String, dynamic> payload) {
  final fields = switch (op) {
    'image.begin' => {'extension', 'size', 'sha256'},
    'image.chunk' => {'token', 'offset', 'bytes'},
    'image.finish' || 'image.cancel' => {'token'},
    _ => throw ArgumentError('Unsupported image action.'),
  };
  bool exact() =>
      payload.length == fields.length && fields.every(payload.containsKey);
  bool matches(Object? value, String pattern) =>
      value is String && RegExp(pattern).hasMatch(value);
  if (!exact()) throw ArgumentError('Invalid image request.');
  if (op == 'image.begin') {
    final size = payload['size'];
    if (!const {
          'png',
          'jpg',
          'jpeg',
          'gif',
          'webp',
          'bmp',
        }.contains(payload['extension']) ||
        size is! int ||
        size < 1 ||
        size > maxImageBytes ||
        !matches(payload['sha256'], r'^[0-9a-f]{64}$')) {
      throw ArgumentError('Invalid image metadata.');
    }
  } else {
    if (!matches(payload['token'], r'^[0-9a-f]{32}$')) {
      throw ArgumentError('Invalid image token.');
    }
    if (op == 'image.chunk') {
      final offset = payload['offset'], value = payload['bytes'];
      if (offset is! int ||
          offset < 0 ||
          offset > maxImageBytes ||
          value is! String ||
          value.isEmpty ||
          value.length > 349528) {
        throw ArgumentError('Invalid image chunk.');
      }
      try {
        final bytes = base64Decode(value);
        if (bytes.isEmpty ||
            bytes.length > 262144 ||
            base64Encode(bytes) != value) {
          throw const FormatException();
        }
      } on FormatException {
        throw ArgumentError('Invalid image chunk.');
      }
    }
  }
}
