import 'dart:async';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'controller.dart';
import 'models.dart';
import 'network_models.dart';
import 'ui_common.dart';

List<PopupMenuEntry<String>> sessionActionItems(
  AppController app,
  SessionInfo session, {
  bool window = false,
  bool groupCreation = true,
}) => [
  PopupMenuItem(
    value: 'rename',
    enabled: app.canManageSession(session),
    child: const Text('Rename'),
  ),
  PopupMenuItem(
    value: 'close',
    enabled: app.canManageSession(session),
    child: const Text('Close terminal…'),
  ),
  if (app.layout.uncertainActions.containsKey(session.computerId))
    const PopupMenuItem(
      value: 'inspect',
      child: Text('Check unconfirmed action…'),
    ),
  const PopupMenuDivider(),
  if (window)
    const PopupMenuItem(value: 'window', child: Text('Open in a window')),
  for (final group in app.layout.groups)
    PopupMenuItem(
      value: 'group:${group.id}',
      child: Text('Add to ${group.name}'),
    ),
  if (groupCreation)
    const PopupMenuItem(value: 'new-group', child: Text('Create a group')),
  if (!app.canManageSession(session) &&
      !app.layout.uncertainActions.containsKey(session.computerId))
    const PopupMenuItem(
      enabled: false,
      child: Text('Session actions need a connected, writable Herdr.'),
    ),
];

Future<void> _selectAction(
  BuildContext context,
  AppController app,
  SessionInfo session,
  String value, {
  VoidCallback? newGroup,
  OpenDesktopWindow? openWindow,
}) async {
  if (!context.mounted) return;
  switch (value) {
    case 'rename':
      await showRenameSession(context, app, session);
    case 'close':
      await confirmCloseSession(context, app, session);
    case 'inspect':
      await showSessionActionInspection(context, app, session.computerId);
    case 'new-group':
      newGroup?.call();
    case 'window':
      if (openWindow != null) await openWindow('session', session.key.id);
    default:
      if (value.startsWith('group:')) {
        app.moveToGroup(session.key.id, value.substring(6));
      }
  }
}

Future<void> showSessionActions(
  BuildContext context,
  AppController app,
  SessionInfo session,
  Offset position, {
  VoidCallback? newGroup,
  OpenDesktopWindow? openWindow,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final point = overlay.globalToLocal(position);
  final value = await showMenu<String>(
    context: context,
    position: RelativeRect.fromSize(
      Rect.fromLTWH(point.dx, point.dy, 0, 0),
      overlay.size,
    ),
    items: sessionActionItems(
      app,
      session,
      window: openWindow != null,
      groupCreation: newGroup != null,
    ),
  );
  if (value != null && context.mounted) {
    await _selectAction(
      context,
      app,
      session,
      value,
      newGroup: newGroup,
      openWindow: openWindow,
    );
  }
}

class SessionActionsButton extends StatelessWidget {
  const SessionActionsButton({
    super.key,
    required this.app,
    required this.session,
    this.newGroup,
    this.openWindow,
  });
  final AppController app;
  final SessionInfo session;
  final VoidCallback? newGroup;
  final OpenDesktopWindow? openWindow;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: ValueKey('session-menu-${session.key.id}'),
    tooltip: 'Session actions',
    padding: EdgeInsets.zero,
    iconSize: 18,
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
    itemBuilder: (_) => sessionActionItems(
      app,
      session,
      window: openWindow != null,
      groupCreation: newGroup != null,
    ),
    onSelected: (value) => unawaited(
      _selectAction(
        context,
        app,
        session,
        value,
        newGroup: newGroup,
        openWindow: openWindow,
      ),
    ),
  );
}

Future<void> showRenameSession(
  BuildContext context,
  AppController app,
  SessionInfo session,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _SessionActionDialog(app: app, operation: 'rename', session: session),
);
Future<void> confirmCloseSession(
  BuildContext context,
  AppController app,
  SessionInfo session,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _SessionActionDialog(app: app, operation: 'close', session: session),
);
Future<void> showCreateSession(BuildContext context, AppController app) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SessionActionDialog(app: app, operation: 'create'),
    );

Future<void> showSessionActionInspection(
  BuildContext context,
  AppController app,
  String computerId,
) async {
  final record = app.layout.uncertainActions[computerId];
  if (record == null) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AnimatedBuilder(
      animation: app,
      builder: (_, _) => AlertDialog(
        title: const Text('Check the sessions'),
        content: Text(
          'An earlier ${record.operation} action on ${app.computerLabel(computerId, origin: record.origin)} may have completed. Refresh and inspect that computer’s sessions before trying another session action. Typing remains available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => unawaited(app.refresh()),
            child: const Text('Refresh sessions'),
          ),
          FilledButton(
            onPressed: app.sessionActionStates[computerId]?.pending == true
                ? null
                : () {
                    if (identical(
                      app.layout.uncertainActions[computerId],
                      record,
                    )) {
                      app.acknowledgeSessionAction(computerId);
                    }
                    Navigator.pop(dialogContext);
                  },
            child: const Text('I’ve checked'),
          ),
        ],
      ),
    ),
  );
}

class _SessionActionDialog extends StatefulWidget {
  const _SessionActionDialog({
    required this.app,
    required this.operation,
    this.session,
  });
  final AppController app;
  final String operation;
  final SessionInfo? session;
  @override
  State<_SessionActionDialog> createState() => _SessionActionDialogState();
}

