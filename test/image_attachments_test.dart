import 'dart:async';
import 'dart:convert';

import 'package:agentspace/src/bridge_protocol.dart';
import 'package:agentspace/src/network_backend.dart';
import 'package:agentspace/src/persistent_bridge.dart';

import 'fixtures/fake_bridge.dart';
import 'fixtures/network_fixture.dart';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/image_attachments.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/storage.dart';

import 'terminal_input_test.dart' show InputFixture, WidgetStore;

final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);
ImageSource image(String name) =>
    ImageSource(name: name, read: () async => png);

class AttachmentFixture extends InputFixture implements ImageAttachmentBackend {
  @override
  SessionInfo get session => const SessionInfo(
    key: SessionKey('demo', 'demo', 'server', 't1'),
    paneId: 'p1',
    title: 'Images',
    project: 'fixture',
    agent: 'fixture',
    status: SessionStatus.idle,
    inputEnabled: true,
    terminalInputEnabled: true,
    imageTransferEnabled: true,
  );
  @override
  bool get imageAttachmentsEnabled => true;
  Completer<void>? uploadHold;
  int uploads = 0, failAt = -1, cancels = 0;
  void Function()? afterFinish;
  @override
  Future<String> uploadImage(
    SessionInfo s,
    PreparedImage image, {
    required bool Function() cancelled,
    required void Function(int, int) onProgress,
  }) async {
    final index = uploads++;
    await uploadHold?.future;
    if (cancelled()) throw SessionUnavailable();
    if (index == failAt) throw ConnectionFailure('Upload failed.');
    onProgress(image.bytes.length, image.bytes.length);
    afterFinish?.call();
    return "/destination/a'post-$index.png";
  }

  @override
  void cancelPendingImageTransfers() {
    cancels++;
  }
}

Future<(AppController, AttachmentFixture, String)> setup({
  LayoutStore? store,
}) async {
  final b = AttachmentFixture();
  final app = AppController(
    snapshot: AppSnapshot(),
    store: store ?? WidgetStore(),
    backendFactory: (_) => b,
  );
  await app.start(polling: false);
  final id = b.session.key.id;
  app.select(id);
  return (app, b, id);
}

class FailNextStore extends WidgetStore {
  bool fail = false;
  @override
  Future<void> save(AppSnapshot value) async {
    if (fail) {
      fail = false;
      throw StateError('Disposable save failure');
    }
  }
}

Future<void> waitAttachment(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), true);
}

