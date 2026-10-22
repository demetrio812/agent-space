import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/storage.dart';

import 'app_widget_test.dart' show createApp;

void main() {
  test(
    'group slots persist while focus, presets and membership change',
    () async {
      final app = await createApp();
      addTearDown(app.shutdown);
      final ids = app.sessions.take(5).map((s) => s.key.id).toList();
      final group = app.createGroup('Review', ids);
      app.setFilter('group:${group.id}');
      app.setGroupView(GroupView.grid);
      expect(group.panels, ids.take(4));
      app.setGroupPanelTargets(group.id, ids.take(4).toList());
      app.select(ids[1]);
      expect(group.activePanel, 1);
      expect(app.canSendTerminalInput(ids[0]), isFalse);
      expect(app.canSendTerminalInput(ids[1]), isTrue);
      app.assignGroupPanel(1, ids[0]);
      expect(group.panels.take(2), [ids[1], ids[0]]);
      app.select(ids[4]);
      expect(group.panels[1], ids[4]);
      app.setGroupView(GroupView.columns);
      expect(group.panels[2], ids[2]);
      app.setGroupView(GroupView.grid);
      expect(group.panels[2], ids[2]);
      app.setGroupView(GroupView.tabs);
      app.select(ids[3]);
      app.setGroupView(GroupView.grid);
      expect(app.layout.selectedId, ids[3]);
      expect(group.activePanel, 3);
      app.setGroupView(GroupView.rows);
      expect(app.layout.selectedId, ids[3]);
      expect(group.panels.take(2), contains(ids[3]));
      app.setGroupView(GroupView.grid);
      app.select(ids[4]);
      app.removeFromGroup(ids[2], group.id);
      expect(group.panels, isNot(contains(ids[2])));
      app.setGroupRatios(column: .65, row: .3);
      expect(group.columnRatio, .65);
      app.setFilter('all');
      app.setFilter('group:${group.id}');
      expect(app.selectedSession!.key.id, ids[4]);
      expect(group.view, GroupView.grid);
      app.deleteGroup(group.id);
      expect(app.selectedGroup, isNull);
      expect(app.layout.filter, 'all');
    },
  );
}
