import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backend_errors.dart';
import 'controller.dart';
import 'file_browser.dart';
import 'models.dart';
import 'project_file_viewer.dart';
import 'ui_common.dart';

class BrowserSource {
  const BrowserSource(this.name, this.length, this.read);
  factory BrowserSource.fromFile(XFile file) => BrowserSource(
    file.name,
    () => _access(file, () async => file.length()),
    () => _access(file, () async {
      if (await file.length() > maxUploadBytes) {
        throw const FormatException('Choose files up to 32 MiB each.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > maxUploadBytes) {
          throw const FormatException('Choose files up to 32 MiB each.');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }),
  );
  static Future<T> _access<T>(XFile file, Future<T> Function() body) async {
    if (file is DropItemDirectory) {
      throw const FormatException('Choose files, rather than folders.');
    }
    final bookmark = file is DropItem ? file.extraAppleBookmark : null;
    bool scoped = false;
    try {
      if (bookmark != null && bookmark.isNotEmpty) {
        scoped = await DesktopDrop.instance
            .startAccessingSecurityScopedResource(bookmark: bookmark);
        if (!scoped) {
          throw const FormatException('Could not read this dropped file.');
        }
      }
      return await body();
    } finally {
      if (scoped) {
        await DesktopDrop.instance.stopAccessingSecurityScopedResource(
          bookmark: bookmark!,
        );
      }
    }
  }

  final String name;
  final Future<int> Function() length;
  final Future<Uint8List> Function() read;
}

class SessionFileBrowser extends StatefulWidget {
  const SessionFileBrowser({
    super.key,
    required this.app,
    required this.session,
    required this.active,
    this.pickFiles,
  });
  final AppController app;
  final SessionInfo session;
  final bool active;
  final Future<List<BrowserSource>> Function()? pickFiles;
  @override
  State<SessionFileBrowser> createState() => _SessionFileBrowserState();
}

class _SessionFileBrowserState extends State<SessionFileBrowser> {
  final path = TextEditingController(), search = TextEditingController();
  BrowserRequest get request => widget.app.fileBrowserExecutor(widget.session);
  BrowserPage? page;
  BrowserPreview? preview;
  BrowserUpload? upload;
  bool busy = false, uploading = false, hidden = false, dragging = false;
  bool cancelRequested = false;
  String? error, message;
  String uploadName = '';
  int sent = 0, total = 0, epoch = 0;
  @override
  void initState() {
    super.initState();
    path.addListener(_pathChanged);
    if (widget.active) unawaited(_load(''));
  }

  void _pathChanged() {
    if (mounted) setState(() {});
  }

  bool get committed => page != null && path.text == page!.path;
  bool _current(int token) => mounted && widget.active && token == epoch;
  @override
  void didUpdateWidget(covariant SessionFileBrowser old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) {
      epoch++;
      upload?.cancel();
      busy = false;
      uploading = false;
      if (widget.active) unawaited(_load(page?.path ?? ''));
    }
  }

  @override
  void dispose() {
    epoch++;
    upload?.cancel();
    path.removeListener(_pathChanged);
    path.dispose();
    search.dispose();
    super.dispose();
  }

  String _problem(Object e, String fallback) =>
      e is ConnectionFailure ? e.message : fallback;
  Future<void> _load(String location) async {
    if (!widget.active || uploading) return;
    final token = ++epoch;
    setState(() {
      busy = true;
      error = null;
      preview = null;
    });
    try {
      final result = BrowserPage.fromJson(
        await request('fs.list', {'path': location}),
      );
      if (!_current(token)) return;
      setState(() {
        page = result;
        path.text = result.path;
        search.clear();
      });
    } catch (e) {
      if (_current(token)) {
        setState(() {
          error = _problem(e, 'Could not open this folder.');
          path.text = page?.path ?? '';
        });
      }
    } finally {
      if (_current(token)) setState(() => busy = false);
    }
  }

  Future<void> _open(BrowserEntry entry) async {
    final folder = page;
    if (folder == null || busy || uploading) return;
    if (entry.kind == 'directory' || entry.kind == 'link') {
      await _load(folder.child(entry.name));
      return;
    }
    if (!entry.previewable) {
      setState(
        () => message =
            '${entry.name} · ${_size(entry.size)} · ${entry.kind}. Preview supports Markdown and HTML.',
      );
      return;
    }
    final token = ++epoch;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final result = BrowserPreview.fromJson(
        await request('fs.read', {
          'path': folder.path,
          'scope': folder.scope,
          'name': entry.name,
          'revision': entry.revision,
        }),
        folder,
        entry,
      );
      if (_current(token)) setState(() => preview = result);
    } catch (e) {
      if (_current(token)) {
        setState(
          () => error = _problem(
            e,
            'Could not preview this file. Refresh the folder.',
          ),
        );
      }
    } finally {
      if (_current(token)) setState(() => busy = false);
    }
  }

