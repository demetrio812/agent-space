import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:agentspace/src/persistent_bridge.dart';
import 'package:agentspace/src/bridge_protocol.dart';

import 'fixtures/fake_bridge.dart';

void main() {
  testWidgets(
    'iPad touch, wheel and trackpad gestures scroll the remote terminal',
    (tester) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('\x1b[?1049hFixture');
      final scrolled = <int>[];
      final typed = <Object>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: TerminalSurface(
            terminal: terminal,
            controller: TerminalController(),
            zoom: 1,
            inputId: 'ipad',
            copy: () async {},
            sendInput: typed.add,
            onScroll: (lines) async => scrolled.add(lines),
          ),
        ),
      );
      final target = tester.getCenter(find.byType(TerminalSurface));
      await tester.drag(find.byType(TerminalSurface), const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 40));
      expect(scrolled, isNotEmpty);
      expect(scrolled.reduce((a, b) => a + b), lessThan(0));
      scrolled.clear();
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: target, scrollDelta: const Offset(0, 120)),
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(scrolled.single, greaterThan(0));
      scrolled.clear();
      final trackpad = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await trackpad.panZoomStart(target);
      await trackpad.panZoomUpdate(target, pan: const Offset(0, 120));
      await trackpad.panZoomEnd();
      await tester.pump(const Duration(milliseconds: 40));
      expect(scrolled.single, lessThan(0));
      expect(typed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'wheel and trackpad scroll the attached pane without typing or stealing focus',
    (tester) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('Current screen');
      final sent = <Object>[], scrolled = <int>[];
      final hold = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 600,
            child: TerminalSurface(
              terminal: terminal,
              controller: TerminalController(),
              zoom: 1,
              copy: () async {},
              inputId: 'pane-a',
              sendInput: sent.add,
              onScroll: (lines) async {
                scrolled.add(lines);
                if (scrolled.length == 1) await hold.future;
              },
            ),
          ),
        ),
      );
      final target = tester.getCenter(find.byType(TerminalSurface));
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: target, scrollDelta: const Offset(0, -60)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(scrolled.single, lessThan(0));
      for (var i = 0; i < 40; i++) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: target,
            scrollDelta: const Offset(0, -60),
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        scrolled,
        hasLength(1),
        reason: 'Only one request may be pending; gestures coalesce.',
      );
      hold.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(scrolled, hasLength(2));
      expect(scrolled.last.abs(), lessThanOrEqualTo(120));
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(target);
      await gesture.panZoomUpdate(target, pan: const Offset(0, -60));
      await gesture.panZoomEnd();
      await tester.pump(const Duration(milliseconds: 20));
      expect(scrolled.last, greaterThan(0));
      expect(sent, isEmpty);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('Terminal keyboard input'),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'queued gestures are discarded when the selected terminal changes',
    (tester) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('Fixture');
      final controller = TerminalController(), hold = Completer<void>();
      final sent = <String>[];
      Future<void> mount(String id) => tester.pumpWidget(
        MaterialApp(
          home: TerminalSurface(
            key: const ValueKey('same-surface'),
            terminal: terminal,
            controller: controller,
            zoom: 1,
            copy: () async {},
            inputId: id,
            onScroll: (lines) async {
              sent.add(id);
              if (id == 'old') await hold.future;
            },
          ),
        ),
      );
      await mount('old');
      final target = tester.getCenter(find.byType(TerminalSurface));
      void wheel() => tester.binding.handlePointerEvent(
        PointerScrollEvent(position: target, scrollDelta: const Offset(0, -60)),
      );
      wheel();
      await tester.pump(const Duration(milliseconds: 20));
      wheel();
      await tester.pump(const Duration(milliseconds: 20));
      await mount('new');
      hold.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(sent, ['old']);
      wheel();
      await tester.pump(const Duration(milliseconds: 20));
      expect(sent, ['old', 'new']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'alternate-screen wheel and touch use Herdr scroll instead of arrow keys',
    (tester) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('\x1b[?1049hFull-screen fixture');
      final scrolled = <int>[], typed = <Object>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalSurface(
            terminal: terminal,
            controller: TerminalController(),
            zoom: 1,
            copy: () async {},
            inputId: 'alternate',
            onScroll: (lines) async {
              scrolled.add(lines);
            },
            sendInput: typed.add,
          ),
        ),
      );
      expect(terminal.isUsingAltBuffer, true);
      final target = tester.getCenter(find.byType(TerminalSurface));
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: target, scrollDelta: const Offset(0, -60)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(scrolled.single, lessThan(0));
      await tester.drag(find.byType(TerminalSurface), const Offset(0, -100));
      await tester.pump(const Duration(milliseconds: 20));
      expect(scrolled.last, greaterThan(0));
      expect(typed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('scroll availability changes preserve focused terminal typing', (
    tester,
  ) async {
    final terminal = Terminal()
      ..resize(80, 24)
      ..write('Fixture');
    final controller = TerminalController();
    var enabled = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TerminalSurface(
              terminal: terminal,
              controller: controller,
              zoom: 1,
              copy: () async {},
              inputId: 'same-pane',
              sendInput: (_) {},
              onScroll: enabled ? (lines) async {} : null,
            );
          },
        ),
      ),
    );
    await tester.tap(find.byType(TerminalView));
    await tester.pump(const Duration(milliseconds: 350));
    final focus = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .focusNode!;
    expect(focus.hasFocus, true);
    update(() => enabled = true);
    await tester.pump();
    expect(
      focus.hasFocus,
      true,
      reason: 'A viewport becoming ready must not interrupt typing.',
    );
    update(() => enabled = false);
    await tester.pump();
    expect(focus.hasFocus, true);
    await tester.pumpWidget(const SizedBox());
  });

  test('scroll stays on the current viewport subscription and cancelled views cannot send', () async {
    final wire = FakeBridge();
    final active = PersistentBridge(wire.open);
    addTearDown(active.close);
    final sub = active.observe(fixtureRoute, cols: 90, rows: 30).listen((_) {});
    await active.request(BridgeLane.streams, 'health', {});
    await active.scroll(fixtureRoute, -5);
    final observed = wire.requests.singleWhere((r) => r['op'] == 'observe');
    final scroll = wire.requests.singleWhere((r) => r['op'] == 'scroll');
    expect(scroll['lane'], 'streams');
    expect(scroll['payload'], {
      'subscription': observed['id'],
      'direction': 'up',
      'steps': 5,
    });
    expect(wire.sentInputs, isEmpty);
    await sub.cancel();
    await expectLater(active.scroll(fixtureRoute, 1), throwsException);
    expect(wire.requests.where((r) => r['op'] == 'scroll'), hasLength(1));
  });
}
