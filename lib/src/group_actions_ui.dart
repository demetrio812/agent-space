import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'storage.dart';

List<PopupMenuEntry<String>> _items() => const [
  PopupMenuItem(value: 'rename', child: Text('Rename')),
  PopupMenuItem(value: 'delete', child: Text('Delete group…')),
];

Future<void> _selectAction(
  BuildContext context,
  AppController app,
  WorkspaceLayout layout,
  TabGroup group,
  String action,
) async {
  bool current() =>
      identical(app.layout, layout) && layout.groups.contains(group);
  if (!current()) return;
  if (action == 'rename') {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameGroupDialog(name: group.name),
    );
    if (name != null && current()) app.renameGroup(group.id, name);
  } else if (action == 'delete') {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete group?'),
        content: Text(
          'Remove “${group.name}” from this device? Only the group will be removed. Its Herdr sessions will keep running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete group'),
          ),
        ],
      ),
    );
    if (confirmed == true && current()) app.deleteGroup(group.id);
  }
}

Future<void> showGroupContextMenu(
  BuildContext context,
  AppController app,
  TabGroup group,
  Offset position,
) async {
  final layout = app.layout;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final point = overlay.globalToLocal(position);
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromSize(
      Rect.fromLTWH(point.dx, point.dy, 0, 0),
      overlay.size,
    ),
    items: _items(),
  );
  if (action != null && context.mounted) {
    await _selectAction(context, app, layout, group, action);
  }
}

class GroupActionsButton extends StatelessWidget {
  const GroupActionsButton({super.key, required this.app, required this.group});
  final AppController app;
  final TabGroup group;

  @override
  Widget build(BuildContext context) {
    final layout = app.layout;
    return PopupMenuButton<String>(
      key: ValueKey('group-menu-${group.id}'),
      tooltip: 'Actions for ${group.name}',
      icon: const Icon(Icons.more_horiz, color: Color(0xffbdcada), size: 18),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
      itemBuilder: (_) => _items(),
      onSelected: (action) =>
          unawaited(_selectAction(context, app, layout, group, action)),
    );
  }
}

class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.name});
  final String name;
  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final name = TextEditingController(text: widget.name);
  String get value => displayText(name.text).trim();
  void save() {
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename group'),
    content: SizedBox(
      width: 320,
      child: TextField(
        key: const ValueKey('group-name'),
        controller: name,
        autofocus: true,
        maxLength: 80,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(labelText: 'Group name'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: value.isEmpty ? null : save,
        child: const Text('Save'),
      ),
    ],
  );
}
