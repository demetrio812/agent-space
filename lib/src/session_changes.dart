import 'dart:async';

import 'package:flutter/material.dart';

import 'backend_errors.dart';
import 'controller.dart';
import 'git_changes.dart';
import 'git_change_tree.dart';
import 'models.dart';
import 'ui_common.dart';

/// All reads stay bound to this pane. No terminal or Git mutation controls.
class SessionChanges extends StatefulWidget {
  const SessionChanges({
    super.key,
    required this.app,
    required this.session,
    required this.active,
  });
  final AppController app;
  final SessionInfo session;
  final bool active;
  @override
  State<SessionChanges> createState() => _SessionChangesState();
}

class _SessionChangesState extends State<SessionChanges> {
  GitChangePage? page;
  GitChange? selected;
  GitDiff? diff;
  String? error;
  bool refreshing = false, reading = false;
  int epoch = 0, readEpoch = 0;
  Timer? timer;
  final filter = TextEditingController();
  final collapsedFolders = <String>{};
  final collapsedMatches = <String>{};
  bool get live => widget.active && widget.app.isActive;
  bool _current(int token) => mounted && live && token == epoch;
  Object _target(SessionInfo s) => (
    s.key,
    s.paneId,
    s.origin?.machineId,
    s.origin?.herdrSession,
    s.origin?.targetHash,
    s.origin?.generation,
  );
  @override
  void initState() {
    super.initState();
    if (live) unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant SessionChanges old) {
    super.didUpdateWidget(old);
    if (old.app != widget.app ||
        old.active != widget.active ||
        _target(old.session) != _target(widget.session)) {
      epoch++;
      readEpoch++;
      timer?.cancel();
      refreshing = false;
      reading = false;
      if (old.app != widget.app ||
          _target(old.session) != _target(widget.session)) {
        page = null;
        selected = null;
        diff = null;
        error = null;
        filter.clear();
        collapsedFolders.clear();
        collapsedMatches.clear();
      }
      if (live) unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    epoch++;
    readEpoch++;
    timer?.cancel();
    filter.dispose();
    super.dispose();
  }

  String _problem(Object e) => e is ConnectionFailure
      ? e.message
      : 'Could not load Git changes. Try Refresh.';
  Future<void> _refresh() async {
    if (!live || refreshing || reading || !widget.app.supportsGitChanges) {
      return;
    }
    final token = epoch;
    setState(() => refreshing = true);
    timer?.cancel();
    try {
      final result = await widget.app.listGitChanges(widget.session);
      if (!_current(token)) return;
      GitChange? next;
      if (selected != null) {
        for (final e in result.entries) {
          if (e.path == selected!.path && e.section == selected!.section) {
            next = e;
            break;
          }
        }
      }
      final changed = page?.scope != result.scope;
      setState(() {
        page = result;
        error = null;
        selected = next;
        if (changed || next == null) diff = null;
      });
      if ((changed || diff == null) && next != null) unawaited(_read(next));
    } catch (e) {
      if (_current(token)) setState(() => error = _problem(e));
    } finally {
      if (_current(token)) {
        setState(() => refreshing = false);
        _schedule();
      }
    }
  }

  void _schedule() {
    timer?.cancel();
    if (live) {
      timer = Timer(const Duration(seconds: 5), () => unawaited(_refresh()));
    }
  }

  Future<void> _read(GitChange entry) async {
    final folder = page;
    if (!live || folder == null) return;
    final token = epoch, request = ++readEpoch;
    setState(() {
      selected = entry;
      diff = null;
      reading = true;
      error = null;
    });
    try {
      final value = await widget.app.readGitDiff(
        widget.session,
        folder.scope,
        entry.id,
      );
      if (!_current(token) ||
          request != readEpoch ||
          page?.scope != folder.scope) {
        return;
      }
      setState(() => diff = value);
    } catch (e) {
      if (_current(token) && request == readEpoch) {
        setState(() => error = _problem(e));
      }
    } finally {
      if (_current(token) && request == readEpoch) {
        setState(() => reading = false);
        _schedule();
      }
    }
  }

  void _back() {
    readEpoch++;
    setState(() {
      selected = null;
      diff = null;
      reading = false;
      error = null;
    });
    _schedule();
  }

  Widget _empty(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: context.mutedInk),
      ),
    ),
  );

  List<Widget> _treeRows(
    String section,
    List<GitChange> entries,
    bool filtering,
  ) {
    final rows = <Widget>[];
    final pending = [
      for (final node in gitChangeTree(entries).reversed) (node, 0),
    ];
    while (pending.isNotEmpty) {
      final (node, depth) = pending.removeLast();
      final inset = 12.0 + depth.clamp(0, 6) * 14;
      final entry = node.change;
      if (entry == null) {
        final id = '$section:${node.path}';
        final collapsed = filtering ? collapsedMatches : collapsedFolders;
        // Compaction can change "src" to "src/api" after a refresh.
        // An explicitly collapsed ancestor still owns its descendants.
        bool containsPath(String folder) =>
            id == folder || id.startsWith('$folder/');
        final expanded = !collapsed.any(containsPath);
        rows.add(
          Semantics(
            expanded: expanded,
            child: ListTile(
              key: ValueKey('changes-folder-$section-${node.path}'),
              dense: true,
              contentPadding: EdgeInsets.only(left: inset, right: 12),
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    expanded
                        ? Icons.folder_open_outlined
                        : Icons.folder_outlined,
                    size: 18,
                    color: context.accent,
                  ),
                ],
              ),
              title: Tooltip(
                message: node.path,
                child: Text(
                  node.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              trailing: Text(
                '${node.count}',
                style: TextStyle(fontSize: 11, color: context.mutedInk),
              ),
              onTap: () => setState(() {
                if (expanded) {
                  collapsed.add(id);
                } else {
                  collapsed.removeWhere(containsPath);
                }
              }),
            ),
          ),
        );
        if (expanded) {
          pending.addAll(
            node.children.reversed.map((child) => (child, depth + 1)),
          );
        }
      } else {
        rows.add(
          ListTile(
            key: ValueKey('changes-file-$section-${entry.path}'),
            dense: true,
            contentPadding: EdgeInsets.only(left: inset, right: 12),
            leading: Text(
              entry.status,
              style: TextStyle(
                color: entry.status == 'D'
                    ? context.attention
                    : context.success,
                fontWeight: FontWeight.bold,
              ),
            ),
            title: Tooltip(
              message: entry.path,
              child: Text(
                node.name,
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            subtitle: Text(
              entry.oldPath.isEmpty
                  ? entry.label
                  : '${entry.label} from ${entry.oldPath}',
              style: TextStyle(fontSize: 10, color: context.mutedInk),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => unawaited(_read(entry)),
          ),
        );
      }
    }
    return rows;
  }

  Widget _list() {
    final value = page;
    if (value == null) {
      return _empty(
        refreshing
            ? 'Loading changes…'
            : 'Open Changes to inspect this repository.',
      );
    }
    if (!value.repository) {
      return _empty('No Git repository in this session’s folder.');
    }
    if (value.entries.isEmpty) return _empty('Working tree clean.');
    final query = filter.text.toLowerCase();
    final entries = value.entries
        .where((e) => e.path.toLowerCase().contains(query))
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: TextField(
            controller: filter,
            onChanged: (_) => setState(collapsedMatches.clear),
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'Filter changed files…',
              prefixIcon: Icon(Icons.search, size: 17),
              contentPadding: EdgeInsets.all(9),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _empty('No matching changes.')
              : ListView(
                  children: [
                    for (final group in [
                      ('staged', 'Staged'),
                      ('unstaged', 'Unstaged'),
                      ('untracked', 'Untracked'),
                    ])
                      if (entries.any((e) => e.section == group.$1)) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                          child: Text(
                            '${group.$2} · ${entries.where((e) => e.section == group.$1).length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: context.mutedInk,
                            ),
                          ),
                        ),
                        ..._treeRows(
                          group.$1,
                          entries.where((e) => e.section == group.$1).toList(),
                          query.isNotEmpty,
                        ),
                      ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _diff() {
    final value = diff;
    if (reading) return _empty('Loading diff…');
    if (value == null) return _empty('Refresh to load this diff.');
    if (value.notice.isNotEmpty) return _empty(value.notice);
    if (value.text.isEmpty) return _empty('No text differences available.');
    final spans = <TextSpan>[];
    final pending = StringBuffer();
    Color? last;
    for (final line in value.text.split('\n')) {
      final colour = line.startsWith('+')
          ? context.success
          : line.startsWith('-')
          ? context.attention
          : line.startsWith('@@')
          ? context.accent
          : context.ink;
      if (last != null && colour != last) {
        spans.add(
          TextSpan(
            text: pending.toString(),
            style: TextStyle(color: last),
          ),
        );
        pending.clear();
      }
      pending.writeln(line);
      last = colour;
    }
    if (pending.isNotEmpty) {
      spans.add(
        TextSpan(
          text: pending.toString(),
          style: TextStyle(color: last),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        key: ValueKey('diff-${value.file}'),
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: (box.maxWidth - 24).clamp(0, double.infinity),
            ),
            child: SelectableText.rich(
              TextSpan(children: spans),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.5,
                color: context.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.app.supportsGitChanges) {
      return _empty('Changes are unavailable for this connection.');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          child: Row(
            children: [
              if (selected != null)
                IconButton(
                  tooltip: 'Back to changes',
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back, size: 18),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected?.path ?? page?.folder ?? 'Changes',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (page?.repository == true)
                      Text(
                        page!.branch,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: context.mutedInk),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh changes',
                onPressed: refreshing || reading
                    ? null
                    : () => unawaited(_refresh()),
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        if (refreshing || reading) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              '$error${page == null ? '' : ' The list shown may be out of date.'}',
              style: TextStyle(color: context.attention, fontSize: 11),
            ),
          ),
        Expanded(child: selected == null ? _list() : _diff()),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              page?.limited == true
                  ? 'Read only · Showing the first 500 supported changes.'
                  : 'Read only · No files or Git state are changed',
              style: TextStyle(color: context.mutedInk, fontSize: 10),
            ),
          ),
        ),
      ],
    );
  }
}
