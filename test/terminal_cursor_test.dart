import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:agentspace/src/terminal_pane.dart';
import 'package:agentspace/src/ui_common.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final style in ['', '\x1b[2m', '\x1b[7m', '\x1b[31m']) {
      testWidgets(
        'block cursor keeps its glyph readable: $brightness ${style.codeUnits}',
        (tester) async {
          final terminal = Terminal()
            ..resize(80, 24)
            ..write('${style}M\x1b[0m\r');
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
                  inputId: 'cursor-fixture',
                  autofocus: true,
                  sendInput: (_) {},
                ),
              ),
            ),
          );
          await tester.pump();
          final view = tester.state<TerminalViewState>(
            find.byType(TerminalView),
          );
          expect(view.widget.focusNode!.hasFocus, isTrue);
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final rect = view.globalCursorRect
              .shift(-boundary.localToGlobal(Offset.zero))
              .deflate(1);
          final pixels = await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final result = (data: data!, width: image.width);
            image.dispose();
            return result;
          });
          var darkest = 1.0, lightest = 0.0;
          for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
            for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
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
            reason: 'The block must contain a contrasting glyph, not cover it with a solid rectangle.',
          );
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
        },
      );
    }
  }
}