class _SessionActionDialogState extends State<_SessionActionDialog> {
  late final title = TextEditingController(
    text: widget.operation == 'rename' ? widget.session!.title : '',
  );
  final folder = TextEditingController();
  late final source = widget.app.source;
  SessionOrigin? origin;
  String? workspaceId, error;
  bool pending = false;
  bool get creating => widget.operation == 'create';
  @override
  void initState() {
    super.initState();
    origin =
        widget.session?.origin ??
        widget.app.manageableComputers.firstOrNull?.origin;
    final computer = widget.app.manageableComputers
        .where((c) => c.origin.computerId == origin?.computerId)
        .firstOrNull;
    workspaceId = computer?.workspaces.firstOrNull?.id;
  }

  @override
  void dispose() {
    title.dispose();
    folder.dispose();
    super.dispose();
  }

  Future<void> submit(SessionWorkspace? workspace) async {
    if (pending) return;
    setState(() {
      pending = true;
      error = null;
    });
    try {
      if (source != widget.app.source) {
        throw SessionUnavailable(
          'The selected connection changed. Close this dialog and choose again.',
        );
      }
      switch (widget.operation) {
        case 'rename':
          await widget.app.renameSession(widget.session!, title.text);
        case 'close':
          await widget.app.closeSession(widget.session!);
        case 'create':
          if (origin == null || workspace == null) {
            throw SessionUnavailable('Choose a computer and workspace.');
          }
          await widget.app.createSession(
            origin!,
            workspace,
            title: title.text,
            cwd: folder.text,
          );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              error = e is ArgumentError ? e.message.toString() : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => pending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      final app = widget.app, computers = app.manageableComputers;
      final computer = computers
          .where(
            (c) =>
                c.origin.computerId == origin?.computerId &&
                sameSessionOrigin(c.origin, origin!),
          )
          .firstOrNull;
      final workspace = computer?.workspaces
          .where((w) => w.id == workspaceId)
          .firstOrNull;
      final valid =
          source == app.source &&
          origin != null &&
          (creating
              ? computer != null &&
                    workspace != null &&
                    app.canManageComputer(origin!)
              : app.canManageSession(widget.session!));
      final uncertain =
          origin != null &&
          app.layout.uncertainActions.containsKey(origin!.computerId) &&
          !pending;
      final action = switch (widget.operation) {
        'rename' => 'Rename',
        'close' => 'Close terminal',
        _ => 'Create session',
      };
      return PopScope(
        canPop: !pending,
        child: AlertDialog(
          title: Text(switch (widget.operation) {
            'rename' => 'Rename terminal',
            'close' => 'Close terminal?',
            _ => 'New session',
          }),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (creating) ...[
                    if (computers.isEmpty)
                      const Text(
                        'No connected computers support session actions. Connect to a writable Herdr with a compatible helper.',
                      ),
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'Computer'),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: const ValueKey('new-session-computer'),
                          isExpanded: true,
                          value:
                              computers.any(
                                (c) =>
                                    c.origin.computerId == origin?.computerId,
                              )
                              ? origin?.computerId
                              : null,
                          hint: const Text('Choose computer'),
                          items: [
                            for (final c in computers)
                              DropdownMenuItem(
                                value: c.origin.computerId,
                                child: Text(
                                  app.computerLabel(
                                    c.origin.computerId,
                                    origin: c.origin,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: pending
                              ? null
                              : (id) => setState(() {
                                  origin = computers
                                      .singleWhere(
                                        (c) => c.origin.computerId == id,
                                      )
                                      .origin;
                                  workspaceId = null;
                                  folder.clear();
                                  error = null;
                                }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    InputDecorator(
                      decoration: const InputDecoration(labelText: 'Workspace'),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          key: const ValueKey('new-session-workspace'),
                          isExpanded: true,
                          value: workspace?.id,
                          hint: const Text('Choose workspace'),
                          items: [
                            for (final w
                                in computer?.workspaces ?? <SessionWorkspace>[])
                              DropdownMenuItem(
                                value: w.id,
                                child: Text(
                                  w.label.isEmpty ? w.id : w.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: pending
                              ? null
                              : (id) => setState(() => workspaceId = id),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (widget.operation == 'close')
                    Text(
                      'This ends the running terminal “${widget.session!.title}” on ${app.computerLabel(widget.session!.computerId, origin: widget.session!.origin)}. Any process in it will stop.',
                    ),
                  if (widget.operation != 'close')
                    TextField(
                      key: const ValueKey('session-title'),
                      controller: title,
                      enabled: !pending,
                      autofocus: !creating,
                      maxLength: 128,
                      decoration: InputDecoration(
                        labelText: creating ? 'Title (optional)' : 'Title',
                      ),
                      onChanged: (_) => setState(() => error = null),
                    ),
                  if (creating) ...[
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('session-folder'),
                      controller: folder,
                      enabled: !pending,
                      decoration: const InputDecoration(
                        labelText: 'Folder (optional)',
                        hintText: '/path or ~/project',
                        helperText: 'Leave empty to use Herdr’s default.',
                      ),
                      onChanged: (_) => setState(() => error = null),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Creates a shell terminal. Start your agent from its command prompt.',
                    ),
                  ],
                  if (!valid && !pending && !uncertain)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text(
                        'The computer or session is unavailable, changed, or does not support this action.',
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (uncertain)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Close this dialog and inspect the sessions. Use “Check unconfirmed session action” in the toolbar when you have checked.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: pending ? null : () => Navigator.pop(context),
              child: Text(uncertain ? 'Close' : 'Cancel'),
            ),
            FilledButton(
              onPressed: valid && !pending ? () => submit(workspace) : null,
              child: Text(pending ? 'Working…' : action),
            ),
          ],
        ),
      );
    },
  );
}
