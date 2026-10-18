import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:agentspace/src/ui_common.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('selected terminal text remains visible in $brightness', (
      tester,
    ) async {
      final terminal = Terminal()
        ..resize(80, 24)
        ..write('READABLE');
      final controller = TerminalController();
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(brightness),
          home: RepaintBoundary(
            key: key,
            child: TerminalSurface(
              terminal: terminal,
              controller: controller,
              zoom: 1,
              copy: () async {},
              inputId: 'selection-fixture',
            ),
          ),
        ),
      );
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(8, 0),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final result = (data: data!, width: image.width);
        image.dispose();
        return result;
      });
      // The selected first cells must contain both glyphs and background,
      // not a solid rectangle painted over every character.
      var darkest = 1.0, lightest = 0.0;
      for (var y = 8; y < 20; y++) {
        for (var x = 10; x < 45; x++) {
          final offset = (y * pixels!.width + x) * 4;
          final luminance = Color.fromARGB(
            255,
            pixels.data.getUint8(offset),
            pixels.data.getUint8(offset + 1),
            pixels.data.getUint8(offset + 2),
          ).computeLuminance();
          if (luminance < darkest) darkest = luminance;
          if (luminance > lightest) lightest = luminance;
        }
      }
      expect(
        (lightest + .05) / (darkest + .05),
        greaterThanOrEqualTo(4.5),
        reason:
            'Selected characters must remain readable against their highlight.',
      );
      expect(terminal.buffer.getText(controller.selection!), 'READABLE');
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }
}
