import 'git_metadata_view.dart';
import 'workspace_actions_ui.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';

import 'backend.dart';
import 'controller.dart';
import 'group_actions_ui.dart';
import 'group_split_view.dart';
import 'storage.dart' show TabGroup;
import 'models.dart';
import 'settings_sheet.dart';
import 'terminal_pane.dart';
import 'ui_common.dart';
import 'computers_list.dart';
import 'session_drag.dart';
import 'session_actions_ui.dart';

final _lightTheme = workspaceTheme(Brightness.light);
final _darkTheme = workspaceTheme(Brightness.dark);

class AgentSpaceApp extends StatelessWidget {
  const AgentSpaceApp({
    super.key,
    required this.controller,
    this.desktop = true,
    this.vault,
    this.openWindow,
    this.secondary = false,
  });
  final AppController controller;
  final bool desktop, secondary;
  final CredentialVault? vault;
  final OpenDesktopWindow? openWindow;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'AgentSpace',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: switch (controller.snapshot.appearance) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      home: _WorkspaceShell(
        app: controller,
        desktop: desktop,
        vault: vault ?? SecureCredentialVault(),
        openWindow: openWindow,
        secondary: secondary,
      ),
    ),
  );
}

class _WorkspaceShell extends StatefulWidget {
  const _WorkspaceShell({
    required this.app,
    required this.desktop,
    required this.vault,
    this.openWindow,
    required this.secondary,
  });
  final AppController app;
  final bool desktop, secondary;
  final CredentialVault vault;
  final OpenDesktopWindow? openWindow;
  @override
  State<_WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<_WorkspaceShell>
    with WidgetsBindingObserver {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final searchFocus = FocusNode();
  final searchField = TextEditingController();
  bool searching = false;
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    searchFocus.dispose();
    searchField.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.secondary) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(app.setActive(false));
    }
    if (state == AppLifecycleState.resumed) unawaited(app.setActive(true));
  }

  void settings() => showSettings(context, app, widget.vault, widget.desktop);
  void beginSearch() {
    setState(() => searching = true);
    searchFocus.requestFocus();
  }

  void cancelSearch() {
    searchField.clear();
    app.setSearch('');
    searchFocus.unfocus();
    setState(() => searching = false);
  }

  void openSidebar() {
    FocusManager.instance.primaryFocus?.unfocus();
    scaffoldKey.currentState?.openDrawer();
  }

  void closeSidebar() => scaffoldKey.currentState?.closeDrawer();

  void filter(String value) {
    searchField.clear();
    setState(() => searching = false);
    app.setFilter(value);
  }

  String get filterTitle => app.filterLabel;
  Future<void> newGroup() async {
    var name = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New group'),
        content: TextField(
          onChanged: (value) => name = value,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Group name'),
          onSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name),
            child: const Text('Create group'),
          ),
        ],
      ),
    );
    if (value == null || value.trim().isEmpty) return;
    final group = app.createGroup(value, []);
    filter('group:${group.id}');
  }

  Widget searchInput() => TextField(
    controller: searchField,
    focusNode: searchFocus,
    onChanged: app.setSearch,
    textInputAction: TextInputAction.search,
    onSubmitted: (_) => searchFocus.unfocus(),
    decoration: const InputDecoration(
      hintText: 'Find a session',
      prefixIcon: Icon(Icons.search, size: 18),
      contentPadding: EdgeInsets.symmetric(vertical: 8),
    ),
  );

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: {
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
          const _SearchIntent(),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true):
          const _SearchIntent(),
      const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
          const _FavouritesIntent(),
      const SingleActivator(LogicalKeyboardKey.digit0, meta: true):
          const _AllIntent(),
      const SingleActivator(LogicalKeyboardKey.escape): const _OverviewIntent(),
      const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
          const _ReconnectIntent(),
      const SingleActivator(LogicalKeyboardKey.enter, meta: true):
          const _SendIntent(),
      const SingleActivator(LogicalKeyboardKey.enter, control: true):
          const _SendIntent(),
    },
    child: Actions(
      actions: {
        _SearchIntent: CallbackAction<_SearchIntent>(
          onInvoke: (_) {
            beginSearch();
            return null;
          },
        ),
        _FavouritesIntent: CallbackAction<_FavouritesIntent>(
          onInvoke: (_) {
            filter('favourites');
            return null;
          },
        ),
        _AllIntent: CallbackAction<_AllIntent>(
          onInvoke: (_) {
            filter('all');
            return null;
          },
        ),
        _OverviewIntent: CallbackAction<_OverviewIntent>(
          onInvoke: (_) {
            if (scaffoldKey.currentState?.isDrawerOpen ?? false) {
              closeSidebar();
            } else if (searching) {
              cancelSearch();
            } else if (app.selectedSession != null) {
              app.overview();
            } else {
              cancelSearch();
            }
            return null;
          },
        ),
        _ReconnectIntent: CallbackAction<_ReconnectIntent>(
          onInvoke: (_) {
            unawaited(app.reconnect());
            return null;
          },
        ),
        _SendIntent: CallbackAction<_SendIntent>(
          onInvoke: (_) {
            if (app.layout.selectedId != null) {
              unawaited(app.sendDraft(app.layout.selectedId!));
            }
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: AnimatedBuilder(
          animation: app,
          builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
            value:
                (context.darkAppearance
                        ? SystemUiOverlayStyle.light
                        : SystemUiOverlayStyle.dark)
                    .copyWith(
                      statusBarColor: Colors.transparent,
                      systemNavigationBarColor: context.workspace,
                    ),
            child: Scaffold(
              key: scaffoldKey,
              drawerEnableOpenDragGesture: false,
              drawer:
                  MediaQuery.sizeOf(context).width -
                          MediaQuery.paddingOf(context).horizontal <
                      850
                  ? Drawer(
                      width: math.min(
                        320,
                        MediaQuery.sizeOf(context).width - 48,
                      ),
                      backgroundColor: ink,
                      child: SafeArea(
                        child: _Sidebar(
                          app: app,
                          width: double.infinity,
                          onClose: closeSidebar,
                          selectComputer: filter,
                          filter: (value) {
                            closeSidebar();
                            filter(value);
                          },
                          newGroup: () {
                            closeSidebar();
                            newGroup();
                          },
                          newSession: () => showCreateSession(context, app),
                          newWorkspace: () => showCreateWorkspace(context, app),
                          settings: () {
                            closeSidebar();
                            settings();
                          },
                        ),
                      ),
                    )
                  : null,
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final sidebar = constraints.maxWidth >= 850;
                    final maxSidebarWidth = math.max(
                      208.0,
                      math.min(520.0, constraints.maxWidth - 642),
                    );
                    final sidebarWidth = app.snapshot.sidebarWidth.clamp(
                      208.0,
                      maxSidebarWidth,
                    );
                    void resizeSidebar(double delta) => app.setSidebarWidth(
                      (app.snapshot.sidebarWidth.clamp(208.0, maxSidebarWidth) +
                              delta)
                          .clamp(208.0, maxSidebarWidth),
                    );
                    final narrow =
                        constraints.maxWidth < 620 ||
                        (sidebar &&
                            constraints.maxWidth - sidebarWidth < 700) ||
                        constraints.maxHeight < 420;
                    final sourceLabel = app.source == 'demo'
                        ? 'Demo'
                        : app.snapshot.profiles
                                  .where((p) => p.id == app.source)
                                  .firstOrNull
                                  ?.label ??
                              'Herdr';
                    return Row(
                      children: [
                        if (sidebar)
                          SizedBox(
                            key: const ValueKey('persistent-sidebar'),
                            width: sidebarWidth,
                            child: Stack(
                              children: [
                                _Sidebar(
                                  width: sidebarWidth,
                                  app: app,
                                  selectComputer: filter,
                                  filter: filter,
                                  newGroup: newGroup,
                                  newSession: () =>
                                      showCreateSession(context, app),
                                  newWorkspace: () =>
                                      showCreateWorkspace(context, app),
                                  openWindow: widget.openWindow,
                                  settings: settings,
                                ),
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  right: 0,
                                  width: 8,
                                  child: Semantics(
                                    label: 'Resize sidebar',
                                    value: '${sidebarWidth.round()} pixels',
                                    increasedValue:
                                        '${(sidebarWidth + 32).clamp(208.0, maxSidebarWidth).round()} pixels',
                                    decreasedValue:
                                        '${(sidebarWidth - 32).clamp(208.0, maxSidebarWidth).round()} pixels',
                                    onIncrease: () => resizeSidebar(32),
                                    onDecrease: () => resizeSidebar(-32),
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.resizeColumn,
                                      child: Tooltip(
                                        message: 'Drag to resize sidebar. Double-click to reset.',
                                        child: GestureDetector(
                                          key: const ValueKey('sidebar-resize'),
                                          behavior: HitTestBehavior.opaque,
                                          onHorizontalDragUpdate: (details) =>
                                              resizeSidebar(details.delta.dx),
                                          onDoubleTap: () =>
                                              app.setSidebarWidth(208),
                                          child: Center(
                                            child: Container(
                                              width: 2,
                                              height: 36,
                                              color: context.mutedInk
                                                  .withValues(alpha: .5),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Column(
                            children: [
                              Container(
                                height: narrow ? 54 : 60,
                                padding: EdgeInsets.symmetric(
                                  horizontal: narrow ? 12 : 22,
                                ),
                                decoration: BoxDecoration(
                                  color: context.panel,
                                  border: Border(
                                    bottom: BorderSide(color: context.border),
                                  ),
                                ),
                                child: narrow && searching
                                    ? Row(
                                        children: [
                                          Expanded(child: searchInput()),
                                          const SizedBox(width: 8),
                                          IconButton(
                                            tooltip: 'Cancel search',
                                            onPressed: cancelSearch,
                                            icon: const Icon(
                                              Icons.close,
                                              size: 22,
                                            ),
                                          ),
                                        ],
                                      )
                                    : Row(
                                        children: [
                                          if (!sidebar)
                                            Expanded(
                                              child: TextButton(
                                                key: const ValueKey(
                                                  'workspace-picker',
                                                ),
                                                onPressed: openSidebar,
                                                style: TextButton.styleFrom(
                                                  padding: EdgeInsets.zero,
                                                  foregroundColor: context.ink,
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  minimumSize: const Size(
                                                    48,
                                                    44,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                      Icons.menu,
                                                      size: 22,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Flexible(
                                                      child: Text(
                                                        filterTitle,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontSize: 15,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            )
                                          else
                                            Expanded(
                                              child: Text(
                                                filterTitle,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 19,
                                                  fontWeight: FontWeight.w600,
                                                  letterSpacing: -0.3,
                                                ),
                                              ),
                                            ),
                                          if (!narrow)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                  ),
                                              child: Text(
                                                '${app.visibleSessions.length} ${app.visibleSessions.length == 1 ? 'session' : 'sessions'}',
                                                style: TextStyle(
                                                  color: context.mutedInk,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          if (searching || !narrow)
                                            SizedBox(
                                              width: narrow ? 130 : 210,
                                              child: searchInput(),
                                            )
                                          else
                                            CompactIcon(
                                              Icons.search,
                                              'Find a session',
                                              beginSearch,
                                            ),
                                          if (app.layout.selectedId == null &&
                                              app.layout.filter != 'recent')
                                            PopupMenuButton<SessionSort>(
                                              tooltip: 'Sort sessions',
                                              icon: const Icon(
                                                Icons.sort,
                                                size: 21,
                                              ),
                                              initialValue: app.layout.gridSort,
                                              onSelected: app.setGridSort,
                                              itemBuilder: (_) => [
                                                for (final order
                                                    in SessionSort.values)
                                                  CheckedPopupMenuItem(
                                                    value: order,
                                                    checked:
                                                        app.layout.gridSort ==
                                                        order,
                                                    child: Text(order.label),
                                                  ),
                                              ],
                                            ),
                                          IconButton(
                                            tooltip: 'New session',
                                            onPressed: () =>
                                                showCreateSession(context, app),
                                            icon: const Icon(
                                              Icons.add_box_outlined,
                                              size: 21,
                                            ),
                                          ),
                                          if (app.layout.uncertainActions.keys
                                              .any(
                                                (id) =>
                                                    app
                                                        .sessionActionStates[id]
                                                        ?.pending !=
                                                    true,
                                              ))
                                            IconButton(
                                              tooltip: 'Check unconfirmed session action',
                                              icon: const Icon(
                                                Icons.pending_actions,
                                                size: 21,
                                              ),
                                              onPressed: () =>
                                                  showSessionActionInspection(
                                                    context,
                                                    app,
                                                    app
                                                        .layout
                                                        .uncertainActions
                                                        .keys
                                                        .firstWhere(
                                                          (id) =>
                                                              app
                                                                  .sessionActionStates[id]
                                                                  ?.pending !=
                                                              true,
                                                        ),
                                                  ),
                                            ),
                                          const SizedBox(width: 10),
                                          if (!widget.secondary)
                                            TextButton(
                                              onPressed: settings,
                                              style: TextButton.styleFrom(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                    ),
                                                foregroundColor:
                                                    app.source == 'demo'
                                                    ? context.accent
                                                    : context.ink,
                                                backgroundColor:
                                                    app.source == 'demo'
                                                    ? context.tabs
                                                    : context.workspace,
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    app.source == 'demo'
                                                        ? Icons.science_outlined
                                                        : Icons.computer,
                                                    size: 15,
                                                  ),
                                                  if (!narrow) ...[
                                                    const SizedBox(width: 6),
                                                    Text(sourceLabel),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          if (!widget.secondary)
                                            CompactIcon(
                                              Icons.tune,
                                              'Settings & connections',
                                              settings,
                                            ),
                                        ],
                                      ),
                              ),
                              if (app.selectedGroup != null)
                                GroupLayoutSelector(app: app),
                              Expanded(
                                child: app.hasGroupSplit
                                    ? GroupSplitView(
                                        key: ValueKey(
                                          '${app.source}/${app.selectedGroup!.id}',
                                        ),
                                        app: app,
                                        desktop: widget.desktop,
                                      )
                                    : app.selectedSession == null
                                    ? Column(
                                        children: [
                                          if ((app.layout.filter == 'all' ||
                                                  app.layout.filter.startsWith(
                                                    'computer:',
                                                  )) &&
                                              app.sidebarWorkspaces.isNotEmpty)
                                            _WorkspaceShortcuts(
                                              app: app,
                                              onSelect: filter,
                                            ),
                                          Expanded(
                                            child: _SessionGrid(
                                              app: app,
                                              openWindow: widget.openWindow,
                                              newGroup: newGroup,
                                            ),
                                          ),
                                        ],
                                      )
                                    : TerminalPane(
                                        app: app,
                                        session: app.selectedSession!,
                                        openWindow: widget.openWindow,
                                        compact: narrow,
                                        mobileControls: !widget.desktop,
                                      ),
                              ),
                              if (constraints.maxHeight >= 350 &&
                                  (widget.desktop ||
                                      app.selectedSession == null ||
                                      app.terminals[app
                                              .selectedSession!
                                              .key
                                              .id] ==
                                          null))
                                _ConnectionFooter(app: app),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _FavouritesIntent extends Intent {
  const _FavouritesIntent();
}

class _AllIntent extends Intent {
  const _AllIntent();
}

class _OverviewIntent extends Intent {
  const _OverviewIntent();
}

class _ReconnectIntent extends Intent {
  const _ReconnectIntent();
}

class _SendIntent extends Intent {
  const _SendIntent();
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.app,
    required this.filter,
    required this.selectComputer,
    required this.newGroup,
    required this.newSession,
    required this.newWorkspace,
    required this.settings,
    this.openWindow,
    this.width = 208,
    this.onClose,
  });
  final double width;
  final VoidCallback? onClose;
  final AppController app;
  final void Function(String) filter, selectComputer;
  final VoidCallback newGroup, newSession, newWorkspace, settings;
  final OpenDesktopWindow? openWindow;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    color: ink,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            onClose == null ? 26 : 10,
            12,
            onClose == null ? 26 : 10,
          ),
          child: Row(
            children: [
              const Icon(Icons.apps, color: Color(0xffa1c2e6), size: 23),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'AgentSpace',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              if (onClose != null)
                IconButton(
                  tooltip: 'Close sidebar',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, color: Color(0xffbdcada)),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _row(
                context,
                'all',
                'All sessions',
                Icons.grid_view,
                app.sessions.length,
                key: const ValueKey('nav-all'),
              ),
              _row(
                context,
                'favourites',
                'Favourites',
                Icons.star_outline,
                app.layout.favourites.length,
                key: const ValueKey('nav-favourites'),
              ),
              _row(
                context,
                'recent',
                'Recent',
                Icons.history,
                app.sessionsForFilter('recent').length,
                key: const ValueKey('nav-recent'),
              ),
              if (app.computers.isNotEmpty) ...[
                _row(
                  context,
                  'all',
                  'All',
                  Icons.devices,
                  app.computers.length,
                  key: const ValueKey('nav-all-computers'),
                ),
                ComputersList(
                  app: app,
                  onSelect: selectComputer,
                  workspaceBuilder: (context, id, label) => _row(
                    context,
                    id,
                    label,
                    Icons.folder_outlined,
                    app.sessions.where((s) => s.workspaceFilterId == id).length,
                    key: ValueKey('workspace-$id'),
                  ),
                ),
              ],
              if (app.layout.groups.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 24, 20, 10),
                  child: Text(
                    'Your groups',
                    style: TextStyle(color: Color(0xff98a8b9), fontSize: 12),
                  ),
                ),
              ...app.layout.groups.map(
                (g) => DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      app.sessionById(details.data) != null,
                  onAcceptWithDetails: (details) =>
                      app.moveToGroup(details.data, g.id),
                  builder: (context, candidates, _) => _row(
                    context,
                    'group:${g.id}',
                    candidates.isEmpty ? g.name : 'Drop to add a tab',
                    Icons.tab_outlined,
                    g.sessions.length,
                    dropping: candidates.isNotEmpty,
                    group: g,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              const Divider(color: Color(0xff344251)),
              Row(
                children: [
                  Expanded(
                    child: PopupMenuButton<String>(
                      key: const ValueKey('sidebar-new'),
                      tooltip: 'New',
                      onSelected: (action) {
                        onClose?.call();
                        switch (action) {
                          case 'session':
                            newSession();
                          case 'workspace':
                            newWorkspace();
                          case 'group':
                            newGroup();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'session',
                          child: Text('New session'),
                        ),
                        PopupMenuItem(
                          value: 'workspace',
                          child: Text('New workspace'),
                        ),
                        PopupMenuItem(value: 'group', child: Text('New group')),
                      ],
                      child: const SizedBox(
                        height: 48,
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Icon(
                                Icons.add,
                                size: 19,
                                color: Color(0xffbdcada),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'New',
                                style: TextStyle(color: Color(0xffbdcada)),
                              ),
                              SizedBox(width: 6),
                              Icon(
                                Icons.expand_more,
                                size: 16,
                                color: Color(0xff8296ab),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('sidebar-settings'),
                    tooltip: 'Settings',
                    onPressed: settings,
                    icon: const Icon(Icons.settings_outlined, size: 19),
                    color: const Color(0xffbdcada),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _row(
    BuildContext context,
    String id,
    String title,
    IconData icon,
    int count, {
    Key? key,
    bool dropping = false,
    TabGroup? group,
  }) {
    final selected = app.layout.filter == id;
    final workspaceTarget = app.workspaceTarget(id);
    final row = Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: dropping
            ? selectionBlue
            : selected
            ? const Color(0xff2b3e52)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: key,
              onTap: () => filter(id),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 17,
                      color: selected
                          ? const Color(0xffa1c2e6)
                          : const Color(0xff97a9bc),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : const Color(0xffcad4df),
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (openWindow == null)
                      Text(
                        '$count',
                        style: const TextStyle(
                          color: Color(0xff8296ab),
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (workspaceTarget != null)
            WorkspaceActionsButton(
              app: app,
              origin: workspaceTarget.$1,
              workspace: workspaceTarget.$2,
            ),
          if (group != null) GroupActionsButton(app: app, group: group),
          if (openWindow != null)
            CompactIcon(
              Icons.open_in_new,
              'Open $title in a window',
              () => unawaited(openWindow!('collection', id)),
              color: const Color(0xff8296ab),
              size: 14,
            ),
        ],
      ),
    );
    if (workspaceTarget != null) {
      return GestureDetector(
        key: ValueKey('workspace-row-$id'),
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) => unawaited(
          showWorkspaceContextMenu(
            context,
            app,
            workspaceTarget.$1,
            workspaceTarget.$2,
            details.globalPosition,
          ),
        ),
        child: row,
      );
    }
    if (group == null) return row;
    return GestureDetector(
      key: ValueKey('group-row-${group.id}'),
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) => unawaited(
        showGroupContextMenu(context, app, group, details.globalPosition),
      ),
      child: row,
    );
  }
}

/// All-computer workspace navigation belongs in the overview, keeping the
/// sidebar's computer picker short even with many workspaces.
class _WorkspaceShortcuts extends StatelessWidget {
  const _WorkspaceShortcuts({required this.app, required this.onSelect});
  final AppController app;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 56,
    child: ListView(
      key: const ValueKey('overview-workspaces'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      children: [
        for (final workspace in app.sidebarWorkspaces.entries)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              key: ValueKey('overview-workspace-${workspace.key}'),
              avatar: const Icon(Icons.folder_outlined, size: 16),
              tooltip: workspace.value,
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(workspace.value, overflow: TextOverflow.ellipsis),
              ),
              onPressed: () => onSelect(workspace.key),
            ),
          ),
      ],
    ),
  );
}

class _SessionGrid extends StatefulWidget {
  const _SessionGrid({
    required this.app,
    this.openWindow,
    required this.newGroup,
  });
  final AppController app;
  final OpenDesktopWindow? openWindow;
  final VoidCallback newGroup;
  @override
  State<_SessionGrid> createState() => _SessionGridState();
}

class _SessionGridState extends State<_SessionGrid> {
  final scroll = ScrollController();
  int columns = 1;
  double viewportHeight = 700;
  static const extent = 224.0;
  EdgeDraggingAutoScroller? autoScroller;
  Offset? dragPosition;
  @override
  void initState() {
    super.initState();
    scroll.addListener(updateTargets);
  }

  @override
  void didUpdateWidget(covariant _SessionGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => updateTargets());
  }

  @override
  void dispose() {
    stopDrag();
    scroll.dispose();
    super.dispose();
  }

  void stopDrag() {
    dragPosition = null;
    autoScroller?.stopAutoScroll();
  }

  void dragUpdate(BuildContext itemContext, DragUpdateDetails details) {
    dragPosition = details.globalPosition;
    final scrollable = Scrollable.of(itemContext);
    if (autoScroller?.scrollable != scrollable) {
      autoScroller?.stopAutoScroll();
      autoScroller = EdgeDraggingAutoScroller(
        scrollable,
        velocityScalar: 12,
        onScrollViewScrolled: () {
          updateTargets();
          updateDragScroll(scrollable);
        },
      );
    }
    updateDragScroll(scrollable);
  }

  void updateDragScroll(ScrollableState scrollable) {
    final position = dragPosition;
    if (!mounted || !scrollable.mounted || position == null) return;
    final box = scrollable.context.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(position);
    if (local.dx < 0 || local.dx > box.size.width) {
      autoScroller?.stopAutoScroll();
      return;
    }
    autoScroller!.startAutoScrollIfNecessary(
      Rect.fromCenter(center: position, width: 40, height: 96),
    );
  }

  void updateTargets() {
    if (!mounted || widget.app.selectedSession != null) return;
    final rows = widget.app.visibleSessions;
    final offset = scroll.hasClients ? scroll.offset : 0.0;
    final first = (offset / (extent + 14)).floor() * columns;
    final count = ((viewportHeight / (extent + 14)).ceil() + 1) * columns;
    widget.app.setPreviewTargets(
      rows.skip(first).take(count).map((s) => s.key.id).toList(),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final pad = box.maxWidth < 600 ? 12.0 : 22.0;
      final available = box.maxWidth - pad * 2;
      columns = math.max(
        1,
        ((available + 14) / (widget.app.layout.tileWidth + 14)).floor(),
      );
      viewportHeight = box.maxHeight;
      WidgetsBinding.instance.addPostFrameCallback((_) => updateTargets());
      final rows = widget.app.visibleSessions;
      if (rows.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.app.layout.filter == 'favourites'
                      ? Icons.star_border_rounded
                      : widget.app.layout.filter == 'recent'
                      ? Icons.history
                      : Icons.space_dashboard_outlined,
                  size: 42,
                  color: const Color(0xff8c9eae),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.app.search.isNotEmpty
                      ? 'No matching sessions'
                      : widget.app.layout.filter == 'favourites'
                      ? 'Keep your favourites here'
                      : widget.app.layout.filter == 'recent'
                      ? 'No recent sessions'
                      : widget.app.layout.filter.startsWith('group:')
                      ? 'Make room for your focus'
                      : 'No sessions yet',
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  widget.app.search.isNotEmpty
                      ? 'Try another title, project or agent.'
                      : widget.app.layout.filter == 'favourites'
                      ? 'Star a session to add it to this collection.'
                      : widget.app.layout.filter == 'recent'
                      ? 'Open a session to find it here next time.'
                      : widget.app.layout.filter.startsWith('group:')
                      ? 'Add sessions from their menu, or drag them onto this group.'
                      : 'Start Herdr or try the demo in Settings.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.mutedInk),
                ),
              ],
            ),
          ),
        );
      }
      return GridView.builder(
        controller: scroll,
        padding: EdgeInsets.all(pad),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: extent,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        ),
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final session = rows[i];
          final entry = widget.app.terminals[session.key.id];
          final tile = SessionTile(
            app: widget.app,
            session: session,
            entry: entry,
            openWindow: widget.openWindow,
            newGroup: widget.newGroup,
          );
          final draggable = SessionDraggable(
            key: ValueKey('drag-${session.key.id}'),
            id: session.key.id,
            onDragUpdate: (details) => dragUpdate(context, details),
            onDragEnd: stopDrag,
            feedback: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 240,
                padding: const EdgeInsets.all(14),
                child: Text(
                  session.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            child: tile,
          );
          return DragTarget<String>(
            key: ValueKey('drop-${session.key.id}'),
            onWillAcceptWithDetails: (details) =>
                widget.app.canReorderGrid &&
                details.data != session.key.id &&
                widget.app.visibleSessions.any((s) => s.key.id == details.data),
            onAcceptWithDetails: (details) =>
                widget.app.reorderGridSession(details.data, session.key.id),
            builder: (context, candidates, rejected) => Stack(
              fit: StackFit.passthrough,
              children: [
                draggable,
                if (candidates.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: context.accent, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );
}

class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.app,
    required this.session,
    this.entry,
    this.openWindow,
    required this.newGroup,
  });
  final AppController app;
  final SessionInfo session;
  final TerminalEntry? entry;
  final OpenDesktopWindow? openWindow;
  final VoidCallback newGroup;
  @override
  Widget build(BuildContext context) {
    final favourite = app.isFavourite(session.key.id);
    final lines = entry?.screen.previewLines ?? <String>[];
    final background = session.available && session.status == SessionStatus.done
        ? context.successSurface
        : session.available && session.status == SessionStatus.needsInput
        ? context.attentionSurface
        : context.panel;
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: session.available && session.status == SessionStatus.needsInput
              ? context.attention
              : context.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('tile-${session.key.id}'),
        onTap: () => app.select(session.key.id),
        onSecondaryTapUp: (details) => showSessionActions(
          context,
          app,
          session,
          details.globalPosition,
          newGroup: newGroup,
          openWindow: openWindow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      session.agent,
                      style: TextStyle(color: context.mutedInk, fontSize: 11),
                    ),
                  ),
                  CompactIcon(
                    favourite ? Icons.star_rounded : Icons.star_outline_rounded,
                    favourite ? 'Remove from favourites' : 'Add to favourites',
                    () => app.toggleFavourite(session),
                    key: ValueKey('star-${session.key.id}'),
                    color: favourite
                        ? const Color(0xffb88123)
                        : context.mutedInk,
                    size: 18,
                  ),
                  SessionActionsButton(
                    app: app,
                    session: session,
                    newGroup: newGroup,
                    openWindow: openWindow,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.15,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 9),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: terminalBackground,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: lines.isEmpty
                    ? Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          !session.available
                              ? 'Session unavailable\nYour view is preserved.'
                              : entry?.state == TerminalState.attention
                              ? 'Reconnect to refresh this terminal.'
                              : 'Waiting for a live preview…',
                          style: const TextStyle(
                            color: Color(0xff8a9ba9),
                            fontFamily: 'Menlo',
                            fontSize: 10,
                            height: 1.6,
                          ),
                        ),
                      )
                    : Text(
                        lines.join('\n'),
                        maxLines: 4,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(
                          color: Color(0xffc3d3df),
                          fontFamily: 'Menlo',
                          fontSize: 10,
                          height: 1.6,
                        ),
                      ),
              ),
            ),
            if (!session.git.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: GitMetadataView(metadata: session.git),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
              child: Row(
                children: [
                  Icon(
                    app.computers.length > 1 && session.origin != null
                        ? Icons.computer
                        : Icons.folder_outlined,
                    size: 13,
                    color: context.mutedInk,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      app.layout.filter == 'recent'
                          ? '${app.computerLabel(session.computerId, origin: session.origin)} · ${session.workspaceLabel.isEmpty ? session.project : session.workspaceLabel}'
                          : app.computers.length > 1 && session.origin != null
                          ? '${app.computerLabel(session.computerId, origin: session.origin)} · ${session.project}'
                          : session.project,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.mutedInk, fontSize: 11),
                    ),
                  ),
                  StatusBadge(session),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionFooter extends StatelessWidget {
  const _ConnectionFooter({required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final good =
        app.connectionState == ConnectionState.live ||
        app.connectionState == ConnectionState.demo;
    final message = app.store.warning ?? app.connectionMessage;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: context.panel,
        border: Border(top: BorderSide(color: context.border)),
      ),
      child: Row(
        children: [
          Icon(
            good ? Icons.circle : Icons.warning_amber_rounded,
            size: good ? 7 : 14,
            color: good ? const Color(0xff388962) : const Color(0xffb17a22),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: context.mutedInk),
            ),
          ),
          if (!good)
            TextButton(
              onPressed: () => unawaited(app.reconnect()),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 24),
              ),
              child: const Text('Reconnect', style: TextStyle(fontSize: 10)),
            ),
          Tooltip(
            message: 'Visible terminals are prioritised. Other previews pause.',
            child: Text(
              '${app.terminals.values.where((t) => t.subscription != null).length}/16 live',
              style: TextStyle(fontSize: 10, color: context.mutedInk),
            ),
          ),
        ],
      ),
    );
  }
}
