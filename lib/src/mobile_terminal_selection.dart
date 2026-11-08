import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A stable local snapshot: live terminal redraws cannot move the selection.
/// Returning text asks the caller to paste it, never to submit it.
class MobileTerminalSelection extends StatefulWidget {
  const MobileTerminalSelection({
    super.key,
    required this.text,
    required this.canPaste,
  });

  final String text;
  final bool canPaste;

  @override
  State<MobileTerminalSelection> createState() =>
      _MobileTerminalSelectionState();
}

class _MobileTerminalSelectionState extends State<MobileTerminalSelection> {
  late final text = TextEditingController(text: widget.text)
    ..addListener(_changed);
  bool copied = false;

  String get selected =>
      text.selection.isValid ? text.selection.textInside(text.text) : '';

  void _changed() => setState(() => copied = false);

  Future<void> _copy() async {
    final value = selected;
    if (value.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted && selected == value) setState(() => copied = true);
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not copy the selected text.')),
        );
      }
    }
  }

  @override
  void dispose() {
    text.removeListener(_changed);
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close text selection',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: const Text('Select text'),
        actions: [
          IconButton(
            tooltip: copied ? 'Selection copied' : 'Copy selected text',
            onPressed: selected.isEmpty ? null : _copy,
            icon: Icon(copied ? Icons.check : Icons.content_copy),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Hold a word, then drag the selection handles. This text stays still while the session continues.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('terminal-selectable-text'),
                controller: text,
                readOnly: true,
                showCursor: false,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                enableInteractiveSelection: true,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  height: 1.35,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.all(16),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: text.text.isEmpty
                          ? null
                          : () {
                              text.selection = TextSelection(
                                baseOffset: 0,
                                extentOffset: text.text.length,
                              );
                            },
                      child: const Text('Select all'),
                    ),
                    Tooltip(
                      message: 'Paste selection into terminal',
                      child: FilledButton(
                        onPressed: widget.canPaste && selected.isNotEmpty
                            ? () => Navigator.pop(context, selected)
                            : null,
                        child: const Text('Paste selection'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
