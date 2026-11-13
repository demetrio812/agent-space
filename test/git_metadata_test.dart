import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:agentspace/src/git_metadata.dart';
import 'package:agentspace/src/git_metadata_view.dart';
import 'package:agentspace/src/models.dart';
import 'package:agentspace/src/app.dart';

import 'app_widget_test.dart' show createApp, closeApp;

void main() {
  test(
    'repository URLs survive storage and reject credentials and non-web links',
    () {
      final git = GitMetadata.fromJson({
        'repoUrl': 'https://gitlab.example/team/subgroup/repo',
      });
      expect(git.repoUrl, 'https://gitlab.example/team/subgroup/repo');
      expect(GitMetadata.fromJson(git.toJson()).repoUrl, git.repoUrl);
      for (final url in [
        'javascript:evil',
        'file:///repo',
        'https://a:b@github.com/a/b',
        'https://github.com/a/b?token=secret',
        'https://github.com/a/../b',
      ]) {
        expect(GitMetadata.fromJson({'repoUrl': url}).repoUrl, isEmpty);
      }
    },
  );
  testWidgets(
    'repository button opens the validated repository in the browser',
    (tester) async {
      final urls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              if (call.arguments is Map &&
                  (call.arguments as Map)['url'] is String) {
                urls.add((call.arguments as Map)['url'] as String);
              }
              return true;
            },
          );
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  OpenRepositoryButton(
                    metadata: GitMetadata(
                      repoUrl: 'https://github.com/example/project',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Open repository'));
        await tester.pump();
        expect(urls, ['https://github.com/example/project']);
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: OpenRepositoryButton(
                metadata: GitMetadata(repoUrl: 'file:///private/repo'),
              ),
            ),
          ),
        );
        expect(find.byTooltip('Open repository'), findsNothing);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'),
              null,
            );
      }
    },
  );
  test('PR links are validated and metadata survives saved sessions', () {
    final git = GitMetadata.fromJson({
      'branch': 'feature/one',
      'prNumber': 42,
      'prState': 'OPEN',
      'prUrl': 'https://github.com/example/project/pull/42',
    });
    expect(git.prUrl, isNotEmpty);
    for (final url in [
      'javascript:evil',
      'file:///tmp/a',
      'https://a:b@github.com/a/b/pull/42',
      'https://github.com/a/b/pull/43',
    ]) {
      expect(
        GitMetadata.fromJson({...git.toJson(), 'prUrl': url}).prUrl,
        isEmpty,
      );
    }
    final s = SessionInfo(
      key: const SessionKey('demo', 'demo', 'sample-v1', 't1'),
      paneId: 'p1',
      title: 'Demo',
      project: 'project',
      agent: 'terminal',
      status: SessionStatus.idle,
      git: git,
    );
    expect(SessionInfo.fromJson(s.toJson())!.git.branch, 'feature/one');
    expect(s.unavailable().git.prNumber, 42);
  });
  for (final size in [
    const Size(320, 740),
    const Size(390, 844),
    const Size(844, 390),
    const Size(1200, 800),
  ]) {
    testWidgets('branch and PR fit a session at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = await createApp();
      try {
        app.select(app.sessions.first.key.id);
        await tester.pumpWidget(
          AgentSpaceApp(controller: app, desktop: size.width == 1200),
        );
        await tester.pumpAndSettle();
        expect(find.byType(GitMetadataView), findsWidgets);
        expect(find.byTooltip('Open repository'), findsOneWidget);
        expect(find.text('feature/navigation'), findsWidgets);
        expect(find.text('#42 · open'), findsWidgets);
        final git = tester.getRect(find.byType(GitMetadataView).first);
        expect(
          tester.getSize(find.byKey(const ValueKey('session-header'))).height,
          lessThanOrEqualTo(56),
        );
        final session = app.selectedSession!;
        final location =
            '${app.computerLabel(session.computerId, origin: session.origin)} · ${session.workspaceLabel.isNotEmpty ? session.workspaceLabel : session.project}';
        final locationRect = tester.getRect(find.text(location).first);
        expect((git.center.dy - locationRect.center.dy).abs(), lessThan(2));
        expect(git.left, greaterThan(locationRect.left));
        final actions = tester.getRect(find.byTooltip('Terminal controls'));
        expect(git.top, greaterThanOrEqualTo(actions.bottom - 1));
        expect((git.right - actions.right).abs(), lessThan(3));
        expect(tester.takeException(), isNull);
      } finally {
        await closeApp(tester, app);
      }
    });
  }
}
