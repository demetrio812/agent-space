import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/file_browser.dart';

final hash = 'a' * 64;
Map<String, dynamic> browserPage([String path = '/project']) => {
  'path': path,
  'home': '/home/demo',
  'scope': hash,
  'entries': [
    {'name': 'docs', 'kind': 'directory', 'size': 0, 'revision': hash},
    {'name': 'README.md', 'kind': 'file', 'size': 12, 'revision': hash},
  ],
  'limited': false,
};
void main() {
  test('strict directory results and payloads reject traversal and malformed entries', () {
    expect(BrowserPage.fromJson(browserPage()).entries.length, 2);
    expect(
      () => BrowserPage.fromJson({...browserPage(), 'path': 'relative'}),
      throwsFormatException,
    );
    expect(
      () => BrowserPage.fromJson({
        ...browserPage(),
        'entries': [
          {'name': '../evil', 'kind': 'file', 'size': 0, 'revision': hash},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => validateBrowserPayload('fs.begin', {
        'path': '/project',
        'scope': hash,
        'name': '../evil',
        'size': 0,
        'sha256': hash,
      }),
      throwsArgumentError,
    );
    expect(
      () => validateBrowserPayload('fs.list', {'path': '../other'}),
      throwsArgumentError,
    );
    validateBrowserPayload('fs.list', {'path': '~'});
  });
  test(
    'binary and empty uploads acknowledge chunks before atomic finish',
    () async {
      for (final bytes in [
        Uint8List.fromList(List.generate(300000, (i) => i % 256)),
        Uint8List(0),
      ]) {
        final calls = <String>[];
        var offset = 0;
        final client = BrowserUpload((op, payload) async {
          validateBrowserPayload(op, payload);
          calls.add(op);
          if (op == 'fs.begin') return {'token': 'b' * 32, 'offset': 0};
          if (op == 'fs.chunk') {
            expect(payload['offset'], offset);
            offset += base64Decode(payload['bytes'] as String).length;
            return {'offset': offset};
          }
          return {
            'uploaded': true,
            'path': '/project/test.bin',
            'size': bytes.length,
            'sha256': payloadDigest(bytes),
          };
        });
        await client.upload(
          BrowserPage.fromJson(browserPage()),
          'test.bin',
          bytes,
          onProgress: (_, _) {},
        );
        expect(calls.last, 'fs.finish');
        expect(offset, bytes.length);
        expect(calls.where((s) => s == 'fs.finish').length, 1);
      }
    },
  );
  test(
    'cancellation after begin cleans the partial and never publishes',
    () async {
      final hold = Completer<Map<String, dynamic>>();
      final calls = <String>[];
      final client = BrowserUpload((op, payload) async {
        calls.add(op);
        if (op == 'fs.begin') return hold.future;
        return {'cancelled': true};
      });
      final future = client.upload(
        BrowserPage.fromJson(browserPage()),
        'test',
        Uint8List(1),
        onProgress: (_, _) {},
      );
      final result = expectLater(future, throwsA(isA<UploadCancelled>()));
      client.cancel();
      hold.complete({'token': 'b' * 32, 'offset': 0});
      await result;
      expect(calls, ['fs.begin', 'fs.cancel']);
    },
  );
  test('lost finish is uncertain and is not retried', () async {
    final calls = <String>[];
    final client = BrowserUpload((op, payload) async {
      calls.add(op);
      if (op == 'fs.begin') return {'token': 'b' * 32, 'offset': 0};
      if (op == 'fs.finish') throw TimeoutException('lost');
      return {'cancelled': true};
    });
    await expectLater(
      client.upload(
        BrowserPage.fromJson(browserPage()),
        'empty',
        Uint8List(0),
        onProgress: (_, _) {},
      ),
      throwsA(isA<UploadUncertain>()),
    );
    expect(calls.where((s) => s == 'fs.finish').length, 1);
    expect(calls.last, 'fs.cancel');
  });
}
