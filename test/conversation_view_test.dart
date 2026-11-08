import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agentspace/src/controller.dart';
import 'package:agentspace/src/storage.dart';
import 'package:agentspace/src/conversation_view.dart';
import 'package:agentspace/src/ui_common.dart';
import 'package:agentspace/src/terminal_pane.dart';

import 'app_widget_test.dart' show createApp, closeApp;

import 'conversation_test.dart' show ChatFixture, chatPage;
import 'terminal_input_test.dart' show WidgetStore;

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1200, 800),
  ]) {
    testWidgets(
      'native Chat copies the complete answer beyond the viewport at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final text =
            '## Complete answer\n\n${List.generate(80, (i) => 'Paragraph $i with useful text.').join('\n\n')}\n\n```dart\nfinal done = true;\n```';
        final backend = ChatFixture()..page = chatPage(text: text);
        final app = AppController(
          snapshot: AppSnapshot(),
          store: WidgetStore(),
          backendFactory: (_) => backend,
        );
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'];
            }
            return null;
          },
        );
        try {
          await app.start(polling: false);
          app.select(backend.session.key.id);
          await tester.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(Brightness.dark),
              home: Scaffold(
                body: ConversationView(
                  app: app,
                  session: backend.session,
                  active: true,
                  onTerminal: () {},
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.byTooltip('Copy last response'));
          await tester.pump();
          expect(clipboard, text);
          expect(backend.chatSends, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(app.shutdown);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        }
      },
    );
  }
  testWidgets(
    'blocked Chat keeps the draft and offers Terminal rather than sending',
    (tester) async {
      final backend = ChatFixture()..page = chatPage(canSend: false);
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      var terminalOpened = false;
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        app.updateDraft(backend.session.key.id, 'keep draft');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationView(
                app: app,
                session: backend.session,
                active: true,
                onTerminal: () => terminalOpened = true,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final send = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.arrow_upward),
        );
        expect(send.onPressed, isNull);
        await tester.tap(find.text('Open Terminal').last);
        expect(terminalOpened, isTrue);
        expect(app.layout.drafts[backend.session.key.id], 'keep draft');
        expect(backend.chatSends, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
  testWidgets(
    'loading earlier messages preserves the current reading position',
    (tester) async {
      final backend = ChatFixture();
      backend.page = {...chatPage(), 'hasEarlier': true};
      backend.earlierPage = {
        ...chatPage(text: 'Earlier conversation'),
        'messages': [
          {
            'id': '33333333-3333-4333-8333-333333333333',
            'role': 'user',
            'text': 'Earlier conversation',
            'tools': <String>[],
            'truncated': false,
          },
        ],
        'before': '33333333-3333-4333-8333-333333333333',
      };
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationView(
                app: app,
                session: backend.session,
                active: true,
                onTerminal: () {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.drag(
          find.byKey(const ValueKey('chat-history')),
          const Offset(0, 500),
        );
        await tester.pumpAndSettle();
        final anchor = find.byKey(
          const ValueKey('chat-message-22222222-2222-4222-8222-222222222222'),
        );
        final top = tester.getTopLeft(anchor).dy;
        await tester.tap(find.text('Load earlier messages'));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(anchor).dy, closeTo(top, 1));
        expect(backend.reads, 2);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );

  testWidgets('Chat stops polling when the app backgrounds', (tester) async {
    final backend = ChatFixture();
    final app = AppController(
      snapshot: AppSnapshot(),
      store: WidgetStore(),
      backendFactory: (_) => backend,
    );
    try {
      await app.start(polling: false);
      app.select(backend.session.key.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationView(
              app: app,
              session: backend.session,
              active: true,
              onTerminal: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(backend.reads, 1);
      await app.setActive(false);
      await tester.pump(const Duration(seconds: 5));
      expect(backend.reads, 1);
      await app.setActive(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(backend.reads, 2);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(app.shutdown);
    }
  });
  testWidgets('Chat embedded in the session remains readable in light mode', (
    tester,
  ) async {
    final app = await createApp();
    try {
      app.select(app.sessions.first.key.id);
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(Brightness.light),
          home: Scaffold(
            body: AnimatedBuilder(
              animation: app,
              builder: (_, _) => TerminalPane(
                app: app,
                session: app.selectedSession!,
                compact: true,
                mobileControls: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('Chat view (experimental)'));
      await tester.pump(const Duration(milliseconds: 500));
      final view = find.byType(ConversationView);
      final container = tester.widget<Container>(
        find
            .ancestor(
              of: view,
              matching: find.byWidgetPredicate(
                (w) => w is Container && w.color != null,
              ),
            )
            .first,
      );
      final foreground = tester.element(view).ink.computeLuminance();
      final background = container.color!.computeLuminance();
      expect(
        (background + .05) / (foreground + .05),
        greaterThanOrEqualTo(4.5),
      );
    } finally {
      await closeApp(tester, app);
    }
  });
  testWidgets(
    'Chat Send uses the bound conversation and clears only the delivered draft',
    (tester) async {
      final backend = ChatFixture();
      final app = AppController(
        snapshot: AppSnapshot(),
        store: WidgetStore(),
        backendFactory: (_) => backend,
      );
      try {
        await app.start(polling: false);
        app.select(backend.session.key.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ConversationView(
                app: app,
                session: backend.session,
                active: true,
                onTerminal: () {},
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.enterText(
          find.byKey(const ValueKey('chat-composer')),
          'Reviewed message',
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Send text + Enter'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(backend.chatSends, 1);
        expect(backend.receivedText, 'Reviewed message');
        expect(backend.receivedSession, '11111111-1111-4111-8111-111111111111');
        expect(backend.composedCalls, 0);
        expect(app.layout.drafts[backend.session.key.id], isNull);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
              .controller!
              .text,
          isEmpty,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(app.shutdown);
      }
    },
  );
}
