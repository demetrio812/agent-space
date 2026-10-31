import 'dart:async';

import 'package:agentspace/src/app.dart';
import 'package:agentspace/src/image_attachments.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart'
    hide ImageSource;
import 'package:xterm/xterm.dart';

import 'image_attachments_test.dart' show setup, png;
import 'image_attachments_test.dart' as attachments;

class PhotosFixture extends ImagePickerPlatform {
  final result = Completer<List<XFile>>();
  MultiImagePickerOptions? options;
  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) {
    this.options = options;
    return result.future;
  }
}

class FilesFixture extends FileSelectorPlatform {
  final result = Completer<List<XFile>>();
  List<XTypeGroup>? filters;
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) {
    filters = acceptedTypeGroups;
    return result.future;
  }
}

void main() {
  for (final change in [
    'selection',
    'selection-return',
    'background-return',
    'source',
  ]) {
    test('picker returning after a $change change cannot attach', () async {
      final (app, backend, id) = await setup();
      addTearDown(app.shutdown);
      final selected = Completer<List<ImageSource>>();
      final pending = app.pickImages(id, () => selected.future);
      if (change == 'selection') {
        app.overview();
      } else if (change == 'selection-return') {
        app.overview();
        app.select(id);
      } else if (change == 'background-return') {
        await app.setActive(false);
        await app.setActive(true);
      } else {
        await app.switchSource('demo');
        app.select(id);
      }
      selected.complete([attachments.image('old.png')]);
      await pending;
      expect(backend.uploads, 0);
      expect(backend.input, isEmpty);
      expect(app.imageDrops[id], isNull);
    });
  }

  for (final outcome in ['cancel', 'oversize', 'batch', 'error']) {
    testWidgets('mobile picker $outcome does not send input', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final original = ImagePickerPlatform.instance;
      final picker = PhotosFixture();
      ImagePickerPlatform.instance = picker;
      addTearDown(() => ImagePickerPlatform.instance = original);
      final (app, backend, id) = await setup();
      try {
        await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
        await tester.pump(const Duration(milliseconds: 800));
        await tester.tap(find.byTooltip('Attach images'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Photos'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(
                  IconButton,
                  Icons.add_photo_alternate_outlined,
                ),
              )
              .onPressed,
          isNull,
        );
        switch (outcome) {
          case 'cancel':
            picker.result.complete([]);
          case 'oversize':
            picker.result.complete([
              XFile.fromData(png, path: '/huge.png', length: 16777217),
            ]);
          case 'batch':
            picker.result.complete(
              List.generate(5, (i) => XFile.fromData(png, path: '/$i.png')),
            );
          case 'error':
            picker.result.completeError(
              StateError('Disposable picker failure'),
            );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        expect(backend.uploads, 0);
        expect(backend.input, isEmpty);
        if (outcome == 'cancel') expect(app.imageDrops[id], isNull);
        if (outcome == 'oversize') {
          expect(find.text('Image exceeds 16 MiB.'), findsOneWidget);
        }
        if (outcome == 'batch') {
          expect(find.text('Add up to four images at a time.'), findsOneWidget);
        }
        if (outcome == 'error') {
          expect(
            find.text('Could not open the image picker. Please try again.'),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    });
  }

  testWidgets('mobile image progress can cancel without moving the terminal', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final original = ImagePickerPlatform.instance;
    final picker = PhotosFixture();
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = original);
    final (app, backend, id) = await setup();
    backend.uploadHold = Completer<void>();
    try {
      await tester.pumpWidget(AgentSpaceApp(controller: app, desktop: false));
      await tester.pump(const Duration(milliseconds: 800));
      final bounds = tester.getRect(find.byType(TerminalView));
      await tester.tap(find.byTooltip('Attach images'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photos'));
      await tester.pumpAndSettle();
      picker.result.complete([XFile.fromData(png, path: '/progress.png')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(app.imageDrops[id]!.phase, ImageDropPhase.uploading);
      expect(tester.getRect(find.byType(TerminalView)), bounds);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      backend.uploadHold!.complete();
      await tester.pumpAndSettle();
      expect(app.imageDrops[id]!.phase, ImageDropPhase.cancelled);
      expect(backend.input, isEmpty);
      expect(backend.composedCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    for (final photos in [true, false]) {
      testWidgets(
        'attach from ${photos ? 'Photos' : 'Files'} at $size without submitting',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final originalPhotos = ImagePickerPlatform.instance;
          final originalFiles = FileSelectorPlatform.instance;
          final photoPicker = PhotosFixture();
          final filePicker = FilesFixture();
          ImagePickerPlatform.instance = photoPicker;
          FileSelectorPlatform.instance = filePicker;
          addTearDown(() {
            ImagePickerPlatform.instance = originalPhotos;
            FileSelectorPlatform.instance = originalFiles;
          });
          final (app, backend, id) = await setup();
          app.updateDraft(id, 'keep my draft');
          try {
            await tester.pumpWidget(
              AgentSpaceApp(controller: app, desktop: false),
            );
            await tester.pump(const Duration(milliseconds: 800));
            final bounds = tester.getRect(find.byType(TerminalView));
            expect(find.byTooltip('Attach images'), findsOneWidget);
            await tester.tap(find.byTooltip('Attach images'));
            await tester.pumpAndSettle();
            expect(find.text('Photos'), findsOneWidget);
            expect(find.text('Files'), findsOneWidget);
            await tester.tap(find.text(photos ? 'Photos' : 'Files'));
            await tester.pumpAndSettle();
            if (photos) {
              expect(photoPicker.options!.limit, 4);
              expect(
                photoPicker.options!.imageOptions.requestFullMetadata,
                false,
              );
            } else {
              expect(
                filePicker.filters!.single.uniformTypeIdentifiers,
                contains('public.png'),
              );
            }
            final result = photos ? photoPicker.result : filePicker.result;
            result.complete([XFile.fromData(png, path: '/selected.png')]);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 100));
            await tester.pumpAndSettle();
            expect(backend.uploads, 1);
            expect(backend.input, hasLength(1));
            expect(backend.input.single.isPaste, true);
            expect(backend.input.single.textValue, "/destination/a'post-0.png");
            expect(backend.composedCalls, 0);
            expect(app.layout.drafts[id], 'keep my draft');
            expect(app.imageDrops[id]!.phase, ImageDropPhase.complete);
            expect(
              find.text('Images added to the prompt. Press Enter when ready.'),
              findsOneWidget,
            );
            expect(tester.getRect(find.byType(TerminalView)), bounds);
            expect(
              tester
                  .widget<TerminalView>(find.byType(TerminalView))
                  .focusNode!
                  .hasFocus,
              true,
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(app.shutdown);
          }
        },
      );
    }
  }
}
