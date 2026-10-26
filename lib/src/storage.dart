import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'dictation_shortcut.dart';
import 'session_actions.dart';

const maxLayoutBytes = 1024 * 1024;
const maxUncertainDeliveries = 256;

enum GroupView {
  tabs('Tabs', 1),
  columns('Two columns', 2),
  rows('Two rows', 2),
  grid('Four panels', 4);

  const GroupView(this.label, this.count);
  final String label;
  final int count;
}

class TabGroup {
  TabGroup(this.id, this.name, this.sessions);
  final String id;
  String name;
  final List<String> sessions;
  GroupView view = GroupView.tabs;
  final panels = List<String?>.filled(4, null);
  bool panelsInitialized = false;
  int activePanel = 0;
  double columnRatio = .5, rowRatio = .5;

  void sanitizePanels() {
    final seen = <String>{};
    for (var i = 0; i < panels.length; i++) {
      final id = panels[i];
      if (id != null && (!sessions.contains(id) || !seen.add(id))) {
        panels[i] = null;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sessions': sessions.take(256).toList(),
    'view': view.name,
    'panels': panels,
    'panelsInitialized': panelsInitialized,
    'activePanel': activePanel,
    'columnRatio': columnRatio,
    'rowRatio': rowRatio,
  };
  static TabGroup? fromJson(dynamic j) {
    if (j is! Map ||
        j['id'] is! String ||
        !validIdentity(j['id']) ||
        j['sessions'] is! List) {
      return null;
    }
    final group = TabGroup(
      j['id'],
      displayText(j['name']),
      (j['sessions'] as List)
          .whereType<String>()
          .where((s) => SessionKey.decode(s) != null)
          .toSet()
          .take(256)
          .toList(),
    );
    group.view =
        GroupView.values.where((v) => v.name == j['view']).firstOrNull ??
        GroupView.tabs;
    if (j['panels'] is List) {
      final slots = j['panels'] as List;
      for (var i = 0; i < slots.length && i < 4; i++) {
        if (slots[i] is String && SessionKey.decode(slots[i]) != null) {
          group.panels[i] = slots[i];
        }
      }
      group.sanitizePanels();
      group.panelsInitialized = j['panelsInitialized'] != false;
    }
    final active = j['activePanel'];
    if (active is int && active >= 0 && active < 4) group.activePanel = active;
    double ratio(dynamic value) =>
        value is num && value.isFinite ? value.toDouble().clamp(.2, .8) : .5;
    group.columnRatio = ratio(j['columnRatio']);
    group.rowRatio = ratio(j['rowRatio']);
    return group;
  }
}

class WorkspaceLayout {
  final favouriteWorkspaces = <String>{};
  final favourites = <String, SessionInfo>{};
  final retained = <String, SessionInfo>{};
  final drafts = <String, String>{};
  final uncertainDeliveries = <String>{};
  final uncertainActions = <String, SessionActionRecord>{};
  final groups = <TabGroup>[];
  final tabOrder = <String>[];
  final favouriteOrder = <String>[];
  final recentSessions = <String>[];
  SessionSort gridSort = SessionSort.custom;
  String? selectedId;
  String filter = 'all';
  double zoom = 1;
  double tileWidth = 310;
  Map<String, dynamic> toJson() => {
    'favouriteWorkspaces': favouriteWorkspaces.take(256).toList(),
    'favourites': favourites.values.take(256).map((s) => s.toJson()).toList(),
    'retained': retained.values.take(256).map((s) => s.toJson()).toList(),
    'drafts': drafts,
    'uncertainDeliveries': uncertainDeliveries
        .take(maxUncertainDeliveries)
        .toList(),
    'uncertainActions': {
      for (final e in uncertainActions.entries.take(256))
        e.key: e.value.toJson(),
    },
    'groups': groups.take(32).map((g) => g.toJson()).toList(),
    'tabOrder': tabOrder.take(4096).toList(),
    'favouriteOrder': favouriteOrder.take(256).toList(),
    'gridSort': gridSort.name,
    'recentSessions': recentSessions.take(256).toList(),
    'selected': selectedId,
    'filter': filter,
    'zoom': zoom,
    'tileWidth': tileWidth,
  };
  static WorkspaceLayout fromJson(dynamic j) {
    final result = WorkspaceLayout();
    if (j is! Map) return result;
    void entries(String name, Map<String, SessionInfo> target) {
      if (j[name] is List) {
        for (final row in (j[name] as List).take(256)) {
          final session = SessionInfo.fromJson(row);
          if (session != null) target[session.key.id] = session;
        }
      }
    }

    if (j['favouriteWorkspaces'] is List) {
      result.favouriteWorkspaces.addAll(
        (j['favouriteWorkspaces'] as List)
            .whereType<String>()
            .where((id) => RegExp(r'^workspace:[0-9a-f]{64}$').hasMatch(id))
            .toSet()
            .take(256),
      );
    }
    entries('favourites', result.favourites);
    entries('retained', result.retained);
    if (j['uncertainDeliveries'] is List) {
      result.uncertainDeliveries.addAll(
        (j['uncertainDeliveries'] as List)
            .whereType<String>()
            .where((id) => SessionKey.decode(id) != null)
            .take(maxUncertainDeliveries),
      );
    }
    if (j['uncertainActions'] is Map) {
      for (final e in (j['uncertainActions'] as Map).entries.take(256)) {
        final record = SessionActionRecord.fromJson(e.value);
        if (record != null && e.key == record.origin.computerId) {
          result.uncertainActions[e.key as String] = record;
        }
      }
    }
    if (j['drafts'] is Map) {
      for (final row in (j['drafts'] as Map).entries.take(256)) {
        if (row.key is String &&
            SessionKey.decode(row.key) != null &&
            row.value is String &&
            utf8.encode(row.value).length <= maxLayoutBytes) {
          result.drafts[row.key] = row.value;
        }
      }
    }
    if (j['groups'] is List) {
      for (final row in (j['groups'] as List).take(32)) {
        final group = TabGroup.fromJson(row);
        if (group != null && !result.groups.any((g) => g.id == group.id)) {
          result.groups.add(group);
        }
      }
    }
    if (j['tabOrder'] is List) {
      result.tabOrder.addAll(
        (j['tabOrder'] as List)
            .whereType<String>()
            .where((s) => SessionKey.decode(s) != null)
            .toSet()
            .take(4096),
      );
    }
    if (j['favouriteOrder'] is List) {
      result.favouriteOrder.addAll(
        (j['favouriteOrder'] as List)
            .whereType<String>()
            .where(result.favourites.containsKey)
            .toSet()
            .take(256),
      );
    }
    result.gridSort =
        SessionSort.values
            .where((value) => value.name == j['gridSort'])
            .firstOrNull ??
        SessionSort.custom;
    if (j['recentSessions'] is List) {
      result.recentSessions.addAll(
        (j['recentSessions'] as List)
            .whereType<String>()
            .where((id) => SessionKey.decode(id) != null)
            .toSet()
            .take(256),
      );
    }
    result.selectedId =
        j['selected'] is String && SessionKey.decode(j['selected']) != null
        ? j['selected']
        : null;
    result.filter = j['filter'] is String && _validFilter(j['filter'] as String)
        ? j['filter']
        : 'all';
    if (j['zoom'] is num && (j['zoom'] as num).isFinite) {
      result.zoom = (j['zoom'] as num).toDouble().clamp(0.5, 3);
    }
    if (j['tileWidth'] is num && (j['tileWidth'] as num).isFinite) {
      result.tileWidth = (j['tileWidth'] as num).toDouble().clamp(240, 480);
    }
    return result;
  }
}

bool _validFilter(String value) {
  if (!validIdentity(value)) return false;
  if (value.startsWith('computer:') || value.startsWith('workspace:')) {
    return RegExp(r'^(?:computer|workspace):[0-9a-f]{64}$').hasMatch(value);
  }
  if (value.startsWith('group:')) return validIdentity(value.substring(6));
  return true;
}

class AppSnapshot {
  String activeSource = 'demo';
  String appearance = 'system';
  double sidebarWidth = 208;
  String dictationProvider = 'openai';
  DictationShortcut dictationShortcut = const DictationShortcut();
  final layouts = <String, WorkspaceLayout>{};
  final profiles = <ConnectionProfile>[];
  final window = <String, double>{};
  final detached = <Map<String, dynamic>>[];
  WorkspaceLayout layoutFor(String source) =>
      layouts.putIfAbsent(source, WorkspaceLayout.new);
  Map<String, dynamic> toJson() => {
    'version': 1,
    'activeSource': activeSource,
    'appearance': appearance,
    'sidebarWidth': sidebarWidth,
    'dictationProvider': dictationProvider,
    'dictationShortcut': dictationShortcut.toJson(),
    'layouts': layouts.map((key, value) => MapEntry(key, value.toJson())),
    'profiles': profiles.take(16).map((p) => p.toJson()).toList(),
    'window': window,
    'detached': detached.take(16).toList(),
  };
  static AppSnapshot fromJson(dynamic j) {
    if (j is! Map || j['version'] != 1) {
      throw const FormatException('Unsupported saved layout version.');
    }
    final result = AppSnapshot();
    final sidebarWidth = j['sidebarWidth'];
    if (sidebarWidth is num && sidebarWidth.isFinite) {
      result.sidebarWidth = sidebarWidth.toDouble().clamp(208, 520);
    }
    result.dictationShortcut = DictationShortcut.fromJson(
      j['dictationShortcut'],
    );
    if (['openai', 'elevenlabs'].contains(j['dictationProvider'])) {
      result.dictationProvider = j['dictationProvider'];
    }
    if (['system', 'light', 'dark'].contains(j['appearance'])) {
      result.appearance = j['appearance'];
    }
    if (j['activeSource'] is String && validIdentity(j['activeSource'])) {
      result.activeSource = j['activeSource'];
    }
    if (j['layouts'] is Map) {
      for (final row in (j['layouts'] as Map).entries.take(17)) {
        if (row.key is String && validIdentity(row.key)) {
          result.layouts[row.key] = WorkspaceLayout.fromJson(row.value);
        }
      }
    }
    if (j['profiles'] is List) {
      for (final row in (j['profiles'] as List).take(16)) {
        final p = ConnectionProfile.fromJson(row);
        if (p != null && !result.profiles.any((e) => e.id == p.id)) {
          result.profiles.add(p);
        }
      }
    }
    if (j['window'] is Map) {
      for (final key in ['x', 'y', 'width', 'height']) {
        final value = j['window'][key];
        if (value is num && value.isFinite) {
          result.window[key] = value.toDouble();
        }
      }
    }
    if (j['detached'] is List) {
      result.detached.addAll(
        (j['detached'] as List)
            .whereType<Map>()
            .take(16)
            .map((e) => Map<String, dynamic>.from(e)),
      );
    }
    return result;
  }
}

class LayoutStore {
  LayoutStore(this.directory);
  final String directory;
  String? warning;
  Future<void> _pendingSave = Future.value();
  bool _preserveUnreadable = false;
  Future<void> save(AppSnapshot value) {
    final bytes = utf8.encode(jsonEncode(value.toJson()));
    if (bytes.length > maxLayoutBytes) {
      warning = 'Layout is too large to save. The previous saved layout is preserved.';
      return Future.error(const FileSystemException('Layout exceeds 1 MiB.'));
    }
    final job = _pendingSave.catchError((_) {}).then((_) async {
      await Directory(directory).create(recursive: true);
      if (_preserveUnreadable) {
        final original = File('$directory/layout.json');
        if (await original.exists()) {
          final name =
              'layout.recovery-${DateTime.now().microsecondsSinceEpoch}.json';
          await original.copy('$directory/$name');
          warning = 'The previous saved layout was preserved as $name.';
        }
        _preserveUnreadable = false;
      }
      final temporary = File('$directory/layout.json.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename('$directory/layout.json');
    });
    _pendingSave = job;
    return job;
  }

  Future<AppSnapshot> load() async {
    final file = File('$directory/layout.json');
    try {
      if (!await file.exists()) return AppSnapshot();
      if (await file.length() > maxLayoutBytes) {
        throw const FormatException('Saved layout is too large.');
      }
      return AppSnapshot.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      _preserveUnreadable = true;
      warning = 'The saved layout could not be read. Its original bytes will be preserved in a recovery file before saving changes.';
      return AppSnapshot();
    }
  }
}
