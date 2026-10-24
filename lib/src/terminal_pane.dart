import 'dictation_dialog.dart';
import 'git_metadata_view.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:xterm/xterm.dart' hide TerminalState;

import 'controller.dart';
import 'mobile_terminal_controls.dart';
import 'terminal_drop_target.dart';
import 'models.dart';
import 'ui_common.dart';
import 'session_drag.dart';
import 'session_actions_ui.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.app,
    required this.session,
    this.openWindow,
    required this.compact,
    this.mobileControls = false,
    this.embedded = false,
    this.active = true,
    this.visible = true,
  });
  final AppController app;
  final SessionInfo session;
  final OpenDesktopWindow? openWindow;
  final bool compact;
  final bool mobileControls;
  final bool embedded, active, visible;
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final draft = TextEditingController();
  final draftFocus = FocusNode();
  final terminalController = TerminalController();
  Terminal? lastTerminal;
  bool composerOpen = false;
  bool dictationOpen = false;

  Future<void> dictate() async {
    if (dictationOpen) return;
    final session = widget.session, app = widget.app;
    final generation = app.dictationGeneration;
    dictationOpen = true;
    String? text;
    try {
      text = await showDictation(context, app, session);
    } finally {
      dictationOpen = false;
    }
    if (!mounted ||
        text == null ||
        !app.dictationTargetIsCurrent(session, generation)) {
      return;
    }
    final existing = app.layout.drafts[session.key.id] ?? '';
    final combined = existing.isEmpty ? text : '$existing\n$text';
    app.updateDraft(session.key.id, combined);
    setState(() {
      composerOpen = true;
      draft.text = combined;
      draft.selection = TextSelection.collapsed(offset: combined.length);
    });
    draftFocus.requestFocus();
  }

  KeyEventResult handleDictationShortcut(KeyEvent event) {
    if (!mounted ||
        !widget.active ||
        defaultTargetPlatform != TargetPlatform.macOS ||
        !widget.app.snapshot.dictationShortcut.matches(event) ||
        ModalRoute.of(context)?.isCurrent != true ||
        (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed) ||
        !widget.app.dictationTargetIsCurrent(
          widget.session,
          widget.app.dictationGeneration,
        )) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent && !dictationOpen) unawaited(dictate());
    return KeyEventResult.handled;
  }

  void toggleComposer() {
    setState(() => composerOpen = !composerOpen);
    if (composerOpen) {
      draftFocus.requestFocus();
    } else {
      draftFocus.unfocus();
    }
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(handleDictationShortcut);
    draft.text = widget.app.layout.drafts[widget.session.key.id] ?? '';
  }

  @override
  void didUpdateWidget(covariant TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final saved = widget.app.layout.drafts[widget.session.key.id] ?? '';
    if (oldWidget.session.key != widget.session.key || saved != draft.text) {
      draft.value = TextEditingValue(
        text: saved,
        selection: TextSelection.collapsed(offset: saved.length),
      );
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(handleDictationShortcut);
    draft.dispose();
    draftFocus.dispose();
    terminalController.dispose();
    super.dispose();
  }

  Future<void> copyTerminal() async {
    final screen = widget.app.terminals[widget.session.key.id]?.screen;
    if (screen?.terminal == null) return;
    final selection = terminalController.selection;
    final text = selection == null
        ? screen!.text.trimRight()
        : screen!.terminal!.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            selection == null ? 'Visible terminal copied' : 'Selection copied',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> showSessionInfo() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(widget.session.title),
      content: SelectionArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.session.terminalTitle.isEmpty
                  ? widget.session.title
                  : widget.session.terminalTitle,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            Text('Workspace: ${widget.session.workspaceLabel}'),
            Text('Project: ${widget.session.project}'),
            GitMetadataView(metadata: widget.session.git),
            Text('Agent: ${widget.session.agent}'),
            Text(
              'Status: ${widget.session.available ? widget.session.status.label : 'Unavailable'}',
            ),
            const SizedBox(height: 16),
            Text(
              'Scroll with a trackpad, mouse wheel or touch to browse history through the attached Herdr terminal. Available history depends on the pane and its application. Zoom and window size update the selected terminal dimensions when viewport control is available.',
              style: TextStyle(color: context.mutedInk),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final app = widget.app, session = widget.session;
    final computer = app.computerLabel(
      session.computerId,
      origin: session.origin,
    );
    final workspace = session.workspaceLabel.isNotEmpty
        ? session.workspaceLabel
        : session.project;
    final location = '$computer · $workspace';
    final entry = app.terminals[session.key.id];
    final state = app.sendStates[session.key.id];
    final connectionReady =
        app.connectionState == ConnectionState.live ||
        app.connectionState == ConnectionState.demo;
    final statusSummary =
        state?.message ??
        app.store.warning ??
        (!connectionReady
            ? app.connectionMessage
            : entry?.state != TerminalState.live
            ? entry?.message ?? 'Connecting terminal…'
            : 'Connected');
    final rows = app.sessionsForFilter(app.layout.filter);
    if (!rows.any((s) => s.key == session.key)) rows.add(session);
    final terminal = entry?.screen.terminal;
    if (terminal != lastTerminal) {
      terminalController.clearSelection();
      lastTerminal = terminal;
    }
    final canSend =
        session.available &&
        session.inputEnabled &&
        state?.sending != true &&
        !app.terminalInputPending(session.key.id) &&
        state?.uncertain != true &&
        app.connectionState != ConnectionState.stale &&
        app.connectionState != ConnectionState.attention &&
        entry?.state != TerminalState.closed;
    return LayoutBuilder(
      builder: (context, constraints) {
        final short = constraints.maxHeight < 280;
        final compact = widget.compact || short;
        return Column(
          children: [
            if (!widget.embedded && rows.length > 1 && !short)
              Container(
                height: 49,
                color: context.tabs,
                child: ReorderableListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  buildDefaultDragHandles: false,
                  itemCount: rows.length,
                  onReorderItem: app.reorderTabs,
                  itemBuilder: (context, i) {
                    final tab = rows[i], selected = tab.key == session.key;
                    return SessionReorderStart(
                      key: ValueKey('tab-${tab.key.id}'),
                      index: i,
                      enabled: app.layout.filter != 'recent',
                      child: Container(
                        width: 190,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: selected ? context.panel : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: selected ? context.accent : context.border,
                          ),
                        ),
                        child: InkWell(
                          onTap: () => app.select(tab.key.id),
                          onSecondaryTapUp: (details) => showSessionActions(
                            context,
                            app,
                            tab,
                            details.globalPosition,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                Icon(
                                  statusIcon(tab),
                                  size: 13,
                                  color: statusInk(context, tab),
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    tab.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                if (app.isFavourite(tab.key.id))
                                  const Padding(
                                    padding: EdgeInsets.only(left: 5),
                                    child: Icon(
                                      Icons.star_rounded,
                                      color: Color(0xffb88123),
                                      size: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            Container(
              height: session.git.isEmpty ? 48 : 70,
              padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 18),
              color: context.panel,
              child: Row(
                children: [
                  if (!widget.embedded)
                    CompactIcon(
                      Icons.arrow_back,
                      'Session overview',
                      app.overview,
                      key: const ValueKey('show-overview'),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: [
                        'Computer: $computer',
                        'Workspace: $workspace',
                        if (session.terminalTitle.isNotEmpty &&
                            session.terminalTitle != session.title)
                          session.terminalTitle,
                      ].join('\n'),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.mutedInk,
                              fontSize: 10,
                            ),
                          ),
                          if (!session.git.isEmpty)
                            GitMetadataView(metadata: session.git),
                        ],
                      ),
                    ),
                  ),
                  if (!compact) StatusBadge(session),
                  if (!compact) const SizedBox(width: 12),
                  CompactIcon(
                    app.isFavourite(session.key.id)
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    app.isFavourite(session.key.id)
                        ? 'Remove from favourites'
                        : 'Add to favourites',
                    () => app.toggleFavourite(session),
                    color: app.isFavourite(session.key.id)
                        ? const Color(0xffb88123)
                        : context.mutedInk,
                  ),
                  if (!compact) ...[
                    CompactIcon(
                      Icons.text_decrease,
                      'Smaller text',
                      () => app.setZoom(app.layout.zoom / 1.15),
                    ),
                    CompactIcon(
                      Icons.fit_screen,
                      'Reset text size and fit the terminal',
                      () => app.setZoom(1),
                    ),
                    CompactIcon(
                      Icons.text_increase,
                      'Larger text',
                      () => app.setZoom(app.layout.zoom * 1.15),
                    ),
                    CompactIcon(
                      Icons.content_copy,
                      'Copy selection or visible screen',
                      () => unawaited(copyTerminal()),
                    ),
                    CompactIcon(
                      Icons.refresh,
                      'Reconnect terminal and refresh its dimensions',
                      () => unawaited(app.reconnectTerminal(session.key.id)),
                    ),
                  ],
                  if (!widget.mobileControls || composerOpen)
                    CompactIcon(
                      Icons.mic_none,
                      defaultTargetPlatform == TargetPlatform.macOS &&
                              app.snapshot.dictationShortcut.enabled
                          ? 'Dictate message (${app.snapshot.dictationShortcut.label})'
                          : 'Dictate message',
                      () => unawaited(dictate()),
                    ),
                  if (compact)
                    CompactIcon(
                      Icons.chat_bubble_outline,
                      composerOpen ? 'Hide message box' : 'Show message box',
                      toggleComposer,
                      key: const ValueKey('toggle-composer'),
                      color: composerOpen ? context.accent : context.mutedInk,
                    )
                  else
                    Tooltip(
                      message: composerOpen
                          ? 'Hide message box'
                          : 'Show message box',
                      child: TextButton.icon(
                        key: const ValueKey('toggle-composer'),
                        onPressed: toggleComposer,
                        icon: Icon(
                          composerOpen
                              ? Icons.close
                              : Icons.chat_bubble_outline,
                          size: 16,
                        ),
                        label: const Text('Message'),
                      ),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Terminal controls',
                    icon: const Icon(Icons.more_horiz, size: 20),
                    onSelected: (value) {
                      switch (value) {
                        case 'rename':
                          unawaited(showRenameSession(context, app, session));
                        case 'info':
                          unawaited(showSessionInfo());
                        case 'copy':
                          unawaited(copyTerminal());
                        case 'fit':
                          app.setZoom(1);
                        case 'larger':
                          app.setZoom(app.layout.zoom * 1.2);
                        case 'smaller':
                          app.setZoom(app.layout.zoom / 1.2);
                        case 'reconnect':
                          unawaited(app.reconnectTerminal(session.key.id));
                        case 'composer':
                          toggleComposer();
                        case 'window':
                          unawaited(
                            widget.openWindow!('session', session.key.id),
                          );
                        default:
                          if (value.startsWith('group:')) {
                            app.moveToGroup(session.key.id, value.substring(6));
                          }
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rename',
                        enabled: app.canManageSession(session),
                        child: const Text('Rename'),
                      ),
                      const PopupMenuItem(
                        value: 'info',
                        child: Text('Session details'),
                      ),
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy terminal'),
                      ),
                      if (compact) ...[
                        const PopupMenuItem(
                          value: 'fit',
                          child: Text('Fit screen'),
                        ),
                        const PopupMenuItem(
                          value: 'larger',
                          child: Text('Larger text'),
                        ),
                        const PopupMenuItem(
                          value: 'smaller',
                          child: Text('Smaller text'),
                        ),
                        const PopupMenuItem(
                          value: 'reconnect',
                          child: Text('Reconnect terminal'),
                        ),
                      ],
                      PopupMenuItem(
                        value: 'composer',
                        child: Text(
                          composerOpen
                              ? 'Hide message composer'
                              : 'Show message composer',
                        ),
                      ),
                      if (widget.openWindow != null)
                        const PopupMenuItem(
                          value: 'window',
                          child: Text('Open in a window'),
                        ),
                      ...app.layout.groups.map(
                        (g) => PopupMenuItem(
                          value: 'group:${g.id}',
                          child: Text('Add to ${g.name}'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: terminalBackground,
                child: terminal == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                session.available
                                    ? Icons.terminal
                                    : Icons.cloud_off_outlined,
                                color: const Color(0xff7d95aa),
                                size: 32,
                              ),
                              const SizedBox(height: 14),
                              Text(
                                session.available
                                    ? entry?.message ?? 'Connecting terminal…'
                                    : 'This session is unavailable. Your saved view and draft are preserved.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xffaabcca),
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (session.available)
                                TextButton(
                                  onPressed: () => unawaited(
                                    app.reconnectTerminal(session.key.id),
                                  ),
                                  child: const Text('Reconnect'),
                                ),
                            ],
                          ),
                        ),
                      )
                    : TerminalDropTarget(
                        app: app,
                        sessionId: session.key.id,
                        enabled: widget.visible,
                        onActivate: widget.embedded
                            ? () => app.select(session.key.id)
                            : null,
                        child: TerminalSurface(
                          autofocus:
                              widget.active && !composerOpen && !dictationOpen,
                          onDictate: () => unawaited(dictate()),
                          showMobileControls:
                              widget.mobileControls &&
                              widget.active &&
                              !composerOpen,
                          mobileStatus: MobileTerminalStatusMenu(
                            summary: statusSummary,
                            details: [
                              app.connectionMessage,
                              if (app.store.warning != null) app.store.warning!,
                              entry!.message,
                              if (!app.canSendTerminalInput(session.key.id))
                                'Terminal input unavailable',
                              '${entry.screen.columns} × ${entry.screen.rows}',
                              '${app.terminals.values.where((t) => t.subscription != null).length}/16 live',
                            ],
                            warning:
                                state?.message != null ||
                                app.store.warning != null ||
                                entry.state != TerminalState.live ||
                                !connectionReady,
                            onReconnect: () => unawaited(
                              connectionReady
                                  ? app.reconnectTerminal(session.key.id)
                                  : app.reconnect(),
                            ),
                          ),
                          terminal: terminal,
                          controller: terminalController,
                          zoom: app.layout.zoom,
                          copy: copyTerminal,
                          inputId: session.key.id,
                          onViewport:
                              widget.visible &&
                                  app.canResizeViewport(session.key.id)
                              ? (cols, rows) => app.updateViewport(
                                  session.key.id,
                                  cols,
                                  rows,
                                )
                              : null,
                          forwardMouseClicks:
                              app.canScrollTerminal(session.key.id) &&
                              app.canSendTerminalInput(session.key.id),
                          onScroll: app.canScrollTerminal(session.key.id)
                              ? (lines) =>
                                    app.scrollTerminal(session.key.id, lines)
                              : null,
                          sendDraft: () =>
                              unawaited(app.sendDraft(session.key.id)),
                          preserveFocusWhilePaused:
                              (!app.isActive ||
                                  app.connectionState ==
                                      ConnectionState.stale) &&
                              state?.uncertain != true,
                          sendInput:
                              widget.active &&
                                  widget.visible &&
                                  app.canSendTerminalInput(session.key.id)
                              ? (input) =>
                                    app.sendTerminalInput(session.key.id, input)
                              : null,
                        ),
                      ),
              ),
            ),
            if ((!widget.mobileControls || composerOpen) &&
                (!widget.mobileControls || state?.uncertain != true) &&
                entry != null &&
                (!short || state?.uncertain != true))
              Container(
                height: 25,
                color: const Color(0xff17232e),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      entry.state == TerminalState.live
                          ? Icons.circle
                          : Icons.warning_amber_rounded,
                      size: entry.state == TerminalState.live ? 6 : 12,
                      color: entry.state == TerminalState.live
                          ? const Color(0xff7ab894)
                          : const Color(0xffd5ae62),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        (widget.mobileControls ? statusSummary : null) ??
                            (state?.uncertain != true
                                ? state?.message
                                : null) ??
                            (entry.state == TerminalState.live &&
                                    app.canSendTerminalInput(session.key.id)
                                ? 'Click terminal to type · arrows and control keys are supported'
                                : entry.message),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xff92a7b8),
                          fontSize: 10,
                        ),
                      ),
                    ),
                    Text(
                      '${entry.screen.columns} × ${entry.screen.rows}',
                      style: const TextStyle(
                        color: Color(0xff92a7b8),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            if (!composerOpen &&
                state?.message != null &&
                state?.uncertain == true)
              Container(
                color: context.panel,
                padding: const EdgeInsets.all(8),
                child: _InputNotice(
                  app: app,
                  id: session.key.id,
                  state: state!,
                  short: short,
                ),
              ),
            if (composerOpen)
              Container(
                color: context.panel,
                padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 18,
                  short ? 5 : 10,
                  compact ? 10 : 18,
                  short ? 5 : 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (state?.message != null && state?.uncertain == true)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                state!.message!,
                                maxLines: short ? 1 : null,
                                overflow: short ? TextOverflow.ellipsis : null,
                                style: TextStyle(
                                  color: state.uncertain
                                      ? context.attention
                                      : context.mutedInk,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            if (state.uncertain)
                              TextButton(
                                onPressed:
                                    app.terminalInputPending(session.key.id)
                                    ? null
                                    : () => app.acknowledgeDelivery(
                                        session.key.id,
                                      ),
                                child: const Text(
                                  'I’ve checked',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('draft-input'),
                            controller: draft,
                            focusNode: draftFocus,
                            enabled: session.available,
                            minLines: 1,
                            maxLines: short
                                ? 1
                                : compact
                                ? 3
                                : 4,
                            keyboardType: TextInputType.multiline,
                            textCapitalization: TextCapitalization.sentences,
                            onChanged: (text) =>
                                app.updateDraft(session.key.id, text),
                            decoration: InputDecoration(
                              hintText: session.inputEnabled
                                  ? 'Message ${session.agent}…'
                                  : 'Input disabled for this connection',
                              helperText: compact ? null : 'Send submits text + Enter. ⌘ Enter also sends.',
                              helperStyle: const TextStyle(fontSize: 10),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Padding(
                          padding: EdgeInsets.only(bottom: compact ? 0 : 22),
                          child: FilledButton.icon(
                            key: const ValueKey('send-draft'),
                            onPressed: canSend
                                ? () => unawaited(app.sendDraft(session.key.id))
                                : null,
                            icon: state?.sending == true
                                ? const SizedBox(
                                    width: 13,
                                    height: 13,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.arrow_upward, size: 16),
                            label: const Text('Send'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 15,
                                vertical: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InputNotice extends StatelessWidget {
  const _InputNotice({
    required this.app,
    required this.id,
    required this.state,
    required this.short,
  });
  final AppController app;
  final String id;
  final SendState state;
  final bool short;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          state.message!,
          maxLines: short ? 2 : null,
          style: TextStyle(color: context.attention, fontSize: 11),
        ),
      ),
      if (state.uncertain)
        TextButton(
          onPressed: app.terminalInputPending(id)
              ? null
              : () => app.acknowledgeDelivery(id),
          child: const Text('I’ve checked', style: TextStyle(fontSize: 11)),
        ),
    ],
  );
}

class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    super.key,
    required this.terminal,
    required this.controller,
    required this.zoom,
    required this.copy,
    required this.inputId,
    this.onViewport,
    this.onScroll,
    this.forwardMouseClicks = false,
    this.sendInput,
    this.sendDraft,
    this.preserveFocusWhilePaused = false,
    this.autofocus = false,
    this.showMobileControls = false,
    this.mobileStatus,
    this.onDictate,
  });
  final Terminal terminal;
  final TerminalController controller;
  final double zoom;
  final Future<void> Function() copy;
  final String inputId;
  final void Function(int, int)? onViewport;
  final Future<void> Function(int)? onScroll;
  final bool forwardMouseClicks;
  final bool autofocus;
  final bool showMobileControls;
  final Widget? mobileStatus;
  final VoidCallback? onDictate;
  final void Function(TerminalInput)? sendInput;
  final VoidCallback? sendDraft;
  final bool preserveFocusWhilePaused;
  @override
  State<TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<TerminalSurface> {
  (int, int)? reportedViewport;
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  bool _controlPressed = false, _arrowsOpen = false;
  int? _tapPointer;
  Offset? _tapStart;
  Duration? _tapTime;

  Widget _withPointerClicks(Widget child) => Listener(
    onPointerDown: (event) {
      if (!widget.forwardMouseClicks || event.buttons != kPrimaryButton) return;
      _tapPointer = event.pointer;
      _tapStart = event.position;
      _tapTime = event.timeStamp;
    },
    onPointerMove: (event) {
      if (_tapPointer == event.pointer &&
          _tapStart != null &&
          (event.position - _tapStart!).distance > kTouchSlop) {
        _tapPointer = null;
      }
    },
    onPointerCancel: (_) => _tapPointer = null,
    onPointerUp: (event) {
      final pointer = _tapPointer;
      _tapPointer = null;
      if (pointer != event.pointer ||
          !widget.forwardMouseClicks ||
          _tapTime == null ||
          event.timeStamp - _tapTime! >= kLongPressTimeout) {
        return;
      }
      final keys = HardwareKeyboard.instance;
      if (keys.isShiftPressed ||
          keys.isMetaPressed ||
          keys.isControlPressed ||
          keys.isAltPressed) {
        return;
      }
      final render = _terminalViewKey.currentState?.renderTerminal;
      if (render == null) return;
      final local = render.globalToLocal(event.position);
      if (!(Offset.zero & render.size).contains(local)) return;
      final cell = render.getCellOffset(local);
      // Herdr expects a row in the remote screen, not a row relative to the
      // locally visible area (which can be clipped during resize or zoom).
      final row = cell.y - widget.terminal.buffer.scrollBack;
      if (row >= 0 && row < widget.terminal.viewHeight) {
        widget.sendInput?.call(TerminalInput.click(cell.x, row));
      }
    },
    child: child,
  );
  Timer? _scrollTimer;
  double _scrollPixels = 0;
  int _pendingScroll = 0, _scrollEpoch = 0;
  bool _scrollBusy = false;

  void _resetScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    _scrollPixels = 0;
    _pendingScroll = 0;
    _scrollBusy = false;
    _scrollEpoch++;
  }

  void _queueScroll(double pixels, double lineHeight) {
    if (widget.onScroll == null || !pixels.isFinite || lineHeight <= 0) return;
    if ((_pendingScroll < 0 && pixels > 0) ||
        (_pendingScroll > 0 && pixels < 0)) {
      _pendingScroll = 0;
      _scrollPixels = 0;
    }
    _scrollPixels += pixels.clamp(-2400, 2400);
    final lines = (_scrollPixels / lineHeight).truncate();
    _scrollPixels -= lines * lineHeight;
    _pendingScroll = (_pendingScroll + lines).clamp(-4096, 4096);
    _scheduleScroll();
  }

  void _scheduleScroll() {
    if (_scrollBusy || _scrollTimer != null || _pendingScroll == 0) return;
    _scrollTimer = Timer(const Duration(milliseconds: 16), () {
      _scrollTimer = null;
      unawaited(_flushScroll());
    });
  }

  Future<void> _flushScroll() async {
    final send = widget.onScroll,
        lines = _pendingScroll.clamp(-40, 40),
        epoch = _scrollEpoch;
    if (!mounted || send == null || lines == 0) return;
    _pendingScroll -= lines;
    _scrollBusy = true;
    try {
      await send(lines);
    } catch (_) {
      // The controller reports failures in the existing terminal status row.
    } finally {
      if (mounted && epoch == _scrollEpoch) {
        _scrollBusy = false;
        _scheduleScroll();
      }
    }
  }

  Widget _withRemoteScroll(Widget child, double lineHeight) {
    if (widget.onScroll == null) return child;
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()) {
          GestureBinding.instance.pointerSignalResolver.register(event, (
            resolved,
          ) {
            _queueScroll(
              (resolved as PointerScrollEvent).scrollDelta.dy,
              lineHeight,
            );
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.panDelta.dy.abs() > event.panDelta.dx.abs()) {
          _queueScroll(-event.panDelta.dy, lineHeight);
        }
      },
      child: GestureDetector(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
        },
        onVerticalDragUpdate: (event) =>
            _queueScroll(-event.delta.dy, lineHeight),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context)
              .copyWith(physics: const NeverScrollableScrollPhysics()),
          child: child,
        ),
      ),
    );
  }

  final focus = FocusNode(debugLabel: 'Terminal keyboard input');
  late final void Function(String) outputHandler = _onOutput;
  void Function(String)? previousOutput;
  @override
  void initState() {
    super.initState();
    focus.addListener(_focusChanged);
    _attach();
    _focusWhenReady();
  }

  bool _needsInitialFocus = true;

  void _focusWhenReady() {
    if (!widget.autofocus || !_needsInitialFocus || widget.sendInput == null) {
      return;
    }
    final id = widget.inputId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.inputId != id ||
          !widget.autofocus ||
          widget.sendInput == null ||
          !_needsInitialFocus ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      _needsInitialFocus = false;
      focus.requestFocus();
    });
  }

  void _focusChanged() {
    if (mounted) {
      setState(() {
        if (!focus.hasFocus) _controlPressed = false;
      });
    }
  }

  void _attach() {
    previousOutput = widget.terminal.onOutput;
    widget.terminal.onOutput = outputHandler;
  }

  void _detach(Terminal terminal) {
    if (identical(terminal.onOutput, outputHandler)) {
      terminal.onOutput = previousOutput;
    }
  }

  @override
  void didUpdateWidget(covariant TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputId != widget.inputId ||
        widget.sendInput == null ||
        !widget.showMobileControls) {
      _controlPressed = false;
      _arrowsOpen = false;
    }
    if (oldWidget.inputId != widget.inputId || widget.onScroll == null) {
      _tapPointer = null;
      _resetScroll();
    }
    if (oldWidget.inputId != widget.inputId ||
        oldWidget.onViewport == null && widget.onViewport != null) {
      reportedViewport = null;
    }
    if (oldWidget.terminal != widget.terminal) {
      _detach(oldWidget.terminal);
      _attach();
    }
    if (oldWidget.inputId != widget.inputId ||
        !oldWidget.autofocus && widget.autofocus) {
      _needsInitialFocus = true;
    }
    if ((widget.sendInput == null && !widget.preserveFocusWhilePaused ||
            oldWidget.inputId != widget.inputId) &&
        focus.hasFocus) {
      focus.unfocus();
    }
    _focusWhenReady();
  }

  @override
  void dispose() {
    _resetScroll();
    _detach(widget.terminal);
    focus.removeListener(_focusChanged);
    focus.dispose();
    super.dispose();
  }

  void _onOutput(String data) {
    if (!focus.hasFocus ||
        widget.sendInput == null ||
        data.isEmpty ||
        HardwareKeyboard.instance.isMetaPressed) {
      return;
    }
    // Device-query replies are not user input. Only typing and fixed keys pass.
    if (data.startsWith('\x1b[200~') && data.endsWith('\x1b[201~')) {
      data = data.substring(6, data.length - 6);
      _literal(data, paste: true);
      return;
    }
    final key = switch (data) {
      '\r' || '\n' => 'enter',
      '\t' => 'tab',
      '\x08' || '\x7f' => 'backspace',
      _ => null,
    };
    if (key != null) {
      _sendLogicalKey(key);
    } else {
      final text = data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      if (!RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]').hasMatch(text)) {
        _literal(text);
      }
    }
  }

  void _literal(String text, {bool paste = false}) {
    if (text.isEmpty) return;
    if (_controlPressed && !paste && RegExp(r'^[a-zA-Z0-9 ]$').hasMatch(text)) {
      _sendLogicalKey(text == ' ' ? 'space' : text.toLowerCase());
      return;
    }
    if (_controlPressed) setState(() => _controlPressed = false);
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    widget.sendInput?.call(
      paste || normalized.contains('\n') || normalized.contains('\t')
          ? TerminalInput.paste(normalized)
          : TerminalInput.text(normalized),
    );
  }

  void _sendLogicalKey(String key) {
    if (widget.sendInput == null) return;
    final modified = _controlPressed && !key.split('+').contains('ctrl')
        ? 'ctrl+$key'
        : key;
    if (_controlPressed) setState(() => _controlPressed = false);
    widget.sendInput!(TerminalInput.keys([modified]));
  }

  Future<void> _paste({bool requireFocus = true}) async {
    final inputId = widget.inputId;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted ||
        (requireFocus && !focus.hasFocus) ||
        widget.sendInput == null ||
        inputId != widget.inputId) {
      return;
    }
    final text =
        data?.text?.replaceAll('\r\n', '\n').replaceAll('\r', '\n') ?? '';
    _literal(text, paste: true);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance, logical = event.logicalKey;
    final platform = Theme.of(context).platform;
    if (platform != TargetPlatform.macOS &&
        keyboard.isControlPressed &&
        keyboard.isShiftPressed &&
        !keyboard.isAltPressed) {
      if (logical == LogicalKeyboardKey.keyC) {
        unawaited(widget.copy());
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.keyV) {
        unawaited(_paste());
        return KeyEventResult.handled;
      }
    }
    // Terminal emulators translate the Mac line-delete shortcut to Ctrl+U.
    // Herdr's legacy encoder otherwise reduces cmd+backspace to plain DEL.
    if (platform == TargetPlatform.macOS &&
        keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isControlPressed &&
        !keyboard.isShiftPressed &&
        logical == LogicalKeyboardKey.backspace) {
      widget.sendInput?.call(TerminalInput.keys(['ctrl+u']));
      return KeyEventResult.handled;
    }
    if (keyboard.isMetaPressed) {
      if (logical == LogicalKeyboardKey.enter ||
          logical == LogicalKeyboardKey.numpadEnter) {
        widget.sendDraft?.call();
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.keyC) {
        unawaited(widget.copy());
        return KeyEventResult.handled;
      }
      if (logical == LogicalKeyboardKey.keyV) {
        unawaited(_paste());
        return KeyEventResult.handled;
      }
      // Keep app/clipboard shortcuts local; editing chords belong to the pane.
      if (!const [
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.home,
        LogicalKeyboardKey.end,
      ].contains(logical)) {
        return KeyEventResult.ignored;
      }
    }
    if (widget.sendInput == null) return KeyEventResult.ignored;
    final name = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.arrowUp: 'up',
      LogicalKeyboardKey.arrowDown: 'down',
      LogicalKeyboardKey.arrowLeft: 'left',
      LogicalKeyboardKey.arrowRight: 'right',
      LogicalKeyboardKey.enter: 'enter',
      LogicalKeyboardKey.numpadEnter: 'enter',
      LogicalKeyboardKey.escape: 'esc',
      LogicalKeyboardKey.tab: 'tab',
      LogicalKeyboardKey.backspace: 'backspace',
      LogicalKeyboardKey.delete: 'delete',
      LogicalKeyboardKey.insert: 'insert',
      LogicalKeyboardKey.home: 'home',
      LogicalKeyboardKey.end: 'end',
      LogicalKeyboardKey.pageUp: 'pageup',
      LogicalKeyboardKey.pageDown: 'pagedown',
      LogicalKeyboardKey.f1: 'f1',
      LogicalKeyboardKey.f2: 'f2',
      LogicalKeyboardKey.f3: 'f3',
      LogicalKeyboardKey.f4: 'f4',
      LogicalKeyboardKey.f5: 'f5',
      LogicalKeyboardKey.f6: 'f6',
      LogicalKeyboardKey.f7: 'f7',
      LogicalKeyboardKey.f8: 'f8',
      LogicalKeyboardKey.f9: 'f9',
      LogicalKeyboardKey.f10: 'f10',
      LogicalKeyboardKey.f11: 'f11',
      LogicalKeyboardKey.f12: 'f12',
    }[logical];
    var base = name;
    final character = event.character;
    if (keyboard.isAltPressed &&
        (platform == TargetPlatform.macOS
            ? !keyboard.isControlPressed
            : keyboard.isControlPressed) &&
        name == null &&
        logical != LogicalKeyboardKey.space &&
        character != null &&
        character.isNotEmpty &&
        !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(character) &&
        character.toLowerCase() != logical.keyLabel.toLowerCase()) {
      _literal(character);
      return KeyEventResult.handled;
    }
    if (platform == TargetPlatform.macOS &&
        keyboard.isAltPressed &&
        !keyboard.isControlPressed &&
        name == null &&
        character == null) {
      return KeyEventResult.skipRemainingHandlers;
    }
    if (base == null &&
        (_controlPressed ||
            keyboard.isControlPressed ||
            keyboard.isAltPressed)) {
      base = logical == LogicalKeyboardKey.space
          ? 'space'
          : logical.keyLabel.toLowerCase();
    }
    if (base != null) {
      final key = [
        if (keyboard.isControlPressed) 'ctrl',
        if (keyboard.isAltPressed) 'alt',
        if (keyboard.isShiftPressed) 'shift',
        if (keyboard.isMetaPressed) 'cmd',
        base,
      ].join('+');
      // The controller reports unsupported chords instead of silently dropping them.
      _sendLogicalKey(key);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(child: _buildTerminal(context)),
            if (widget.showMobileControls && _arrowsOpen)
              Positioned.fill(
                child: MobileTerminalArrowPad(
                  onClose: () => setState(() => _arrowsOpen = false),
                  enabled: widget.sendInput != null,
                  onKey: _sendLogicalKey,
                ),
              ),
          ],
        ),
      ),
      if (widget.showMobileControls)
        MediaQuery.fromView(
          view: View.of(context),
          child: Builder(
            builder: (keyboardContext) => MobileTerminalKeyBar(
              statusMenu: widget.mobileStatus,
              onDictate: widget.onDictate,
              enabled: widget.sendInput != null,
              control: _controlPressed,
              arrows: _arrowsOpen,
              keyboardVisible:
                  MediaQuery.viewInsetsOf(keyboardContext).bottom > 0,
              onControl: () {
                setState(() => _controlPressed = !_controlPressed);
                if (_controlPressed) {
                  _terminalViewKey.currentState?.requestKeyboard();
                }
              },
              onArrows: () => setState(() => _arrowsOpen = !_arrowsOpen),
              onKeyboard: () {
                if (MediaQuery.viewInsetsOf(keyboardContext).bottom > 0) {
                  _terminalViewKey.currentState?.closeKeyboard();
                  unawaited(
                    SystemChannels.textInput.invokeMethod<void>(
                      'TextInput.hide',
                    ),
                  );
                } else {
                  _terminalViewKey.currentState?.requestKeyboard();
                }
              },
              onPaste: () => unawaited(_paste(requireFocus: false)),
              onKey: _sendLogicalKey,
            ),
          ),
        ),
    ],
  );

  Widget _buildTerminal(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final terminal = widget.terminal,
          controller = widget.controller,
          zoom = widget.zoom;
      const reference = 14.0;
      final painter = TextPainter(
        text: const TextSpan(
          text: 'M',
          style: TextStyle(
            fontFamily: 'Menlo',
            fontFamilyFallback: ['SF Mono', 'monospace'],
            fontSize: reference,
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final glyphWidth = painter.width, glyphHeight = painter.height;
      painter.dispose();
      final fit = math.min(
        (box.maxWidth - 16).clamp(1, double.infinity) /
            math.max(1, terminal.viewWidth * glyphWidth) *
            reference,
        (box.maxHeight - 12).clamp(1, double.infinity) /
            math.max(1, terminal.viewHeight * glyphHeight) *
            reference,
      );
      final size =
          (widget.onViewport != null
              ? reference
              : math.min(18.0, fit).clamp(1.0, 18.0)) *
          zoom;
      if (widget.onViewport != null) {
        final cols = ((box.maxWidth - 16) / (glyphWidth * size / reference))
            .floor()
            .clamp(1, 512);
        final rows = ((box.maxHeight - 12) / (glyphHeight * size / reference))
            .floor()
            .clamp(1, math.min(256, 65536 ~/ cols))
            .toInt();
        if (reportedViewport != (cols, rows)) {
          reportedViewport = (cols, rows);
          final inputId = widget.inputId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                widget.inputId == inputId &&
                reportedViewport == (cols, rows)) {
              widget.onViewport?.call(cols, rows);
            }
          });
        }
      }
      final width = widget.onViewport != null
          ? box.maxWidth
          : math.max(
              box.maxWidth,
              terminal.viewWidth * glyphWidth / reference * size + 16,
            );
      return DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: focus.hasFocus && widget.sendInput != null
                ? context.accent
                : Colors.transparent,
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: box.maxHeight,
            child: Semantics(
              label: widget.sendInput == null
                  ? 'Live terminal screen. Use the message field below to submit text.'
                  : 'Live terminal. Click or tap to type; arrows and control keys go to this session.',
              child: _withPointerClicks(
                _withRemoteScroll(
                  TerminalView(
                    terminal,
                    key: _terminalViewKey,
                    controller: controller,
                    theme: _terminalTheme,
                    textStyle: TerminalStyle(
                      fontFamily: 'Menlo',
                      fontSize: size,
                      height: 1.2,
                      fontFamilyFallback: const ['SF Mono', 'monospace'],
                    ),
                    textScaler: TextScaler.noScaling,
                    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                    autoResize: false,
                    readOnly: widget.sendInput == null,
                    focusNode: focus,
                    onKeyEvent: _key,
                    onPerformSelector: (selector) {
                      if (selector == 'paste:' ||
                          selector == 'pasteAsPlainText:') {
                        unawaited(_paste());
                      } else if (selector == 'copy:') {
                        unawaited(widget.copy());
                      }
                    },
                    hardwareKeyboardOnly: false,
                    deleteDetection: true,
                    keyboardAppearance: Theme.of(context).brightness,
                    simulateScroll: false,
                    onSecondaryTapUp: (_, _) => unawaited(widget.copy()),
                  ),
                  glyphHeight * size / reference,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

const _terminalTheme = TerminalTheme(
  cursor: Color(0xffdce7ef),
  // xterm paints selection over the glyphs, so the highlight must be translucent.
  selection: Color(0x4d8cbdf0),
  foreground: Color(0xffd0dce6),
  background: terminalBackground,
  black: Color(0xff101820),
  red: Color(0xffdd7274),
  green: Color(0xff80bc94),
  yellow: Color(0xffdec47f),
  blue: Color(0xff7da8d3),
  magenta: Color(0xffbd99d2),
  cyan: Color(0xff80c2c4),
  white: Color(0xffd0dce6),
  brightBlack: Color(0xff8496a7),
  brightRed: Color(0xfff58b8d),
  brightGreen: Color(0xffa6d6b3),
  brightYellow: Color(0xfff2dc9f),
  brightBlue: Color(0xffa8c6e9),
  brightMagenta: Color(0xffd5b8e5),
  brightCyan: Color(0xffa4d8da),
  brightWhite: Color(0xfff0f6fa),
  searchHitBackground: Color(0xff554f26),
  searchHitBackgroundCurrent: Color(0xff807342),
  searchHitForeground: Color(0xfff4efd0),
);
