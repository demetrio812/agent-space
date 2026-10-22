import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'storage.dart';
import 'terminal_pane.dart';
import 'ui_common.dart';

class GroupLayoutSelector extends StatelessWidget {
  const GroupLayoutSelector({
    super.key,
    required this.app,
    this.compact = false,
  });
  final AppController app;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final group = app.selectedGroup!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          key: const ValueKey('group-layout'),
          tooltip: 'Group layout: ${group.view.label}',
          initialValue: group.view.name,
          onSelected: (value) {
            if (value == 'equal') {
              app.setGroupRatios(column: .5, row: .5);
            } else {
              app.setGroupView(
                GroupView.values.firstWhere((v) => v.name == value),
              );
            }
          },
          itemBuilder: (_) => [
            for (final view in GroupView.values)
              CheckedPopupMenuItem(
                value: view.name,
                checked: view == group.view,
                child: Text(view.label),
              ),
            if (compact && group.view != GroupView.tabs) ...[
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'equal',
                child: Text('Equal panel sizes'),
              ),
            ],
          ],
          icon: compact ? const Icon(Icons.dashboard_outlined, size: 19) : null,
          child: compact
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.dashboard_outlined, size: 17),
                      const SizedBox(width: 8),
                      Text(
                        group.view.label,
                        style: const TextStyle(fontSize: 13),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 18),
                    ],
                  ),
                ),
        ),
        if (!compact && group.view != GroupView.tabs)
          IconButton(
            tooltip: 'Equal panel sizes',
            onPressed: () => app.setGroupRatios(column: .5, row: .5),
            icon: const Icon(Icons.splitscreen_outlined, size: 18),
          ),
      ],
    );
  }
}

class GroupSplitView extends StatefulWidget {
  const GroupSplitView({super.key, required this.app, required this.desktop});
  final AppController app;
  final bool desktop;
  @override
  State<GroupSplitView> createState() => _GroupSplitViewState();
}

class _GroupSplitViewState extends State<GroupSplitView> {
  int? maximized;
  String? registration;
  AppController get app => widget.app;

