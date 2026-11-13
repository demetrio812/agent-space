import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'file_browser.dart';

/// Return false on cancellation. Nothing is sent to another app until the user
/// chooses a destination in the native save/share UI.
Future<bool> saveDownloadedFile(
  BuildContext context,
  String name,
  Uint8List bytes, {
  bool Function()? isCurrent,
}) async {
  if (isCurrent?.call() == false) return false;
  if (!browserName(name)) {
    throw const FormatException('Invalid download file name.');
  }
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final directory = await Directory(
      '${(await getTemporaryDirectory()).path}/agentspace-downloads',
    ).create(recursive: true);
    // Keep exports available while destination apps consume them asynchronously.
    // Only this feature's own stale temporary directories are removed.
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is Directory &&
          entry.path.split('/').last.startsWith('export-')) {
        try {
          if (DateTime.now().difference((await entry.stat()).modified) >
              const Duration(hours: 24)) {
            await entry.delete(recursive: true);
          }
        } on FileSystemException {
          /* A busy export can be cleaned up next time. */
        }
      }
    }
    if (isCurrent?.call() == false) return false;
    final temporary = await directory.createTemp('export-');
    final file = File('${temporary.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    if (isCurrent?.call() == false) {
      await temporary.delete(recursive: true);
      return false;
    }
    final result = await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], sharePositionOrigin: origin),
    );
    return result.status != ShareResultStatus.dismissed;
  }
  final location = await getSaveLocation(suggestedName: name);
  if (location == null || isCurrent?.call() == false) return false;
  await XFile.fromData(bytes, name: name).saveTo(location.path);
  return true;
}
