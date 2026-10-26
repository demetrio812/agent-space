import 'dart:async';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';
import 'network_models.dart';
import 'session_actions_ui.dart';

List<PopupMenuEntry<String>> _items(
  AppController app,
  SessionOrigin origin,
  SessionWorkspace workspace,
) => [
  PopupMenuItem(
    value: 'favourite',
    child: Text(
      app.isWorkspaceFavourite(scopedWorkspaceId(origin, workspace.id))
          ? 'Remove from favourites'
          : 'Add to favourites',
    ),
  ),
  const PopupMenuDivider(),
  PopupMenuItem(
    value: 'rename',
    enabled: app.canManageWorkspace(origin, workspace),
    child: const Text('Rename'),
  ),
  PopupMenuItem(
    value: 'close',
    enabled: app.canManageWorkspace(origin, workspace),
    child: const Text('Close workspace…'),
  ),
  if (app.layout.uncertainActions.containsKey(origin.computerId))
    const PopupMenuItem(
      value: 'inspect',
      child: Text('Check unconfirmed action…'),
    ),
];

Future<void> _action(
  BuildContext context,
  AppController app,
  SessionOrigin origin,
  SessionWorkspace workspace,
  String action,
) async {
  if (!context.mounted) return;
  if (action == 'favourite') {
    app.toggleWorkspaceFavourite(scopedWorkspaceId(origin, workspace.id));
    return;
  }
  if (action == 'inspect') {
    await showSessionActionInspection(context, app, origin.computerId);
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WorkspaceDialog(
      app: app,
      origin: origin,
      workspace: workspace,
      closing: action == 'close',
    ),
  );
}

Future<void> showWorkspaceContextMenu(
  BuildContext context,
  AppController app,
  SessionOrigin origin,
  SessionWorkspace workspace,
  Offset position,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final point = overlay.globalToLocal(position);
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromSize(
      Rect.fromLTWH(point.dx, point.dy, 0, 0),
      overlay.size,
    ),
    items: _items(app, origin, workspace),
  );
  if (action != null && context.mounted) {
    await _action(context, app, origin, workspace, action);
  }
}

class WorkspaceActionsButton extends StatelessWidget {
  const WorkspaceActionsButton({
    super.key,
    required this.app,
    required this.origin,
    required this.workspace,
  });
  final AppController app;
  final SessionOrigin origin;
  final SessionWorkspace workspace;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: ValueKey('workspace-menu-${scopedWorkspaceId(origin, workspace.id)}'),
    tooltip: 'Workspace actions',
    padding: EdgeInsets.zero,
    iconSize: 16,
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
    itemBuilder: (_) => _items(app, origin, workspace),
    onSelected: (value) =>
        unawaited(_action(context, app, origin, workspace, value)),
  );
}

class _WorkspaceDialog extends StatefulWidget {
  const _WorkspaceDialog({
    required this.app,
    required this.origin,
    required this.workspace,
    required this.closing,
  });
  final AppController app;
  final SessionOrigin origin;
  final SessionWorkspace workspace;
  final bool closing;
  @override
  State<_WorkspaceDialog> createState() => _WorkspaceDialogState();
}

class _WorkspaceDialogState extends State<_WorkspaceDialog> {
  late final name = TextEditingController(text: widget.workspace.label);
  bool pending = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      pending = true;
      error = null;
    });
    try {
      if (widget.closing) {
        await widget.app.closeWorkspace(widget.origin, widget.workspace);
      } else {
        await widget.app.renameWorkspace(
          widget.origin,
          widget.workspace,
          name.text.trim(),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          pending = false;
          error = e is SessionActionUncertain
              ? e.toString()
              : 'Could not update this workspace. $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.app,
    builder: (context, _) {
      final app = widget.app;
      final ready = app.canManageWorkspace(widget.origin, widget.workspace);
      final count = app.sessions
          .where(
            (s) =>
                s.computerId == widget.origin.computerId &&
                s.workspaceId == widget.workspace.id,
          )
          .length;
      return PopScope(
        canPop: !pending,
        child: AlertDialog(
          title: Text(widget.closing ? 'Close workspace?' : 'Rename workspace'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    app.computerLabel(
                      widget.origin.computerId,
                      origin: widget.origin,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (widget.closing)
                    Text(
                      'Close “${widget.workspace.label}” and end all its terminals and running processes on this computer? Currently $count ${count == 1 ? 'terminal is' : 'terminals are'} listed. Files in the project folder are kept.',
                    )
                  else
                    TextField(
                      key: const ValueKey('workspace-name'),
                      controller: name,
                      enabled: !pending,
                      autofocus: true,
                      maxLength: 128,
                      decoration: const InputDecoration(
                        labelText: 'Workspace name',
                      ),
                      onChanged: (_) => setState(() => error = null),
                    ),
                  if (!ready && !pending)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'This workspace is unavailable or has an unconfirmed action. Close this dialog and check its computer.',
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: pending ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  pending ||
                      !ready ||
                      (!widget.closing && name.text.trim().isEmpty)
                  ? null
                  : submit,
              child: Text(
                pending
                    ? 'Working…'
                    : widget.closing
                    ? 'Close workspace'
                    : 'Save',
              ),
            ),
          ],
        ),
      );
    },
  );
}
