import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'controller.dart';
import 'image_attachments.dart';

Future<Uint8List> readDroppedImage(
  DropItem item, {
  bool Function()? cancelled,
}) async {
  if (item is DropItemDirectory) {
    throw const FormatException('Drop image files, rather than folders.');
  }
  final bookmark = item.extraAppleBookmark;
  var scoped = false;
  void check() {
    if (cancelled?.call() == true) {
      throw const FormatException('Image attachment cancelled.');
    }
  }

  try {
    check();
    if (bookmark != null && bookmark.isNotEmpty) {
      scoped = await DesktopDrop.instance.startAccessingSecurityScopedResource(
        bookmark: bookmark,
      );
      if (!scoped) {
        throw const FileSystemException('Cannot read this dropped image.');
      }
    }
    check();
    if (await item.length() > maxImageBytes) {
      throw const FormatException('Image exceeds 16 MiB.');
    }
    final result = BytesBuilder(copy: false);
    var size = 0;
    await for (final chunk in item.openRead()) {
      check();
      size += chunk.length;
      if (size > maxImageBytes) {
        throw const FormatException('Image exceeds 16 MiB.');
      }
      result.add(chunk);
    }
    check();
    return result.takeBytes();
  } finally {
    if (scoped) {
      await DesktopDrop.instance.stopAccessingSecurityScopedResource(
        bookmark: bookmark!,
      );
    }
  }
}

class TerminalDropTarget extends StatefulWidget {
  const TerminalDropTarget({
    super.key,
    required this.app,
    required this.sessionId,
    required this.child,
  });
  final AppController app;
  final String sessionId;
  final Widget child;
  @override
  State<TerminalDropTarget> createState() => _TerminalDropTargetState();
}

class _TerminalDropTargetState extends State<TerminalDropTarget> {
  bool hover = false;
  bool rejected = false;
  Timer? clear;
  @override
  void dispose() {
    clear?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalDropTarget old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      hover = false;
      rejected = false;
      clear?.cancel();
    }
  }

  Future<void> drop(DropDoneDetails details) async {
    setState(() => hover = false);
    final app = widget.app, id = widget.sessionId;
    if (app.imageDrops[id]?.busy == true) return;
    if (!app.canDropImages(id)) {
      setState(() => rejected = true);
      return;
    }
    setState(() => rejected = false);
    clear?.cancel();
    await app.dropImages(
      id,
      details.files
          .map(
            (item) => ImageSource(
              name: item.name,
              read: () {
                final state = app.imageDrops[id];
                return readDroppedImage(
                  item,
                  cancelled: () =>
                      state?.cancelled == true ||
                      !identical(app.imageDrops[id], state),
                );
              },
            ),
          )
          .toList(),
    );
    if (!mounted || widget.sessionId != id) return;
    if (app.imageDrops[id]?.phase == ImageDropPhase.complete) {
      clear = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => hidden = app.imageDrops[id]);
      });
    }
  }

  ImageDropState? hidden;
  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) {
        final app = widget.app,
            id = widget.sessionId,
            state = app.imageDrops[id];
        final error = rejected ? app.imageDropUnavailableReason(id) : null;
        final busy = state?.busy == true;
        final show =
            hover ||
            error != null ||
            (state != null && !identical(hidden, state));
        return DropTarget(
          enable: ModalRoute.of(context)?.isCurrent != false && !busy,
          onDragEntered: (_) => setState(() => hover = true),
          onDragExited: (_) => setState(() => hover = false),
          onDragDone: (details) => unawaited(drop(details)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (hover)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: .08),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              if (show)
                Positioned(
                  top: 12,
                  right: 12,
                  left: 12,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHigh,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (hover)
                                Text(
                                  app.canDropImages(id)
                                      ? 'Drop images to add to this prompt'
                                      : app.imageDropUnavailableReason(id)!,
                                ),
                              if (!hover && state != null && error == null)
                                Text(
                                  state.busy
                                      ? '${state.nextIndex + 1}/${state.names.length} · ${state.names[state.nextIndex]}'
                                      : '${state.nextIndex}/${state.names.length} images added',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (!hover && (error ?? state?.message) != null)
                                Text(error ?? state!.message!),
                              if (busy &&
                                  state!.phase == ImageDropPhase.uploading)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: LinearProgressIndicator(
                                    value: state.total == 0
                                        ? null
                                        : state.bytesSent / state.total,
                                  ),
                                ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (busy &&
                                      !(state!.phase ==
                                              ImageDropPhase.attaching &&
                                          state.inputDispatched))
                                    TextButton(
                                      onPressed: () => app.cancelImageDrop(id),
                                      child: const Text('Cancel'),
                                    ),
                                  if (state?.phase == ImageDropPhase.failed &&
                                      state!.prepared.length ==
                                          state.names.length &&
                                      app.canDropImages(id))
                                    TextButton(
                                      onPressed: () =>
                                          unawaited(app.retryImageDrop(id)),
                                      child: const Text('Retry'),
                                    ),
                                  if (!busy)
                                    TextButton(
                                      onPressed: () => setState(() {
                                        rejected = false;
                                        hover = false;
                                        hidden = state;
                                      }),
                                      child: const Text('Dismiss'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
