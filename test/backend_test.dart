import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';

void main() {
  late Directory dir;
  late ConnectionProfile profile;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agentspace-cli-');
    await File('${dir.path}/server.sock')
        .writeAsString('socket generation fixture');
    final script = File('${dir.path}/fake-herdr');
    await script.writeAsString(r'''#!/usr/bin/env python3
import sys,os,json,base64
from pathlib import Path
root=Path(os.environ['HERDR_SOCKET_PATH']).parent
args=sys.argv[1:]
with (root/'requests.jsonl').open('a') as f: f.write(json.dumps(args)+'\n')
if args[:2]==['agent','list']:
 print(json.dumps({'result':{'agents':[{'terminal_id':'t1','pane_id':'p1','workspace_id':'w1','tab_id':'tab1','terminal_title':'Generated','agent_status':'idle','cwd':'/work/demo'}]}}))
elif args[:2]==['workspace','list']: print(json.dumps({'result':{'workspaces':[{'workspace_id':'w1','label':'Work'}]}}))
elif args[:2]==['tab','list']: print(json.dumps({'result':{'tabs':[{'workspace_id':'w1','tab_id':'tab1','label':'My label','number':1}]}}))
elif args[:2]==['pane','layout']: print(json.dumps({'result':{'layout':{'panes':[{'pane_id':'p1','rect':{'width':175,'height':55}}]}}}))
elif args[:3]==['terminal','session','observe']:
 print(json.dumps({'type':'terminal.frame','encoding':'ansi','width':175,'height':55,'seq':0,'full':True,'bytes':base64.b64encode(b'\x1b[55;1Hbottom menu').decode()}))
 print(json.dumps({'type':'terminal.closed','reason':'Fixture complete'}))
elif args[:2]==['pane','run']:
 if (root/'fail-send').exists(): sys.exit(1)
else: sys.exit(2)
''');
    await Process.run('/bin/chmod', ['+x', script.path]);
    profile = ConnectionProfile(
      id: 'test',
      label: 'Test Mac',
      executable: script.path,
      socketPath: '${dir.path}/server.sock',
    );
  });
  tearDown(() async => dir.delete(recursive: true));
  test(
    'local catalog uses existing socket and preserves custom tab label',
    () async {
      final backend = LocalHerdrBackend(profile);
      addTearDown(backend.close);
      final catalog = await backend.listSessions();
      expect(catalog.single.title, 'My label');
      expect(catalog.single.inputEnabled, isTrue);
      expect(catalog.single.key.server, hasLength(64));
    },
  );
  test(
    'observer requests native pane geometry without a terminal resize',
    () async {
      final backend = LocalHerdrBackend(profile);
      addTearDown(backend.close);
      final session = (await backend.listSessions()).single;
      final events = await backend.observe(session).toList();
      expect((events.first as TerminalFrame).height, 55);
      final calls = (await File(
        '${dir.path}/requests.jsonl',
      ).readAsLines()).map(jsonDecode).toList();
      expect(
        calls,
        contains(
          equals([
            'terminal',
            'session',
            'observe',
            't1',
            '--cols',
            '175',
            '--rows',
            '55',
          ]),
        ),
      );
      expect(calls.where((c) => c.contains('resize')), isEmpty);
    },
  );
  test(
    'literal input reaches CLI once and uncertain failure never retries',
    () async {
      final backend = LocalHerdrBackend(profile);
      addTearDown(backend.close);
      final session = (await backend.listSessions()).single;
      const draft = '--literal café; \$(echo harmless)\nsecond line';
      await backend.sendText(session, draft);
      await File('${dir.path}/fail-send').writeAsString('fail');
      await expectLater(
        backend.sendText(session, 'second submission'),
        throwsA(isA<DeliveryUncertain>()),
      );
      final calls = (await File('${dir.path}/requests.jsonl').readAsLines())
          .map(jsonDecode)
          .where((c) => c[0] == 'pane' && c[1] == 'run')
          .toList();
      expect(calls, [
        ['pane', 'run', 'p1', draft],
        ['pane', 'run', 'p1', 'second submission'],
      ]);
    },
  );
  test(
    'server socket replacement rejects a retained session before input',
    () async {
      final backend = LocalHerdrBackend(profile);
      addTearDown(backend.close);
      final session = (await backend.listSessions()).single;
      await File(profile.socketPath).rename('${dir.path}/old.sock');
      await File(profile.socketPath).writeAsString('replacement');
      await expectLater(
        backend.sendText(session, 'should never send'),
        throwsA(isA<SessionUnavailable>()),
      );
      final calls = (await File(
        '${dir.path}/requests.jsonl',
      ).readAsLines()).map(jsonDecode);
      expect(calls.where((c) => c[0] == 'pane' && c[1] == 'run'), isEmpty);
    },
  );
  test('missing socket does not implicitly start Herdr', () async {
    final backend = LocalHerdrBackend(profile);
    addTearDown(backend.close);
    await File(profile.socketPath).delete();
    await expectLater(
      backend.listSessions(),
      throwsA(isA<ConnectionFailure>()),
    );
    expect(await File('${dir.path}/requests.jsonl').exists(), isFalse);
  });
}
