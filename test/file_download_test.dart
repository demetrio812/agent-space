import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agentspace/src/file_download.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class HeldSavePicker extends FileSelectorPlatform {
  final result = Completer<FileSaveLocation?>();
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) => result.future;
}

void main() {
  testWidgets(
    'navigation while Save is open does not write the chosen destination',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'agentspace-download-test-',
        );
        final prior = FileSelectorPlatform.instance, picker = HeldSavePicker();
        FileSelectorPlatform.instance = picker;
        try {
          bool current = true;
          final result = saveDownloadedFile(
            context,
            'test.bin',
            Uint8List.fromList([0, 255]),
            isCurrent: () => current,
          );
          current = false;
          final destination = File('${directory.path}/test.bin');
          picker.result.complete(FileSaveLocation(destination.path));
          expect(await result, isFalse);
          expect(await destination.exists(), isFalse);
          await expectLater(
            saveDownloadedFile(context, '../escape', Uint8List(0)),
            throwsFormatException,
          );
        } finally {
          FileSelectorPlatform.instance = prior;
          await directory.delete(recursive: true);
        }
      });
    },
  );
}
