import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';

void main() {
  test(
    'installed Herdr preserves literal text and sends Enter exactly once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'agentspace-real-cli-',
      );
      final path = '${directory.path}/fixture.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final requests = <Map<String, dynamic>>[];
      final clients = <Socket>[];
      final subscription = listener.listen((client) {
        clients.add(client);
        client
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final request = jsonDecode(line) as Map<String, dynamic>;
              requests.add(request);
              final result = switch (request['method']) {
                'ping' => {'type': 'pong', 'version': '0.0.0', 'protocol': 22},
                'agent.list' => {
                  'type': 'agent_list',
                  'agents': [
                    {
                      'terminal_id': 't1',
                      'pane_id': 'p1',
                      'workspace_id': 'w1',
                      'tab_id': 'tab1',
                      'agent_status': 'idle',
                      'focused': false,
                      'revision': 0,
                    },
                  ],
                },
                'workspace.list' => {
                  'type': 'workspace_list',
                  'workspaces': [],
                },
                'tab.list' => {'type': 'tab_list', 'tabs': []},
                'pane.send_input' ||
                'pane.send_text' ||
                'pane.send_keys' => {'type': 'ok'},
                _ => {'type': 'error', 'message': 'Unexpected fixture method'},
              };
              client.writeln(
                jsonEncode({'id': request['id'], 'result': result}),
              );
            });
      });
      final backend = LocalHerdrBackend(
        ConnectionProfile(
          id: 'fixture',
          label: 'Disposable',
          executable: Platform.environment['HERDR_TEST_BINARY']!,
          socketPath: path,
        ),
      );
      try {
        final session = (await backend.listSessions()).single;
        const text = '--literal café; \$(echo harmless)\nsecond line';
        await backend.sendText(session, text);
        final writes = requests
            .where((r) => r['method'] == 'pane.send_input')
            .toList();
        expect(writes, hasLength(1));
        expect(writes.single['params'], {
          'pane_id': 'p1',
          'text': text,
          'keys': ['Enter'],
        });
        await backend.sendTerminalInput(
          session,
          const TerminalInput.text(' café '),
        );
        await backend.sendTerminalInput(
          session,
          TerminalInput.keys([
            'up',
            'ctrl+enter',
            'shift+tab',
            'cmd+backspace',
          ]),
        );
        expect(
          requests
              .where((r) => r['method'] == 'pane.send_text')
              .single['params'],
          {'pane_id': 'p1', 'text': ' café '},
        );
        expect(
          requests
              .where((r) => r['method'] == 'pane.send_keys')
              .single['params'],
          {
            'pane_id': 'p1',
            'keys': ['up', 'ctrl+enter', 'shift+tab', 'cmd+backspace'],
          },
        );
        expect(
          requests.where((r) => r['method'] == 'pane.send_input'),
          hasLength(1),
        );
      } finally {
        await backend.close();
        for (final client in clients) {
          client.destroy();
        }
        await subscription.cancel();
        await listener.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS || Platform.environment['HERDR_TEST_BINARY'] == null
        ? 'Set HERDR_TEST_BINARY to the installed CLI; only a disposable socket is used.'
        : false,
  );
}
