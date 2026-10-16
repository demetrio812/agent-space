import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';

void main() {
  test(
    'live saved-computer discovery and preview through existing OpenSSH',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'agentspace-live-',
      );
      try {
        final output = File('${directory.path}/network.json');
        final result = await Process.run('scripts/read-only-network', [
          '--gateway',
          Platform.environment['HERDR_NETWORK_GATEWAY']!,
          '--seconds',
          '5',
          '--output',
          output.path,
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        final report = jsonDecode(await output.readAsString()) as Map;
        final computers = report['computers'] as List;
        expect(
          computers.any(
            (c) => c['machine'] == 'gateway' && c['state'] == 'live',
          ),
          true,
        );
        expect(
          computers.any(
            (c) => c['machine'] != 'gateway' && c['state'] == 'live',
          ),
          true,
        );
        expect(report['preview']['frames'], greaterThan(0));
        expect(report['preview']['remained_open'], true);
        stderr.writeln(
          'Read-only network: ${computers.length} computers, preview remained live.',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['HERDR_NETWORK_GATEWAY'] == null
        ? 'Opt-in existing SSH account and approved versioned cache; never submits input.'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'live Herdr read-only catalog and native terminal frame',
    () async {
      final backend = SocketHerdrBackend(
        ConnectionProfile(
          id: 'live-validation',
          label: 'Read-only validation',
          executable: Platform.environment['HERDR_TEST_BINARY']!,
          socketPath: Platform.environment['HERDR_LIVE_SOCKET']!,
        ),
      );
      try {
        final sessions = await backend.listSessions();
        expect(sessions, isNotEmpty);
        // Report geometry only. No titles, drafts or terminal contents are logged.
        final frame = await backend
            .observe(sessions.first)
            .where((event) => event is TerminalFrame)
            .cast<TerminalFrame>()
            .first
            .timeout(const Duration(seconds: 15));
        expect(frame.full, isTrue);
        expect(frame.bytes, isNotEmpty);
        stderr.writeln(
          'Read-only validation: ${sessions.length} sessions; ${frame.width} × ${frame.height} full frame.',
        );
      } finally {
        await backend.close();
      }
    },
    skip:
        Platform.environment['HERDR_LIVE_SOCKET'] == null ||
            Platform.environment['HERDR_TEST_BINARY'] == null
        ? 'Optional live observation; never sends input.'
        : false,
  );
}
