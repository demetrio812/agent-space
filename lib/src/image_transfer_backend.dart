import 'dart:async';
import 'dart:convert';

import 'backend_errors.dart';
import 'bridge_protocol.dart';
import 'image_attachments.dart';
import 'persistent_bridge.dart';

class ImageTransferClient {
  ImageTransferClient(this.bridge);
  final PersistentBridge bridge;
  final _pending = <String, Map<String, dynamic>>{};
  final _cancels = <Future<void>>{};
  Future<void> drainCancelled() => Future.wait(_cancels.toList());
  void cancelPending() {
    for (final entry in _pending.entries.toList()) {
      final task = _cancel(entry.key, entry.value);
      _cancels.add(task);
      unawaited(task.whenComplete(() => _cancels.remove(task)));
    }
  }

  Future<void> _cancel(String token, Map<String, dynamic> route) async {
    try {
      await bridge.request(
        BridgeLane.transfer,
        'image.cancel',
        {'token': token},
        route: route,
        timeout: const Duration(seconds: 2),
      );
    } catch (_) {}
  }

  Future<String> upload(
    Map<String, dynamic> route,
    PreparedImage image, {
    required bool Function() cancelled,
    required void Function(int, int) onProgress,
  }) async {
    void check() {
      if (cancelled()) {
        throw SessionUnavailable(
          'Image transfer cancelled because its destination changed.',
        );
      }
    }

    String? token;
    bool finished = false;
    try {
      check();
      final start = await bridge.request(
        BridgeLane.transfer,
        'image.begin',
        {
          'extension': image.extension,
          'size': image.bytes.length,
          'sha256': image.sha256,
        },
        route: route,
        cancelled: cancelled,
      );
      final value = start['token'];
      if (value is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(value) ||
          start['offset'] != 0) {
        throw const FormatException('Invalid image transfer acknowledgement.');
      }
      token = value;
      _pending[token] = route;
      check();
      for (var offset = 0; offset < image.bytes.length;) {
        check();
        final end = (offset + 256 * 1024).clamp(0, image.bytes.length);
        final result = await bridge.request(
          BridgeLane.transfer,
          'image.chunk',
          {
            'token': token,
            'offset': offset,
            'bytes': base64Encode(image.bytes.sublist(offset, end)),
          },
          route: route,
          cancelled: cancelled,
        );
        check();
        if (result['offset'] != end) {
          throw const FormatException('Invalid image transfer offset.');
        }
        offset = end;
        onProgress(offset, image.bytes.length);
      }
      check();
      final result = await bridge.request(
        BridgeLane.transfer,
        'image.finish',
        {'token': token},
        route: route,
        cancelled: cancelled,
      );
      check();
      final path = result['path'];
      if (result['size'] != image.bytes.length ||
          result['sha256'] != image.sha256 ||
          path is! String) {
        throw const FormatException('Invalid image transfer receipt.');
      }
      quoteAttachmentPath(path);
      finished = true;
      return path;
    } finally {
      if (token != null) {
        _pending.remove(token);
        if (!finished) await _cancel(token, route);
      }
    }
  }
}
