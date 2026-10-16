import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/storage.dart';

void main() {
  test(
    'appearance persists and older layouts follow system appearance',
    () async {
      final dir = await Directory.systemTemp.createTemp('agentspace-theme-');
      addTearDown(() => dir.delete(recursive: true));
      final store = LayoutStore(dir.path);
      final state = AppSnapshot()..appearance = 'dark';
      await store.save(state);
      expect((await store.load()).appearance, 'dark');
      expect(AppSnapshot.fromJson({'version': 1}).appearance, 'system');
      expect(
        AppSnapshot.fromJson({'version': 1, 'appearance': 'invalid'})
            .appearance,
        'system',
      );
    },
  );
  test(
    'favourites and drafts persist per source and retain offline metadata',
    () async {
      final dir = await Directory.systemTemp.createTemp('agentspace-storage-');
      addTearDown(() => dir.delete(recursive: true));
      final store = LayoutStore(dir.path);
      final state = AppSnapshot();
      const session = SessionInfo(
        key: SessionKey('herdr', 'local', 'generation-a', 't1'),
        paneId: 'p1',
        title: 'API review',
        project: 'client',
        agent: 'claude',
        status: SessionStatus.needsInput,
        workspaceId: 'w1',
        workspaceLabel: 'Client',
        terminalTitle: 'Generated',
        inputEnabled: true,
      );
      state.layoutFor('local').favourites[session.key.id] = session;
      state.layoutFor('local').drafts[session.key.id] = 'Keep my draft';
      state.layoutFor('local').selectedId = session.key.id;
      await store.save(state);
      final restored = await store.load();
      expect(
        restored.layoutFor('local').favourites.values.single.title,
        'API review',
      );
      expect(
        restored.layoutFor('local').drafts[session.key.id],
        'Keep my draft',
      );
      expect(restored.layoutFor('demo').favourites, isEmpty);
      expect(restored.layoutFor('demo').drafts, isEmpty);
    },
  );
  test(
    'malformed snapshot recovers without deleting the unreadable evidence',
    () async {
      final dir = await Directory.systemTemp.createTemp('agentspace-corrupt-');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/layout.json').writeAsString('{broken');
      final store = LayoutStore(dir.path);
      final recovered = await store.load();
      expect(recovered.activeSource, 'demo');
      expect(store.warning, isNotNull);
      expect(await File('${dir.path}/layout.json').readAsString(), '{broken');
    },
  );
  test(
    'automatic save after malformed recovery preserves the original bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'agentspace-recovery-save-',
      );
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/layout.json').writeAsString('{broken evidence');
      final store = LayoutStore(dir.path);
      await store.save(await store.load());
      final files = await dir
          .list()
          .where((f) => f is File)
          .cast<File>()
          .toList();
      final contents = await Future.wait(files.map((f) => f.readAsString()));
      expect(contents, contains('{broken evidence'));
      expect((await store.load()).activeSource, 'demo');
    },
  );
  test(
    'saved draft over the send limit survives relaunch for editing',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'agentspace-large-draft-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final store = LayoutStore(dir.path), state = AppSnapshot();
      final id = const SessionKey('herdr', 'demo', 'generation', 't1').id;
      final draft = 'café ' * 4000;
      expect(validateInput(draft), isNotNull);
      state.layoutFor('demo').drafts[id] = draft;
      await store.save(state);
      final restored = (await store.load()).layoutFor('demo').drafts[id];
      expect(restored, isNotNull);
      expect(restored == draft, isTrue);
    },
  );
}
