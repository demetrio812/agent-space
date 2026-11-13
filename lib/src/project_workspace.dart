import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backend_errors.dart';
import 'controller.dart';
import 'models.dart';
import 'project_files.dart';
import 'project_file_viewer.dart';
import 'ui_common.dart';

class ProjectWorkspace extends StatefulWidget {
  const ProjectWorkspace({
    super.key,
    required this.app,
    required this.session,
    required this.active,
    required this.builder,
  });
  final AppController app;
  final SessionInfo session;
  final bool active;
  final Widget Function(VoidCallback toggle, bool visible, bool covered)
  builder;
  @override
  State<ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<ProjectWorkspace> {
  late ProjectPanelLayout preference;
  bool hasPreference = false, busy = false, wasRunning = false;
  int epoch = 0;
  Timer? timer;
  ProjectManifest? manifest;
  String? error;
  final documents = <String, ProjectDocument>{};
  final errors = <String, String>{};
  final loading = <String>{};
  final search = TextEditingController();
  final focus = FocusNode();
  final coverOwner = Object();
  final sessionSlot = GlobalKey();
  String? savedPreference;
  bool get running =>
      widget.active &&
      widget.app.isActive &&
      widget.app.layout.selectedId == widget.session.key.id;
  bool get wanted =>
      running &&
      (preference.visible || !hasPreference) &&
      widget.app.supportsProjectFiles;
  @override
  void initState() {
    super.initState();
    _restore();
    widget.app.addListener(_appChanged);
    wasRunning = running;
    if (wanted) unawaited(_refresh());
  }

  void _restore() {
    final saved = widget.app.layout.projectPanels[widget.session.key.id];
    hasPreference = saved != null;
    preference = saved == null
        ? ProjectPanelLayout()
        : ProjectPanelLayout.fromJson(saved.toJson());
    savedPreference = saved == null ? null : jsonEncode(saved.toJson());
  }

  void _save() {
    final value = jsonEncode(preference.toJson());
    if (value == savedPreference) return;
    savedPreference = value;
    widget.app.saveProjectPanel(widget.session.key.id, preference);
  }

  Object _target(SessionInfo session) => (
    session.key,
    session.paneId,
    session.origin?.machineId,
    session.origin?.herdrSession,
    session.origin?.targetHash,
    session.origin?.generation,
  );
  void _appChanged() {
    if (!mounted) return;
    if (running != wasRunning) {
      wasRunning = running;
      epoch++;
      timer?.cancel();
      busy = false;
      loading.clear();
      if (wanted) unawaited(_refresh());
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant ProjectWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app ||
        _target(oldWidget.session) != _target(widget.session)) {
      oldWidget.app.removeListener(_appChanged);
      oldWidget.app.setProjectPanelFocused(
        oldWidget.session.key.id,
        this,
        false,
      );
      oldWidget.app.setProjectPanelFocused(
        oldWidget.session.key.id,
        coverOwner,
        false,
      );
      focus.unfocus();
      widget.app.addListener(_appChanged);
      epoch++;
      timer?.cancel();
      busy = false;
      manifest = null;
      error = null;
      documents.clear();
      errors.clear();
      loading.clear();
      search.clear();
      _restore();
      preference.scope = '';
      preference.opened.clear();
      preference.active = 'files';
      _save();
      wasRunning = false;
    }
    _appChanged();
  }

  void _schedule() {
    timer?.cancel();
    if (wanted) {
      timer = Timer(
        Duration(seconds: preference.visible ? 5 : 10),
        () => unawaited(_refresh()),
      );
    }
  }

  void _toggle() {
    FocusManager.instance.primaryFocus?.unfocus();
    epoch++;
    timer?.cancel();
    busy = false;
    loading.clear();
    setState(() {
      hasPreference = true;
      preference.visible = !preference.visible;
      error = null;
      if (!preference.visible) {
        documents.clear();
        errors.clear();
      }
    });
    widget.app.setProjectPanelFocused(
      widget.session.key.id,
      this,
      preference.visible,
    );
    _save();
    if (preference.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && preference.visible) focus.requestFocus();
      });
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (!wanted || busy) return;
    final token = epoch;
    busy = true;
    try {
      final result = await widget.app.listProjectFiles(widget.session);
      if (!mounted || token != epoch || !wanted) return;
      setState(() {
        if (preference.scope.isNotEmpty && preference.scope != result.scope) {
          preference.opened.clear();
          preference.active = 'files';
          documents.clear();
          errors.clear();
          loading.clear();
          search.clear();
        }
        preference.scope = result.scope;
        manifest = result;
        preference.opened.removeWhere((id) => result.file(id) == null);
        documents.removeWhere((id, _) => !preference.opened.contains(id));
        errors.removeWhere((id, _) => !preference.opened.contains(id));
        if (!const ['files', 'specs'].contains(preference.active) &&
            !preference.opened.contains(preference.active)) {
          preference.active = 'files';
        }
        if (!hasPreference && result.files.isNotEmpty) {
          preference.visible = true;
          hasPreference = true;
        }
        error = null;
      });
      if (hasPreference) _save();
      final active = result.file(preference.active);
      if (preference.visible &&
          active != null &&
          documents[active.id]?.revision != active.revision) {
        await _load(active);
      }
    } catch (e) {
      if (mounted && token == epoch && wanted) {
        setState(
          () => error = manifest == null
              ? 'Project files could not be loaded. Try Refresh.'
              : 'Could not refresh. The documents shown are cached.',
        );
      }
    } finally {
      if (mounted && token == epoch) {
        setState(() => busy = false);
        _schedule();
      }
    }
  }

  Future<void> _load(ProjectFile file) async {
    final page = manifest;
    if (page == null ||
        loading.contains(file.id) ||
        !running ||
        !preference.visible) {
      return;
    }
    final token = epoch;
    setState(() => loading.add(file.id));
    try {
      final doc = await widget.app.readProjectFile(
        widget.session,
        page.scope,
        file.id,
      );
      if (!mounted ||
          token != epoch ||
          !running ||
          !preference.visible ||
          manifest?.scope != doc.scope ||
          !preference.opened.contains(file.id)) {
        return;
      }
      if (manifest?.file(file.id)?.revision != doc.revision) {
        throw SessionUnavailable(
          'The document changed. Refresh to read the latest version.',
        );
      }
      setState(() {
        documents[file.id] = doc;
        errors.remove(file.id);
      });
    } catch (e) {
      if (mounted && token == epoch && preference.opened.contains(file.id)) {
        setState(
          () => errors[file.id] = e is ConnectionFailure
              ? e.message
              : 'This document could not be loaded. Try Refresh.',
        );
      }
    } finally {
      if (mounted && token == epoch) setState(() => loading.remove(file.id));
    }
  }

  void _select(String id) {
    focus.requestFocus();
    setState(() {
      preference.active = id;
      search.clear();
    });
    _save();
    final file = manifest?.file(id);
    if (file != null && documents[id]?.revision != file.revision) {
      unawaited(_load(file));
    }
  }

  void _open(ProjectFile file) {
    if (!preference.opened.contains(file.id)) {
      if (preference.opened.length >= 8) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Close a document before opening another.'),
          ),
        );
        return;
      }
      preference.opened.add(file.id);
    }
    _select(file.id);
  }

  void _closeFile(ProjectFile file) {
    setState(() {
      preference.opened.remove(file.id);
      documents.remove(file.id);
      errors.remove(file.id);
      if (preference.active == file.id) preference.active = file.section;
    });
    _save();
    focus.requestFocus();
  }

  Future<void> _link(ProjectFile file, String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if ({'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
      return;
    }
    if (uri.hasScheme || uri.hasAuthority) return;
    final path = Uri(path: file.path).resolveUri(uri).path;
    final match = manifest?.files.where((f) => f.path == path).firstOrNull;
    if (match != null) _open(match);
  }

  @override
  void dispose() {
    epoch++;
    timer?.cancel();
    widget.app.removeListener(_appChanged);
    widget.app.setProjectPanelFocused(widget.session.key.id, this, false);
    widget.app.setProjectPanelFocused(widget.session.key.id, coverOwner, false);
    search.dispose();
    focus.dispose();
    super.dispose();
  }

  Widget _tab(String id, String title, IconData icon, {ProjectFile? file}) {
    final selected = preference.active == id;
    return Container(
      decoration: BoxDecoration(
        color: selected ? context.tabs : null,
        border: Border(
          bottom: BorderSide(
            color: selected ? context.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            key: ValueKey('project-tab-$id'),
            onPressed: () => _select(id),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 44),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? context.accent : context.mutedInk,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 135),
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: context.ink),
                  ),
                ),
              ],
            ),
          ),
          if (file != null)
            IconButton(
              tooltip: 'Close ${file.name}',
              onPressed: () => _closeFile(file),
              icon: const Icon(Icons.close, size: 14),
              constraints: const BoxConstraints(minWidth: 30, minHeight: 44),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }

  Widget _row(ProjectFile file) => ListTile(
    key: ValueKey('project-file-${file.id}'),
    dense: true,
    leading: Icon(
      file.kind == 'html' ? Icons.code : Icons.description_outlined,
      size: 20,
      color: file.kind == 'html' ? context.attention : context.accent,
    ),
    title: Text(file.name, style: const TextStyle(fontSize: 13)),
    subtitle: Text(
      file.path == file.name
          ? (file.kind == 'html' ? 'HTML preview' : 'Markdown')
          : file.path,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10, color: context.mutedInk),
    ),
    trailing: const Icon(Icons.chevron_right, size: 17),
    onTap: () => _open(file),
  );
  Widget _list() {
    final specs = preference.active == 'specs',
        needle = search.text.toLowerCase();
    final items =
        manifest?.files
            .where(
              (f) =>
                  f.section == (specs ? 'specs' : 'files') &&
                  (needle.isEmpty ||
                      '${f.path} ${f.feature}'.toLowerCase().contains(needle)),
            )
            .toList() ??
        <ProjectFile>[];
    final features = items.map((f) => f.feature).toSet().toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            key: const ValueKey('project-search'),
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: specs ? 'Find a spec…' : 'Find a file…',
              prefixIcon: const Icon(Icons.search, size: 18),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              specs
                  ? '.kiro/specs/ and .specs/'
                  : 'Markdown and HTML in this project',
              style: TextStyle(color: context.mutedInk, fontSize: 10),
            ),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      busy && manifest == null
                          ? 'Loading project files…'
                          : specs
                          ? 'No matching Kiro specs.'
                          : 'No matching Markdown or HTML files.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.mutedInk),
                    ),
                  ),
                )
              : ListView(
                  key: PageStorageKey('project-list-${preference.active}'),
                  children: specs
                      ? features
                            .map(
                              (feature) => ExpansionTile(
                                key: PageStorageKey('feature-$feature'),
                                initiallyExpanded: true,
                                leading: Icon(
                                  Icons.folder_outlined,
                                  size: 19,
                                  color: context.accent,
                                ),
                                title: Text(
                                  feature,
                                  style: const TextStyle(fontSize: 13),
                                ),
                                children: items
                                    .where((f) => f.feature == feature)
                                    .map(_row)
                                    .toList(),
                              ),
                            )
                            .toList()
                      : items.map(_row).toList(),
                ),
        ),
      ],
    );
  }

  Widget _document(ProjectFile file) {
    final doc = documents[file.id], problem = errors[file.id];
    return Column(
      children: [
        if (problem != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              doc == null
                  ? problem
                  : 'Showing the last readable version. $problem',
              style: TextStyle(fontSize: 11, color: context.attention),
            ),
          ),
        Expanded(
          child: doc != null
              ? ProjectFileViewer(
                  key: ValueKey('project-viewer-${file.id}'),
                  file: file,
                  document: doc,
                  onLink: (link) => unawaited(_link(file, link)),
                )
              : Center(
                  child: loading.contains(file.id)
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: () => unawaited(_load(file)),
                          child: const Text('Retry document'),
                        ),
                ),
        ),
      ],
    );
  }

  Widget _panel(bool narrow) => Focus(
    focusNode: focus,
    onFocusChange: (value) =>
        widget.app.setProjectPanelFocused(widget.session.key.id, this, value),
    child: Listener(
      onPointerDown: (_) {
        focus.requestFocus();
        widget.app.setProjectPanelFocused(widget.session.key.id, this, true);
      },
      child: Material(
        color: context.workspace,
        child: Column(
          children: [
            Container(
              color: context.panel,
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
              child: Row(
                children: [
                  if (narrow)
                    IconButton(
                      tooltip: 'Back to session',
                      onPressed: _toggle,
                      icon: const Icon(Icons.arrow_back, size: 20),
                    ),
                  const Icon(Icons.folder_outlined, size: 19),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Project files',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          manifest?.folder ?? 'Current session',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: context.mutedInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh project files',
                    onPressed: busy ? null : () => unawaited(_refresh()),
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                  if (!narrow)
                    IconButton(
                      tooltip: 'Close project files',
                      onPressed: _toggle,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: context.border)),
              ),
              child: Row(
                children: [
                  _tab('files', 'Files', Icons.folder_outlined),
                  _tab('specs', 'Specs', Icons.checklist),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: preference.opened
                            .map((id) => manifest?.file(id))
                            .whereType<ProjectFile>()
                            .map(
                              (f) => _tab(
                                f.id,
                                f.name,
                                f.kind == 'html'
                                    ? Icons.code
                                    : Icons.description_outlined,
                                file: f,
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Offstage(
                    offstage: !const [
                      'files',
                      'specs',
                    ].contains(preference.active),
                    child: _list(),
                  ),
                  for (final id in preference.opened)
                    if (manifest?.file(id) case final ProjectFile file)
                      Offstage(
                        key: ValueKey('project-content-$id'),
                        offstage: preference.active != id,
                        child: TickerMode(
                          enabled: preference.active == id,
                          child: _document(file),
                        ),
                      ),
                ],
              ),
            ),
            Container(
              constraints: const BoxConstraints(minHeight: 25),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: context.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      error ??
                          (manifest?.limited == true
                              ? 'Some files were omitted by the preview limits.'
                              : busy
                              ? 'Refreshing…'
                              : 'Read only'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: error == null
                            ? context.mutedInk
                            : context.attention,
                      ),
                    ),
                  ),
                  if (error != null)
                    TextButton(
                      onPressed: busy ? null : () => unawaited(_refresh()),
                      child: const Text(
                        'Retry',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < 900,
          visible = preference.visible && widget.app.supportsProjectFiles;
      widget.app.setProjectPanelFocused(
        widget.session.key.id,
        coverOwner,
        visible && narrow,
      );
      final child = KeyedSubtree(
        key: sessionSlot,
        child: Listener(
          onPointerDown: (_) => widget.app.setProjectPanelFocused(
            widget.session.key.id,
            this,
            false,
          ),
          child: widget.builder(_toggle, visible, visible && narrow),
        ),
      );
      if (!visible) return child;
      if (narrow) {
        return Stack(
          children: [
            ExcludeFocus(child: IgnorePointer(child: child)),
            Positioned.fill(child: _panel(true)),
          ],
        );
      }
      final width = preference.width.clamp(
        300.0,
        (box.maxWidth - 420).clamp(300.0, 700.0),
      );
      return Row(
        children: [
          Expanded(child: child),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) => setState(
                () => preference.width = (preference.width - details.delta.dx)
                    .clamp(300.0, (box.maxWidth - 420).clamp(300.0, 700.0)),
              ),
              onHorizontalDragEnd: (_) => _save(),
              child: Container(width: 5, color: context.border),
            ),
          ),
          SizedBox(width: width, child: _panel(false)),
        ],
      );
    },
  );
}
