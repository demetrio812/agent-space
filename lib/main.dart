import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/backend.dart';
import 'src/controller.dart';
import 'src/demo_backend.dart';
import 'src/models.dart';
import 'src/storage.dart';
import 'src/network_backend.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  const nativeWindow = MethodChannel('agentspace/window');
  Map<dynamic, dynamic> bootstrap = {};
  if (Platform.isMacOS) {
    bootstrap = await nativeWindow.invokeMapMethod('bootstrap') ?? {};
  }
  final directory =
      '${(await getApplicationSupportDirectory()).path}/AgentSpace';
  final store = LayoutStore(directory);
  final snapshot = await store.load();
  if (Platform.isMacOS && !snapshot.profiles.any((p) => p.id == 'local')) {
    Map<dynamic, dynamic> discovered = {};
    try {
      discovered =
          await const MethodChannel('agentspace/herdr')
              .invokeMapMethod('discover')
              .timeout(const Duration(seconds: 6)) ??
          {};
    } catch (_) {
      /* Settings retains editable paths if discovery is unavailable. */
    }
    final home =
        bootstrap['userHome'] as String? ?? Platform.environment['HOME'] ?? '';
    snapshot.profiles.insert(
      0,
      ConnectionProfile(
        id: 'local',
        label: 'Local Mac',
        executable:
            discovered['executable'] as String? ?? '$home/.local/bin/herdr',
        socketPath:
            discovered['socketPath'] as String? ??
            '$home/.config/herdr/herdr.sock',
      ),
    );
  }
  if (snapshot.activeSource != 'demo' &&
      !snapshot.profiles.any(
        (p) =>
            p.id == snapshot.activeSource &&
            (desktop || p.kind == ConnectionKind.ssh),
      )) {
    snapshot.activeSource = 'demo';
  }
  final vault = SecureCredentialVault();
  final app = AppController(
    snapshot: snapshot,
    store: store,
    backendFactory: (source) {
      if (source == 'demo') return DemoBackend();
      final profile = snapshot.profiles
          .where((p) => p.id == source)
          .firstOrNull;
      if (profile == null) {
        throw ConnectionFailure(
          'Choose an available connection in Settings.',
          permanent: true,
        );
      }
      return profile.kind == ConnectionKind.local
          ? NetworkHerdrBackend.local(profile)
          : NetworkHerdrBackend.remote(profile, vault);
    },
  );
  if (Platform.isMacOS) {
    await nativeWindow.invokeMethod('restoreGeometry', snapshot.window);
    nativeWindow.setMethodCallHandler((call) async {
      if (call.method == 'geometry' && call.arguments is Map) {
        final values = call.arguments as Map;
        for (final key in ['x', 'y', 'width', 'height']) {
          final value = values[key];
          if (value is num && value.isFinite) {
            snapshot.window[key] = value.toDouble();
          }
        }
        await app.flush();
      }
      if (call.method == 'requestClose') {
        await app.shutdown();
        return true;
      }
      return null;
    });
  }
  runApp(AgentSpaceApp(controller: app, desktop: desktop, vault: vault));
  unawaited(app.start());
}