  void targets(TabGroup group, List<String> ids) {
    final token = '${app.source}/${group.id}';
    registration = token;
    final source = app.source;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && app.source == source && registration == token) {
        app.setGroupPanelTargets(group.id, ids, owner: this);
      }
    });
  }

  @override
  void dispose() {
    final controller = app;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.releaseGroupPanelTargets(this);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final group = app.selectedGroup!;
    final sessions = app.sessionsForFilter(app.layout.filter);
    final count = group.view.count;
    if (maximized != null) maximized = group.activePanel;
    return Column(
      children: [
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final session in sessions)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 4,
                  ),
                  child: ChoiceChip(
                    key: ValueKey('group-session-${session.key.id}'),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 170),
                      child: Text(
                        session.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    selected: app.layout.selectedId == session.key.id,
                    onSelected: (_) => app.select(session.key.id),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final phone =
                  !widget.desktop &&
                  MediaQuery.sizeOf(context).shortestSide < 600;
              final columns =
                  group.view == GroupView.columns ||
                      group.view == GroupView.grid
                  ? 2
                  : 1;
              final rows =
                  group.view == GroupView.rows || group.view == GroupView.grid
                  ? 2
                  : 1;
              final single =
                  phone ||
                  box.maxWidth / columns < 286 ||
                  box.maxHeight / rows < 206;
              final shown = single
                  ? [group.activePanel]
                  : List.generate(count, (i) => i);
              targets(
                group,
                shown.map((i) => group.panels[i]).whereType<String>().toList(),
              );
              final only = single ? group.activePanel : maximized;
              const gap = 10.0;
              final usableWidth = box.maxWidth - (columns > 1 ? gap : 0);
              final usableHeight = box.maxHeight - (rows > 1 ? gap : 0);
              final columnRatio = single
                  ? .5
                  : columns == 1
                  ? 1.0
                  : group.columnRatio.clamp(
                      280 / usableWidth,
                      1 - 280 / usableWidth,
                    );
              final rowRatio = single
                  ? .5
                  : rows == 1
                  ? 1.0
                  : group.rowRatio.clamp(
                      200 / usableHeight,
                      1 - 200 / usableHeight,
                    );
              final left = usableWidth * columnRatio,
                  top = usableHeight * rowRatio;
              Rect rectangle(int slot) {
                if (only == slot || single) return Offset.zero & box.biggest;
                final col = columns == 1 ? 0 : slot % 2;
                final row = columns == 1 ? slot : slot ~/ 2;
                return Rect.fromLTWH(
                  col == 0 ? 0 : left + gap,
                  row == 0 ? 0 : top + gap,
                  columns == 1
                      ? box.maxWidth
                      : col == 0
                      ? left
                      : usableWidth - left,
                  rows == 1
                      ? box.maxHeight
                      : row == 0
                      ? top
                      : usableHeight - top,
                );
              }

              return Stack(
                children: [
                  for (final slot in shown)
                    Positioned.fromRect(
                      key: ValueKey('group-slot-$slot'),
                      rect: rectangle(slot),
                      child: Offstage(
                        offstage: only != null && only != slot,
                        child: ExcludeFocus(
                          excluding: only != null && only != slot,
                          child: panel(
                            context,
                            group,
                            slot,
                            only == null || only == slot,
                          ),
                        ),
                      ),
                    ),
                  if (!single && maximized == null && columns == 2)
                    Positioned(
                      left: left,
                      top: 0,
                      width: gap,
                      height: box.maxHeight,
                      child: _DividerControl(
                        vertical: true,
                        value: group.columnRatio,
                        onChange: (v) => app.setGroupRatios(column: v),
                        onDrag: (d) => app.setGroupRatios(
                          column: group.columnRatio + d / usableWidth,
                        ),
                      ),
                    ),
                  if (!single && maximized == null && rows == 2)
                    Positioned(
                      left: 0,
                      top: top,
                      height: gap,
                      width: box.maxWidth,
                      child: _DividerControl(
                        vertical: false,
                        value: group.rowRatio,
                        onChange: (v) => app.setGroupRatios(row: v),
                        onDrag: (d) => app.setGroupRatios(
                          row: group.rowRatio + d / usableHeight,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget panel(BuildContext context, TabGroup group, int slot, bool visible) {
    final id = group.panels[slot];
    final session = id == null ? null : app.sessionById(id);
    final active = group.activePanel == slot;
    void activate() {
      if (visible && id != null && app.layout.selectedId != id) app.select(id);
    }

    return Listener(
      onPointerDown: (_) => activate(),
      child: Focus(
        onFocusChange: (focused) {
          if (focused) activate();
        },
        child: Container(
          key: ValueKey('split-panel-$slot'),
          decoration: BoxDecoration(
            border: Border.all(
              color: active ? context.accent : context.border,
              width: 2,
            ),
          ),
          child: Column(
            children: [
              Container(
                height: 32,
                color: context.panel,
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Panel ${slot + 1}${active ? ' · Active' : ''}',
                        style: TextStyle(fontSize: 11, color: context.mutedInk),
                      ),
                    ),
                    PopupMenuButton<String>(
                      key: ValueKey('panel-picker-$slot'),
                      tooltip: 'Choose session for panel ${slot + 1}',
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      padding: EdgeInsets.zero,
                      onSelected: (value) => app.assignGroupPanel(
                        slot,
                        value.isEmpty ? null : value,
                      ),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: '',
                          child: Text('Empty panel'),
                        ),
                        for (final s in app.sessionsForFilter(
                          app.layout.filter,
                        ))
                          PopupMenuItem(
                            value: s.key.id,
                            child: Text(
                              '${s.title} · ${app.computerLabel(s.computerId, origin: s.origin)} · ${s.workspaceLabel}',
                            ),
                          ),
                      ],
                    ),
                    IconButton(
                      key: ValueKey('maximize-panel-$slot'),
                      tooltip: maximized == slot
                          ? 'Restore panels'
                          : 'Maximise panel',
                      padding: EdgeInsets.zero,
                      iconSize: 17,
                      onPressed: () {
                        activate();
                        setState(
                          () => maximized = maximized == slot ? null : slot,
                        );
                      },
                      icon: Icon(
                        maximized == slot
                            ? Icons.close_fullscreen
                            : Icons.open_in_full,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: session == null
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Choose a session using the panel menu.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : TerminalPane(
                        key: ValueKey('split-terminal-$id'),
                        app: app,
                        session: session,
                        compact: true,
                        embedded: true,
                        active: active && visible,
                        visible: visible,
                        mobileControls: !widget.desktop,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DividerControl extends StatelessWidget {
  const _DividerControl({
    required this.vertical,
    required this.value,
    required this.onChange,
    required this.onDrag,
  });
  final bool vertical;
  final double value;
  final ValueChanged<double> onChange, onDrag;
  @override
  Widget build(BuildContext context) => Semantics(
    label: vertical ? 'Column divider' : 'Row divider',
    value: '${(value * 100).round()}%',
    increasedValue: '${((value + .05).clamp(.2, .8) * 100).round()}%',
    decreasedValue: '${((value - .05).clamp(.2, .8) * 100).round()}%',
    onIncrease: () => onChange(value + .05),
    onDecrease: () => onChange(value - .05),
    child: Focus(
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        final decrease = vertical
            ? LogicalKeyboardKey.arrowLeft
            : LogicalKeyboardKey.arrowUp;
        final increase = vertical
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowDown;
        if (key != decrease && key != increase) return KeyEventResult.ignored;
        onChange(value + (key == increase ? .05 : -.05));
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: vertical
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: vertical ? (d) => onDrag(d.delta.dx) : null,
          onVerticalDragUpdate: vertical ? null : (d) => onDrag(d.delta.dy),
          child: Center(
            child: Container(
              width: vertical ? 3 : 36,
              height: vertical ? 36 : 3,
              decoration: BoxDecoration(
                color: context.mutedInk,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
