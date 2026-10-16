import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/protocol.dart';

Map<String, dynamic> catalog({String server = 'generation-a'}) => {
  'serverIdentity': server,
  'inputEnabled': true,
  'catalog': {
    'result': {
      'agents': [
        {
          'terminal_id': 't1',
          'pane_id': 'p1',
          'workspace_id': 'w1',
          'tab_id': 'tab1',
          'terminal_title': '\u001b[32mGenerated title\u001b[0m',
          'cwd': '/work/same-name',
          'agent': 'claude',
          'agent_status': 'question',
        },
        {
          'terminal_id': 't2',
          'pane_id': 'p2',
          'workspace_id': 'w2',
          'tab_id': 'tab2',
          'terminal_title': 'Other',
          'cwd': '/other/same-name',
          'agent_status': 'idle',
        },
        {'terminal_id': 't1', 'pane_id': 'duplicate'},
        {'terminal_id': 'bad\nidentity'},
      ],
    },
  },
  'workspaces': [
    {'workspace_id': 'w1', 'label': 'Client work'},
    {'workspace_id': 'w2', 'label': 'Personal'},
  ],
  'tabs': [
    {
      'workspace_id': 'w1',
      'tab_id': 'tab1',
      'label': 'Review API',
      'number': 1,
    },
  ],
};
String frame({
  int width = 175,
  int height = 55,
  int seq = 0,
  bool full = true,
  String text = 'screen',
}) => jsonEncode({
  'type': 'terminal.frame',
  'width': width,
  'height': height,
  'seq': seq,
  'full': full,
  'encoding': 'ansi',
  'bytes': base64Encode(utf8.encode(text)),
});

void main() {
  test('stable identity survives title/order changes but separates replacement servers', () {
    const a = SessionKey('herdr', 'mac', 'generation-a', 't1');
    expect(SessionKey.decode(a.id), a);
    expect(
      a.id,
      isNot(const SessionKey('herdr', 'mac', 'generation-b', 't1').id),
    );
    expect(SessionKey.decode('invalid'), isNull);
    expect(
      SessionKey.decode(
        base64UrlEncode(utf8.encode('["herdr","mac","bad\\nserver","t1"]')),
      ),
      isNull,
    );
  });
  test(
    'catalog prefers custom label, strips ANSI and groups by workspace ID',
    () {
      final sessions = parseCatalog(jsonEncode(catalog()), 'mac');
      expect(sessions, hasLength(2));
      expect(sessions.first.title, 'Review API');
      expect(sessions.first.terminalTitle, 'Generated title');
      expect(sessions.first.workspaceLabel, 'Client work');
      expect(sessions.first.status, SessionStatus.needsInput);
      expect(sessions.first.inputEnabled, isTrue);
      expect(sessions[1].workspaceId, 'w2');
    },
  );
  test(
    'failed and oversized catalogs are rejected instead of hiding sessions',
    () {
      expect(
        () => parseCatalog('{"error":"no access"}', 'mac'),
        throwsFormatException,
      );
      expect(
        () => parseCatalog(' ' * (2 * 1024 * 1024 + 1), 'mac'),
        throwsFormatException,
      );
    },
  );
  test(
    'native tall frame preserves bottom menu and full redraw clears old screen',
    () {
      final screen = TerminalScreen();
      screen.accept(
        parseObserveLine(frame(text: '\u001b[55;1HModel menu at the bottom'))
            as TerminalFrame,
      );
      expect(screen.rows, 55);
      expect(screen.columns, 175);
      expect(screen.text, contains('Model menu at the bottom'));
      screen.accept(
        parseObserveLine(frame(seq: 1, text: 'replacement')) as TerminalFrame,
      );
      expect(screen.text, contains('replacement'));
      expect(screen.text, isNot(contains('Model menu')));
    },
  );
  test('deltas require an initial snapshot, consecutive sequence and matching dimensions', () {
    final screen = TerminalScreen();
    expect(
      () =>
          screen.accept(parseObserveLine(frame(full: false)) as TerminalFrame),
      throwsFormatException,
    );
    screen.accept(parseObserveLine(frame()) as TerminalFrame);
    expect(
      () => screen.accept(
        parseObserveLine(frame(seq: 2, full: false)) as TerminalFrame,
      ),
      throwsFormatException,
    );
    expect(
      () => screen.accept(
        parseObserveLine(frame(seq: 1, full: false, width: 80))
            as TerminalFrame,
      ),
      throwsFormatException,
    );
    screen.accept(
      parseObserveLine(frame(seq: 1, full: false, text: '\u001b[2;1Hdelta'))
          as TerminalFrame,
    );
    expect(screen.text, contains('delta'));
  });
  test(
    'frame decoder rejects cell explosion, wrong encoding and malformed base64',
    () {
      expect(
        () => parseObserveLine(frame(width: 512, height: 256)),
        throwsFormatException,
      );
      expect(() => parseObserveLine(frame(width: 0)), throwsFormatException);
      expect(
        () => parseObserveLine(frame().replaceFirst('ansi', 'html')),
        throwsFormatException,
      );
      expect(
        () => parseObserveLine(frame().replaceFirst('c2NyZWVu', '%%%')),
        throwsFormatException,
      );
      expect(
        parseObserveLine('{"type":"terminal.closed","reason":"Finished"}'),
        isA<TerminalClosed>(),
      );
    },
  );
  test('input is literal UTF-8, bounded, with no control sequences', () {
    expect(
      validateInput('--literal café; \$(echo harmless)\nsecond line'),
      isNull,
    );
    expect(validateInput('\u001b[2J'), isNotNull);
    expect(validateInput('   '), isNotNull);
    expect(validateInput('é' * 8192), isNull);
    expect(validateInput('é' * 8193), isNotNull);
  });
  test(
    'status mapping keeps idle neutral and attention separate from transport',
    () {
      expect(SessionStatus.parse('done'), SessionStatus.done);
      expect(SessionStatus.parse('needs_input'), SessionStatus.needsInput);
      expect(SessionStatus.parse('idle'), SessionStatus.idle);
      expect(SessionStatus.parse('working'), SessionStatus.working);
      expect(SessionStatus.parse('unexpected'), SessionStatus.unknown);
    },
  );
}
