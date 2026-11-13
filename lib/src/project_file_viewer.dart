import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'project_files.dart';
import 'ui_common.dart';

String prepareProjectHtml(String source) => '''<!doctype html><html><head>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
<meta name="viewport" content="width=device-width,initial-scale=1">
</head><body>$source</body></html>''';

bool projectPreviewNavigationAllowed(String url) => url == 'about:blank';

(int, int) projectTaskProgress(String text) {
  final matches = RegExp(
    r'^[ \t]*[-*+][ \t]+\[([ xX\-~])\]',
    multiLine: true,
  ).allMatches(text).toList();
  return (
    matches.where((m) => m[1]!.toLowerCase() == 'x').length,
    matches.length,
  );
}

class ProjectFileViewer extends StatefulWidget {
  const ProjectFileViewer({
    super.key,
    required this.file,
    required this.document,
    required this.onLink,
  });
  final ProjectFile file;
  final ProjectDocument document;
  final ValueChanged<String> onLink;
  @override
  State<ProjectFileViewer> createState() => _ProjectFileViewerState();
}

class _ProjectFileViewerState extends State<ProjectFileViewer> {
  final scroll = ScrollController();
  WebViewController? web;
  bool source = false, ready = false, failed = false;
  Offset? restore;
  (int, int) progress = (0, 0);
  @override
  void initState() {
    super.initState();
    if (widget.file.kind != 'html') {
      progress = projectTaskProgress(widget.document.text);
    }
    if (widget.file.kind == 'html' && WebViewPlatform.instance != null) {
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    try {
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.disabled);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              projectPreviewNavigationAllowed(request.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) async {
            final position = restore;
            restore = null;
            if (position != null && mounted) {
              await controller.scrollTo(
                position.dx.round(),
                position.dy.round(),
              );
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => failed = true);
            }
          },
        ),
      );
      if (!mounted) return;
      web = controller;
      await controller.loadHtmlString(prepareProjectHtml(widget.document.text));
      if (mounted) setState(() => ready = true);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  void didUpdateWidget(covariant ProjectFileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.document.text != oldWidget.document.text ||
        widget.file.kind != oldWidget.file.kind) {
      progress = widget.file.kind == 'html'
          ? (0, 0)
          : projectTaskProgress(widget.document.text);
    }
    if (widget.document.text != oldWidget.document.text && web != null) {
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    try {
      final controller = web!;
      restore = await controller.getScrollPosition();
      if (mounted) {
        await controller.loadHtmlString(
          prepareProjectHtml(widget.document.text),
        );
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final html = widget.file.kind == 'html';
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: context.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.file.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: context.mutedInk),
                ),
              ),
              if (html)
                TextButton(
                  onPressed: () => setState(() => source = !source),
                  child: Text(
                    source ? 'Preview' : 'Source',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
        if (html)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              'Preview only · scripts and external resources are disabled',
              style: TextStyle(fontSize: 10, color: context.mutedInk),
            ),
          ),
        if (!html && progress.$2 > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${progress.$1} of ${progress.$2} complete',
                  style: TextStyle(fontSize: 11, color: context.mutedInk),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: progress.$1 / progress.$2,
                  minHeight: 3,
                ),
              ],
            ),
          ),
        Expanded(
          child: html && !source && ready && !failed && web != null
              ? WebViewWidget(controller: web!)
              : SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsets.all(18),
                  child: SelectionArea(
                    child: html
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!source)
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    'HTML source · preview is unavailable on this platform',
                                  ),
                                ),
                              Text(
                                widget.document.text,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: context.ink,
                                ),
                              ),
                            ],
                          )
                        : MarkdownBody(
                            data: widget.document.text,
                            onTapLink: (_, href, _) {
                              if (href != null) widget.onLink(href);
                            },
                            imageBuilder: (_, _, alt) => Text(
                              '[${alt?.isNotEmpty == true ? alt : 'Image'}]',
                            ),
                            styleSheet:
                                MarkdownStyleSheet.fromTheme(Theme.of(context))
                                    .copyWith(
                                      p: TextStyle(
                                        color: context.ink,
                                        fontSize: 13,
                                        height: 1.6,
                                      ),
                                      code: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                      ),
                                      codeblockDecoration: BoxDecoration(
                                        color: context.panel,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                          ),
                  ),
                ),
        ),
      ],
    );
  }
}