void main() {
  test(
    'source changes at attachment dispatch notification suppress input',
    () async {
      final (app, b, id) = await setup();
      addTearDown(app.shutdown);
      var changed = false;
      app.addListener(() {
        if (!changed && app.imageDrops[id]?.inputDispatched == true) {
          changed = true;
          app.overview();
        }
      });
      await app.dropImages(id, [image('one.png')]);
      expect(changed, true);
      expect(b.input, isEmpty);
      expect(app.imageDrops[id]!.nextIndex, 0);
    },
  );

  test('already dispatched attachment reports its actual acknowledgement after Cancel', () async {
    final (app, b, id) = await setup();
    addTearDown(app.shutdown);
    b.hold = Completer<void>();
    final drop = app.dropImages(id, [image('one.png')]);
    await waitAttachment(() => b.input.isNotEmpty);
    app.cancelImageDrop(id);
    expect(app.imageDrops[id]!.phase, ImageDropPhase.attaching);
    b.hold!.complete();
    await drop;
    expect(app.imageDrops[id]!.nextIndex, 1);
    expect(app.imageDrops[id]!.phase, ImageDropPhase.complete);
  });

  test('cancel removes a queued attachment behind held typing', () async {
    final (app, b, id) = await setup();
    addTearDown(app.shutdown);
    b.hold = Completer<void>();
    app.sendTerminalInput(id, TerminalInput.text('held typing'));
    await waitAttachment(() => b.input.isNotEmpty);
    final drop = app.dropImages(id, [image('one.png')]);
    await waitAttachment(
      () => app.imageDrops[id]!.phase == ImageDropPhase.attaching,
    );
    expect(app.imageDrops[id]!.phase, ImageDropPhase.attaching);
    app.cancelImageDrop(id);
    b.hold!.complete();
    await drop;
    expect(b.input.map((e) => e.textValue), ['held typing']);
    expect(app.imageDrops[id]!.nextIndex, 0);
    expect(app.imageDrops[id]!.phase, ImageDropPhase.cancelled);
  });
  test('later key save failure cannot retry an acknowledged image', () async {
    final store = FailNextStore();
    final (app, b, id) = await setup(store: store);
    addTearDown(app.shutdown);
    b.hold = Completer<void>();
    final drop = app.dropImages(id, [image('one.png')]);
    await waitAttachment(() => b.input.isNotEmpty);
    expect(b.input, hasLength(1));
    app.sendTerminalInput(id, TerminalInput.keys(['up']));
    store.fail = true;
    b.hold!.complete();
    await drop;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(app.imageDrops[id]!.nextIndex, 1);
    expect(app.imageDrops[id]!.phase, ImageDropPhase.complete);
    await app.retryImageDrop(id);
    expect(b.uploads, 1);
    expect(b.input, hasLength(1));
  });

  test(
    'transfer envelopes reject malformed metadata before opening a lane',
    () async {
      final wire = FakeBridge();
      final bridge = PersistentBridge(wire.open);
      addTearDown(bridge.close);
      for (final payload in [
        {'extension': 'png', 'size': true, 'sha256': 'a' * 64},
        {'extension': 'png', 'size': 16777217, 'sha256': 'a' * 64},
        {'extension': '../png', 'size': 8, 'sha256': 'a' * 64},
      ]) {
        await expectLater(
          bridge.request(
            BridgeLane.transfer,
            'image.begin',
            payload,
            route: fixtureRoute,
          ),
          throwsArgumentError,
        );
      }
      expect(wire.openedLanes, isEmpty);
    },
  );

  test(
    'image chunks use their separate lane and exact selected peer receipt',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [wireComputer(fixtureMachineB, 'Peer')];
      (wire.computerEvents.single['catalog'] as Map)['imageTransferEnabled'] =
          true;
      final token = 'a' * 32;
      Map? begin;
      final received = <int>[];
      wire.resultFor = (row) {
        final p = row['payload'] as Map;
        switch (row['op']) {
          case 'image.begin':
            begin = p;
            return {'token': token, 'offset': 0};
          case 'image.chunk':
            expect(p['offset'], received.length);
            received.addAll(base64Decode(p['bytes']));
            return {'offset': received.length};
          case 'image.finish':
            return {
              'path': '/remote/image.png',
              'size': received.length,
              'sha256': begin!['sha256'],
            };
        }
        return null;
      };
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      final session = (await backend.listSessions()).single;
      final bytes = Uint8List(300000)..setRange(0, png.length, png);
      final image = PreparedImage.prepare('test.png', bytes);
      expect(
        await backend.uploadImage(
          session,
          image,
          cancelled: () => false,
          onProgress: (_, _) {},
        ),
        '/remote/image.png',
      );
      expect(received, bytes);
      final requests = wire.requests
          .where((r) => (r['op'] as String).startsWith('image.'))
          .toList();
      expect(requests.map((r) => r['op']), [
        'image.begin',
        'image.chunk',
        'image.chunk',
        'image.finish',
      ]);
      for (final r in requests) {
        expect(r['lane'], 'transfer');
        expect(r['route']['machine'], fixtureMachineB);
        expect(r['route']['pane'], 'p1');
      }
      expect(wire.sentInputs, isEmpty);
    },
  );
  test(
    'bad image receipt cannot become a prompt path and cancels the token',
    () async {
      final wire = FakeBridge()
        ..computerEvents = [wireComputer(fixtureMachineB, 'Peer')];
      (wire.computerEvents.single['catalog'] as Map)['imageTransferEnabled'] =
          true;
      wire.resultFor = (row) => switch (row['op']) {
        'image.begin' => {'token': 'a' * 32, 'offset': 0},
        'image.chunk' => {'offset': png.length},
        'image.finish' => {
          'path': '/bad.png',
          'size': png.length,
          'sha256': '0' * 64,
        },
        'image.cancel' => {'cancelled': true},
        _ => null,
      };
      final backend = NetworkHerdrBackend(
        ConnectionProfile(id: 'remote', label: 'Gateway'),
        PersistentBridge(wire.open),
      );
      addTearDown(backend.close);
      final session = (await backend.listSessions()).single;
      await expectLater(
        backend.uploadImage(
          session,
          PreparedImage.prepare('test.png', png),
          cancelled: () => false,
          onProgress: (_, _) {},
        ),
        throwsFormatException,
      );
      expect(wire.requests.last['op'], 'image.cancel');
      expect(wire.sentInputs, isEmpty);
    },
  );

  test('unsupported signatures and oversized batches never upload', () async {
    final (app, b, id) = await setup();
    addTearDown(app.shutdown);
    await app.dropImages(id, [
      ImageSource(
        name: 'bad.png',
        read: () async => Uint8List.fromList([1, 2]),
      ),
    ]);
    expect(b.uploads, 0);
    expect(app.imageDrops[id]!.phase, ImageDropPhase.failed);
    await app.dropImages(id, List.generate(5, (i) => image('$i.png')));
    expect(b.uploads, 0);
    expect(
      () => PreparedImage.prepare('huge.png', Uint8List(16777217)),
      throwsFormatException,
    );
  });
  test(
    'typing continues during upload and image path is pasted without Enter',
    () async {
      final (app, b, id) = await setup();
      addTearDown(app.shutdown);
      b.uploadHold = Completer<void>();
      final drop = app.dropImages(id, [image('one.png')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      app.sendTerminalInput(id, TerminalInput.text('typing '));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(b.input.single.textValue, 'typing ');
      b.uploadHold!.complete();
      await drop;
      expect(b.input.last.toJson(), {'paste': "/destination/a'post-0.png"});
      expect(b.input.last.keyNames, isNull);
      expect(app.imageDrops[id]!.phase, ImageDropPhase.complete);
      expect(b.composedCalls, 0);
    },
  );
  for (final boundary in ['selection', 'background', 'finish']) {
    test('$boundary change prevents attachment insertion', () async {
      final (app, b, id) = await setup();
      addTearDown(app.shutdown);
      b.uploadHold = Completer<void>();
      if (boundary == 'finish') b.afterFinish = app.overview;
      final drop = app.dropImages(id, [image('one.png')]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (boundary == 'selection') app.overview();
      if (boundary == 'background') app.setActive(false);
      b.uploadHold!.complete();
      await drop;
      expect(b.input, isEmpty);
      expect(app.imageDrops[id]!.phase, ImageDropPhase.cancelled);
    });
  }
  test(
    'retry starts at failed image without duplicating earlier attachments',
    () async {
      final (app, b, id) = await setup();
      addTearDown(app.shutdown);
      b.failAt = 1;
      await app.dropImages(id, [image('one.png'), image('two.png')]);
      expect(b.input, hasLength(1));
      expect(app.imageDrops[id]!.nextIndex, 1);
      await app.retryImageDrop(id);
      expect(b.input, hasLength(2));
      expect(b.uploads, 3);
      expect(app.imageDrops[id]!.phase, ImageDropPhase.complete);
    },
  );
  test(
    'uncertain final input persists the inspection gate and cannot retry',
    () async {
      final (app, b, id) = await setup();
      addTearDown(app.shutdown);
      b.uncertain = true;
      await app.dropImages(id, [image('one.png')]);
      expect(app.imageDrops[id]!.phase, ImageDropPhase.uncertain);
      expect(app.layout.uncertainDeliveries, contains(id));
      await app.retryImageDrop(id);
      expect(b.input, hasLength(1));
      expect(b.uploads, 1);
    },
  );
  test('cancel before input timer settles the attachment waiter', () async {
    final (app, b, id) = await setup();
    addTearDown(app.shutdown);
    final insertion = app.insertAttachmentPath(id, '/tmp/test.png');
    app.overview();
    await expectLater(
      insertion.timeout(const Duration(seconds: 1)),
      throwsA(isA<SessionUnavailable>()),
    );
    expect(b.input, isEmpty);
  });
}
