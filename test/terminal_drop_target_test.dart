import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/terminal_drop_target.dart';

import 'package:agentspace/src/controller.dart';

import 'image_attachments_test.dart' show setup, png;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('desktop_drop'), (
          call,
        ) async {
          calls.add(call.method);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('desktop_drop'), null),
  );
  test(
    'cancellation after bookmark start releases access before reading',
    () async {
      var cancelled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('desktop_drop'), (
            call,
          ) async {
            calls.add(call.method);
            if (call.method.startsWith('start')) cancelled = true;
            return true;
          });
      final item = DropItemFile.fromData(png, path: '/tmp/cancel.png')
        ..extraAppleBookmark = Uint8List.fromList([1]);
      await expectLater(
        readDroppedImage(item, cancelled: () => cancelled),
        throwsFormatException,
      );
      expect(calls, [
        'startAccessingSecurityScopedResource',
        'stopAccessingSecurityScopedResource',
      ]);
    },
  );
  for (final exists in [true, false]) {
    test(
      'bookmark access is paired when read ${exists ? 'succeeds' : 'fails'}',
      () async {
        final item =
            (exists
                  ? DropItemFile.fromData(png, path: '/tmp/fixture.png')
                  : DropItemFile('/missing.png'))
              ..extraAppleBookmark = Uint8List.fromList([1, 2]);
        if (exists) {
          expect(await readDroppedImage(item), png);
        } else {
          await expectLater(readDroppedImage(item), throwsA(isA<Exception>()));
        }
        expect(calls, [
          'startAccessingSecurityScopedResource',
          'stopAccessingSecurityScopedResource',
        ]);
      },
    );
  }
  test(
    'directories and oversized images are rejected before reading',
    () async {
      await expectLater(
        readDroppedImage(DropItemDirectory('/tmp', [])),
        throwsFormatException,
      );
      await expectLater(
        readDroppedImage(
          DropItemFile.fromData(
            Uint8List(0),
            path: '/tmp/huge.png',
            length: 16777217,
          ),
        ),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'Finder drop activates its panel, preserves bounds and ignores a second busy drop',
    (tester) async {
      final (app, b, id) = await setup();
      b.uploadHold = Completer<void>();
      app.overview();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 300,
              child: TerminalDropTarget(
                app: app,
                sessionId: id,
                onActivate: () => app.select(id),
                child: const ColoredBox(
                  key: ValueKey('screen'),
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      final bounds = tester.getRect(find.byKey(const ValueKey('screen')));
      final target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile.fromData(png, path: '/tmp/one.png')],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(find.byKey(const ValueKey('screen'))), bounds);
      expect(app.imageDrops[id]!.busy, true);
      target.onDragDone!(
        DropDoneDetails(
          files: [DropItemFile.fromData(png, path: '/tmp/two.png')],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(b.uploads, 1);
      b.uploadHold!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(b.input, hasLength(1));
      expect(b.input.single.keyNames, isNull);
      expect(tester.getRect(find.byKey(const ValueKey('screen'))), bounds);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'uncertain delivery explains image block and recovers after acknowledgement',
    (tester) async {
      final (app, b, id) = await setup();
      app.layout.uncertainDeliveries.add(id);
      app.sendStates.putIfAbsent(id, SendState.new).uncertain = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalDropTarget(
              app: app,
              sessionId: id,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      DropDoneDetails dropped() => DropDoneDetails(
        files: [DropItemFile.fromData(png, path: '/tmp/recovery.png')],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      );
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(dropped());
      await tester.pump();
      expect(b.uploads, 0);
      expect(find.textContaining('I’ve checked'), findsOneWidget);
      expect(
        find.text('Image attachments are unavailable for this session.'),
        findsNothing,
      );
      app.acknowledgeDelivery(id);
      await tester.pump();
      expect(find.textContaining('I’ve checked'), findsNothing);
      tester.widget<DropTarget>(find.byType(DropTarget)).onDragDone!(dropped());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(b.uploads, 1);
      expect(b.input.single.isPaste, true);
      expect(b.input.single.keyNames, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
  testWidgets('mobile terminal has no desktop drop receiver', (tester) async {
    final (app, _, id) = await setup();
    await tester.pumpWidget(
      MaterialApp(
        home: TerminalDropTarget(
          app: app,
          sessionId: id,
          child: const SizedBox(),
        ),
      ),
    );
    expect(find.byType(DropTarget), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(app.shutdown);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
