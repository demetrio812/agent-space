import 'package:agentspace/src/demo_backend.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/file_browser.dart';
import 'package:agentspace/src/backend_errors.dart';
import 'package:agentspace/src/session_file_browser.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';

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

class GrowingBrowserSource extends DropItemFile {
  GrowingBrowserSource() : super('/growing');
  @override
  Future<int> length() async => 1;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    final chunk = Uint8List(1024 * 1024);
    for (var i = 0; i < 33; i++) {
      yield chunk;
    }
  }
}

void main() {
  test('Demo folders remain in memory and download original bytes', () async {
    final demo = DemoBackend();
    addTearDown(demo.close);
    final session = (await demo.listSessions()).first;
    Future<Map<String, dynamic>> request(String op, Map<String, dynamic> p) =>
        demo.fileBrowserRequest(session, op, p);
    final page = BrowserPage.fromJson(await request('fs.list', {'path': ''}));
    final created = await createBrowserFolder(request, page, '.new');
    final refreshed = BrowserPage.fromJson(
      await request('fs.list', {'path': page.path}),
    );
    expect(
      refreshed.entries.any((e) => e.name == '.new' && e.kind == 'directory'),
      isTrue,
    );
    expect((await request('fs.list', {'path': created}))['entries'], isEmpty);
    await expectLater(
      createBrowserFolder(request, page, '.new'),
      throwsA(isA<FileRequestRejected>()),
    );
    final readme = refreshed.entries.firstWhere((e) => e.name == 'README.md');
    expect(
      utf8.decode(await downloadBrowserFile(request, refreshed, readme)),
      contains('#'),
    );
  });

  test('download joins bounded binary chunks and rejects changing or truncated files', () async {
    final page = BrowserPage.fromJson(browserPage('/project'));
    final entry = BrowserEntry.fromJson({
      'name': 'data.bin',
      'kind': 'file',
      'size': 3,
      'revision': hash,
    });
    int calls = 0;
    Future<Map<String, dynamic>> execute(
      String op,
      Map<String, dynamic> p,
    ) async {
      calls++;
      expect(op, 'fs.download');
      expect(p['path'], '/project');
      return {'offset': 0, 'bytes': 'AP9B', 'size': 3, 'eof': true};
    }

    expect(await downloadBrowserFile(execute, page, entry), [0, 255, 65]);
    expect(calls, 1);
    await expectLater(
      downloadBrowserFile(
        (_, _) async => {'offset': 0, 'bytes': 'QQ==', 'size': 3, 'eof': true},
        page,
        entry,
      ),
      throwsFormatException,
    );
    await expectLater(
      downloadBrowserFile(execute, page, entry, isCurrent: () => false),
      throwsFormatException,
    );
  });

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
  test('acknowledged no-replace rejection is definite', () async {
    final client = BrowserUpload((op, p) async {
      if (op == 'fs.begin') return {'token': 'b' * 32, 'offset': 0};
      if (op == 'fs.finish') {
        throw FileRequestRejected('A file already exists.');
      }
      return {'cancelled': true};
    });
    await expectLater(
      client.upload(
        BrowserPage.fromJson(browserPage()),
        'empty',
        Uint8List(0),
        onProgress: (_, _) {},
      ),
      throwsA(isA<SessionUnavailable>()),
    );
  });
  test('Finder bookmarks are paired during bounded source reads', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('desktop_drop'), (
          call,
        ) async {
          calls.add(call.method);
          return true;
        });
    try {
      final item = DropItemFile.fromData(
        Uint8List.fromList([1, 2]),
        path: '/outside/file.bin',
      )..extraAppleBookmark = Uint8List.fromList([1]);
      final source = BrowserSource.fromFile(item);
      expect(await source.length(), 2);
      expect(await source.read(), [1, 2]);
      expect(calls, [
        'startAccessingSecurityScopedResource',
        'stopAccessingSecurityScopedResource',
        'startAccessingSecurityScopedResource',
        'stopAccessingSecurityScopedResource',
      ]);
      await expectLater(
        BrowserSource.fromFile(DropItemDirectory('/tmp', [])).read(),
        throwsFormatException,
      );
      await expectLater(
        BrowserSource.fromFile(GrowingBrowserSource()).read(),
        throwsFormatException,
      );
      await expectLater(
        BrowserSource.fromFile(
          DropItemFile.fromData(
            Uint8List(1),
            path: '/huge',
            length: maxUploadBytes + 1,
          ),
        ).read(),
        throwsFormatException,
      );
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('desktop_drop'), null);
    }
  });
  test('create folder validates a single name and reports uncertain completion without retry', () async {
    final page = BrowserPage.fromJson(browserPage());
    var calls = 0;
    expect(
      () => validateBrowserPayload('fs.mkdir', {
        'path': page.path,
        'scope': page.scope,
        'name': '../other',
      }),
      throwsArgumentError,
    );
    expect(
      () => validateBrowserPayload('fs.mkdir', {
        'path': page.path,
        'scope': page.scope,
        'name': ' ',
      }),
      throwsArgumentError,
    );
    expect(
      await createBrowserFolder(
        (op, p) async {
          calls++;
          expect(op, 'fs.mkdir');
          return {'created': true, 'path': '/project/New folder'};
        },
        page,
        'New folder',
      ),
      '/project/New folder',
    );
    await expectLater(
      createBrowserFolder(
        (op, p) async {
          calls++;
          throw TimeoutException('lost');
        },
        page,
        'Next',
      ),
      throwsA(isA<FolderCreationUncertain>()),
    );
    expect(calls, 2);
  });
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
