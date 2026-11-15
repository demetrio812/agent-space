import 'git_changes.dart';

class GitChangeNode {
  GitChangeNode.file(GitChange entry)
    : name = entry.path.split('/').last,
      path = entry.path,
      change = entry,
      children = const [],
      count = 1;
  GitChangeNode.folder(this.name, this.path, this.children)
    : change = null,
      count = children.fold(0, (sum, child) => sum + child.count);

  final String name, path;
  final GitChange? change;
  final List<GitChangeNode> children;
  final int count;
}

/// Compact single-folder chains, so even unusually deep paths stay manageable.
/// Only branching folders and file leaves need nodes (at most twice the files).
List<GitChangeNode> gitChangeTree(Iterable<GitChange> entries) =>
    _group(entries.map((e) => (e, e.path.split('/'))).toList(), '');

List<GitChangeNode> _group(
  List<(GitChange, List<String>)> entries,
  String prefix,
) {
  final folders = <String, List<(GitChange, List<String>)>>{};
  final result = <GitChangeNode>[];
  for (final entry in entries) {
    if (entry.$2.length == 1) {
      result.add(GitChangeNode.file(entry.$1));
    } else {
      folders.putIfAbsent(entry.$2.first, () => []).add(entry);
    }
  }
  for (final group in folders.values) {
    final parts = group.first.$2;
    var common = 1;
    while (common < parts.length - 1 &&
        group.every(
          (e) => common < e.$2.length - 1 && e.$2[common] == parts[common],
        )) {
      common++;
    }
    final name = parts.take(common).join('/');
    final path = prefix.isEmpty ? name : '$prefix/$name';
    result.add(
      GitChangeNode.folder(
        name,
        path,
        _group(group.map((e) => (e.$1, e.$2.sublist(common))).toList(), path),
      ),
    );
  }
  result.sort((a, b) {
    final kind = (a.change == null ? 0 : 1).compareTo(b.change == null ? 0 : 1);
    if (kind != 0) return kind;
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name != 0 ? name : a.name.compareTo(b.name);
  });
  return result;
}