  Future<List<BrowserSource>> _pick() async {
    final files = await openFiles(confirmButtonText: 'Upload');
    return files.map(BrowserSource.fromFile).toList();
  }

  Future<void> _choose() async {
    if (uploading || busy || !committed) return;
    final token = epoch, destination = page!;
    try {
      final sources = await (widget.pickFiles ?? _pick)();
      if (_current(token) && identical(page, destination)) {
        await _upload(sources);
      }
    } catch (e) {
      if (_current(token)) {
        setState(() => error = _problem(e, 'Could not choose files.'));
      }
    }
  }

  Future<void> _upload(List<BrowserSource> sources) async {
    if (sources.isEmpty ||
        page == null ||
        uploading ||
        busy ||
        !widget.active ||
        !committed) {
      return;
    }
    if (sources.length > 20) {
      setState(() => error = 'Choose up to 20 files at a time.');
      return;
    }
    final destination = page!, token = ++epoch;
    int completed = 0;
    bool failed = false;
    BrowserUpload? operation;
    setState(() {
      uploading = true;
      cancelRequested = false;
      error = null;
      message = null;
    });
    try {
      for (final source in sources) {
        if (!_current(token) || cancelRequested) throw const UploadCancelled();
        if (!browserName(source.name)) {
          throw const FormatException('Choose a file with a valid name.');
        }
        final size = await source.length();
        if (!_current(token) || cancelRequested) throw const UploadCancelled();
        if (size < 0 || size > maxUploadBytes) {
          throw const FormatException('Choose files up to 32 MiB each.');
        }
        setState(() {
          uploadName = source.name;
          sent = 0;
          total = size;
        });
        final bytes = await source.read();
        if (!_current(token) || cancelRequested) throw const UploadCancelled();
        if (bytes.length != size) {
          throw const FormatException(
            'The local file changed. Choose it again.',
          );
        }
        final task = BrowserUpload(request);
        operation = task;
        upload = task;
        await task.upload(
          destination,
          source.name,
          bytes,
          onProgress: (s, t) {
            if (_current(token)) {
              setState(() {
                sent = s;
                total = t;
              });
            }
          },
        );
        completed++;
        if (identical(upload, task)) upload = null;
      }
      if (_current(token)) {
        setState(
          () => message = widget.app.source == 'demo'
              ? 'Demo upload complete; no files were saved.'
              : '$completed ${completed == 1 ? 'file' : 'files'} uploaded.',
        );
      }
    } catch (e) {
      failed = true;
      if (_current(token)) {
        setState(
          () => error = switch (e) {
            UploadCancelled() => 'Upload cancelled.',
            UploadUncertain() => 'Upload outcome is unknown. Refresh the destination before trying again.',
            FormatException(:final message) => message,
            _ => _problem(e, 'Upload failed. No existing files were replaced.'),
          },
        );
      }
    } finally {
      if (identical(upload, operation)) upload = null;
      if (_current(token)) {
        setState(() => uploading = false);
        // Refresh the same captured location without hiding an outcome warning.
        if (!failed) {
          final note = message;
          await _load(destination.path);
          if (mounted && widget.active) setState(() => message = note);
        }
      }
    }
  }

