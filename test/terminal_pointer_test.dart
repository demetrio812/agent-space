import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/backend.dart';
import 'package:agentspace/src/bridge_protocol.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/persistent_bridge.dart';
import 'package:agentspace/src/terminal_pane.dart';

import 'fixtures/fake_bridge.dart';

import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';

import 'terminal_input_test.dart' show InputFixture, WidgetStore;

void main() {
  testWidgets(
    'plain terminal tap forwards the visible cell without typing text',
    (tester) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('Jump to bottom (click)');
      final inputs = <TerminalInput>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalSurface(
            terminal: terminal,
            controller: TerminalController(),
            zoom: 1,
            copy: () async {},
            inputId: 'pane',
            onViewport: (_, _) {},
            sendInput: inputs.add,
            forwardMouseClicks: true,
          ),
        ),
      );
      final point =
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(10, 8);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
      expect(inputs.single.clickCell, (column: 0, row: 0));
      expect(inputs.single.textValue, isNull);
      expect(inputs.single.keyNames, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'clicks use the persisted input gate and uncertainty blocks later typing',
    () async {
      final backend = InputFixture()..uncertain = true;
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      addTearDown(app.shutdown);
      await app.start(polling: false);
      final id = backend.session.key.id;
      app.select(id);
      Future<void> until(bool Function() ready) async {
        final end = DateTime.now().add(const Duration(seconds: 2));
        while (!ready() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(ready(), true);
      }

      await until(() => app.canSendTerminalInput(id));
      app.sendTerminalInput(id, const TerminalInput.click(12, 25));
      await until(() => app.sendStates[id]?.uncertain == true);
      expect(backend.input.single.clickCell, (column: 12, row: 25));
      expect(app.layout.uncertainDeliveries, contains(id));
      app.sendTerminalInput(id, const TerminalInput.text('blocked'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(backend.input, hasLength(1));
    },
  );

  test('unconfirmed click is uncertain and never replayed', () async {
    final wire = FakeBridge()..inputFault = 'lost';
    final bridge = PersistentBridge(wire.open);
    addTearDown(bridge.close);
    final sub = bridge
        .observe(fixtureRoute, cols: 90, rows: 30)
        .listen((_) {}, onError: (Object _) {});
    await bridge.request(BridgeLane.streams, 'health', {});
    await expectLater(
      bridge.click(
        fixtureRoute,
        12,
        25,
        timeout: const Duration(milliseconds: 80),
      ),
      throwsA(isA<DeliveryUncertain>()),
    );
    expect(wire.requests.where((r) => r['op'] == 'click'), hasLength(1));
    await sub.cancel();
  });
}
