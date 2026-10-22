import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/models.dart';

String id(int n) => SessionKey('demo', 'test', 'one', 't$n').id;
void main() {
  test(
    'group layout round trips independently with four stable assignments',
    () {
      final group = TabGroup('g1', 'Work', [id(1), id(2), id(3), id(4)]);
      group.view = GroupView.grid;
      group.panels.setAll(0, group.sessions);
      group.activePanel = 2;
      group.columnRatio = .65;
      group.rowRatio = .35;
      final restored = TabGroup.fromJson(group.toJson())!;
      expect(restored.view, GroupView.grid);
      expect(restored.panels, group.sessions);
      expect(restored.activePanel, 2);
      expect(restored.columnRatio, .65);
      expect(restored.rowRatio, .35);
      expect(TabGroup('g2', 'Other', []).view, GroupView.tabs);
    },
  );
  test('legacy groups and malformed layout values remain usable', () {
    final group = TabGroup.fromJson({
      'id': 'g1',
      'name': 'Work',
      'sessions': [id(1), id(2)],
      'view': 'unknown',
      'panels': [id(1), id(1), id(99), 7],
      'activePanel': 99,
      'columnRatio': double.nan,
      'rowRatio': 99,
    })!;
    expect(group.view, GroupView.tabs);
    expect(group.panels, [id(1), null, null, null]);
    expect(group.activePanel, 0);
    expect(group.columnRatio, .5);
    expect(group.rowRatio, .8);
    expect(
      TabGroup.fromJson({'id': 'old', 'sessions': []})!.view,
      GroupView.tabs,
    );
  });
}