  String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  Future<void> _link(String href) async {
    final uri = Uri.tryParse(href);
    if (uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  Widget _fit(Widget child) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxHeight >= 320) return child;
      return SingleChildScrollView(child: SizedBox(height: 320, child: child));
    },
  );
  @override
  Widget build(BuildContext context) {
    if (!widget.app.supportsFileBrowser) {
      return Center(
        child: Text(
          'File browsing requires the bundled connection helper.',
          style: TextStyle(color: context.mutedInk),
        ),
      );
    }
    final folder = page, document = preview;
    final enabled = widget.active && !busy && !uploading;
    if (document != null) {
      return Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Back to files',
                onPressed: () => setState(() => preview = null),
                icon: const Icon(Icons.arrow_back, size: 18),
              ),
              Expanded(
                child: Text(
                  document.file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Expanded(
            child: ProjectFileViewer(
              key: ValueKey(document.file.id),
              file: document.file,
              document: document.document,
              onLink: (s) => unawaited(_link(s)),
            ),
          ),
        ],
      );
    }
    final entries =
        folder?.entries
            .where(
              (e) =>
                  (hidden || !e.name.startsWith('.')) &&
                  e.name.toLowerCase().contains(search.text.toLowerCase()),
            )
            .toList() ??
        <BrowserEntry>[];
    return DropTarget(
      enable:
          enabled && committed && ModalRoute.of(context)?.isCurrent != false,
      onDragEntered: (_) => setState(() => dragging = true),
      onDragExited: (_) => setState(() => dragging = false),
      onDragDone: (details) {
        setState(() => dragging = false);
        unawaited(_upload(details.files.map(BrowserSource.fromFile).toList()));
      },
      child: _fit(
        Container(
          decoration: BoxDecoration(
            border: dragging
                ? Border.all(color: context.accent, width: 2)
                : null,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Parent folder',
                      onPressed: enabled && folder != null && folder.path != '/'
                          ? () => unawaited(_load(folder.parent))
                          : null,
                      icon: const Icon(Icons.arrow_upward, size: 18),
                    ),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('browser-path'),
                        controller: path,
                        enabled: enabled,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Absolute folder path',
                          contentPadding: EdgeInsets.all(9),
                        ),
                        onSubmitted: (value) => unawaited(_load(value)),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Folder locations',
                      enabled: enabled,
                      onSelected: (value) => unawaited(_load(value)),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: '',
                          child: Text('Session folder'),
                        ),
                        const PopupMenuItem(
                          value: '~',
                          child: Text('Home folder'),
                        ),
                        const PopupMenuItem(
                          value: '/',
                          child: Text('Computer root'),
                        ),
                      ],
                      icon: const Icon(Icons.more_horiz, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Upload files',
                      onPressed: enabled && committed
                          ? () => unawaited(_choose())
                          : null,
                      icon: const Icon(Icons.upload_file_outlined, size: 19),
                    ),
                    IconButton(
                      tooltip: 'Refresh folder',
                      onPressed: enabled
                          ? () => unawaited(_load(folder?.path ?? ''))
                          : null,
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                  ],
                ),
              ),
              if (folder != null)
                SizedBox(
                  height: 30,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: enabled
                              ? () => unawaited(_load('/'))
                              : null,
                          child: const Text(
                            '/',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        for (
                          var i = 0;
                          i <
                              folder.path
                                  .split('/')
                                  .where((p) => p.isNotEmpty)
                                  .length;
                          i++
                        )
                          Builder(
                            builder: (context) {
                              final parts = folder.path
                                  .split('/')
                                  .where((p) => p.isNotEmpty)
                                  .toList();
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.chevron_right, size: 13),
                                  TextButton(
                                    onPressed: enabled
                                        ? () => unawaited(
                                            _load(
                                              '/${parts.take(i + 1).join('/')}',
                                            ),
                                          )
                                        : null,
                                    child: Text(
                                      parts[i],
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: search,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Filter this folder…',
                          prefixIcon: Icon(Icons.search, size: 17),
                          contentPadding: EdgeInsets.all(9),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: hidden
                          ? 'Hide hidden files'
                          : 'Show hidden files',
                      isSelected: hidden,
                      onPressed: () => setState(() => hidden = !hidden),
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                    ),
                  ],
                ),
              ),
              if (busy) const LinearProgressIndicator(minHeight: 2),
              if (error != null || message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      error ?? message!,
                      style: TextStyle(
                        fontSize: 11,
                        color: error != null
                            ? context.attention
                            : context.success,
                      ),
                    ),
                  ),
                ),
              if (uploading)
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Uploading $uploadName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: total == 0 ? 0 : sent / total,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              cancelRequested = true;
                              upload?.cancel();
                            },
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                      Text(
                        '${_size(sent)} / ${_size(total)}',
                        style: TextStyle(fontSize: 10, color: context.mutedInk),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(
                          busy
                              ? 'Opening folder…'
                              : folder == null
                              ? 'Open a folder to browse its files.'
                              : 'This folder has no matching files.',
                          style: TextStyle(color: context.mutedInk),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return ListTile(
                            key: ValueKey('browser-entry-${entry.name}'),
                            dense: true,
                            enabled: enabled,
                            leading: Icon(
                              switch (entry.kind) {
                                'directory' => Icons.folder_outlined,
                                'link' => Icons.link,
                                'file' => Icons.insert_drive_file_outlined,
                                _ => Icons.device_unknown,
                              },
                              size: 20,
                              color: entry.kind == 'directory'
                                  ? context.accent
                                  : context.mutedInk,
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: Text(
                              entry.kind == 'file'
                                  ? _size(entry.size)
                                  : entry.kind,
                              style: TextStyle(
                                fontSize: 10,
                                color: context.mutedInk,
                              ),
                            ),
                            trailing:
                                entry.kind == 'directory' ||
                                    entry.kind == 'link'
                                ? const Icon(Icons.chevron_right, size: 17)
                                : null,
                            onTap: () => unawaited(_open(entry)),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    folder?.limited == true
                        ? 'Folder listing limited. Use a narrower location.'
                        : 'Upload into this folder · 32 MiB per file · existing files kept',
                    style: TextStyle(fontSize: 10, color: context.mutedInk),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
