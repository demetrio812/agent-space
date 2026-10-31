import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart' as photos;

import 'controller.dart';
import 'image_attachments.dart';
import 'ui_common.dart';

enum _ImageLocation { photos, files }

Future<List<ImageSource>> _pickImages(_ImageLocation location) async {
  final files = switch (location) {
    _ImageLocation.photos => await photos.ImagePicker().pickMultiImage(
      limit: 4,
      requestFullMetadata: false,
    ),
    _ImageLocation.files => await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
          uniformTypeIdentifiers: [
            'public.png',
            'public.jpeg',
            'com.compuserve.gif',
            'org.webmproject.webp',
            'com.microsoft.bmp',
          ],
        ),
      ],
    ),
  };
  return files
      .map(
        (file) => ImageSource(
          name: file.name,
          read: () async {
            if (await file.length() > maxImageBytes) {
              throw const FormatException('Image exceeds 16 MiB.');
            }
            final bytes = BytesBuilder(copy: false);
            await for (final chunk in file.openRead()) {
              if (bytes.length + chunk.length > maxImageBytes) {
                throw const FormatException('Image exceeds 16 MiB.');
              }
              bytes.add(chunk);
            }
            return bytes.takeBytes();
          },
        ),
      )
      .toList();
}

class MobileImageAttachment extends StatefulWidget {
  const MobileImageAttachment({
    super.key,
    required this.app,
    required this.sessionId,
    required this.onFinished,
  });
  final AppController app;
  final String sessionId;
  final VoidCallback onFinished;
  @override
  State<MobileImageAttachment> createState() => _MobileImageAttachmentState();
}

class _MobileImageAttachmentState extends State<MobileImageAttachment> {
  bool picking = false;

  Future<void> attach() async {
    if (picking || !widget.app.canDropImages(widget.sessionId)) return;
    final app = widget.app, id = widget.sessionId;
    setState(() => picking = true);
    try {
      await app.pickImages(id, () async {
        final location = await showDialog<_ImageLocation>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Attach images'),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _ImageLocation.photos),
                child: const ListTile(
                  leading: Icon(Icons.photo_library_outlined),
                  title: Text('Photos'),
                ),
              ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _ImageLocation.files),
                child: const ListTile(
                  leading: Icon(Icons.folder_open_outlined),
                  title: Text('Files'),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: Text(
                  'Up to four images, 16 MiB each. Adds to the current prompt without sending it.',
                ),
              ),
            ],
          ),
        );
        if (!mounted || widget.sessionId != id || location == null) return [];
        return _pickImages(location);
      });
    } catch (_) {
      if (mounted && widget.sessionId == id) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the image picker. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => picking = false);
        if (widget.sessionId == id) widget.onFinished();
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 44,
    child: IconButton(
      tooltip: 'Attach images',
      padding: EdgeInsets.zero,
      color: context.ink,
      disabledColor: context.mutedInk,
      onPressed: !picking && widget.app.canDropImages(widget.sessionId)
          ? () => unawaited(attach())
          : null,
      icon: Icon(Icons.add_photo_alternate_outlined, size: 22),
    ),
  );
}
