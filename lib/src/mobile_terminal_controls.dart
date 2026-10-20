import 'package:flutter/material.dart';

import 'ui_common.dart';

/// These controls must not take focus away from the terminal's text client.
class MobileTerminalKeyBar extends StatelessWidget {
  const MobileTerminalKeyBar({
    super.key,
    required this.enabled,
    required this.control,
    required this.arrows,
    required this.keyboardVisible,
    required this.onControl,
    required this.onArrows,
    required this.onKeyboard,
    required this.onPaste,
    required this.onKey,
    this.statusMenu,
    this.onDictate,
  });
  final Widget? statusMenu;
  final VoidCallback? onDictate;
  final bool enabled, control, arrows, keyboardVisible;
  final VoidCallback onControl, onArrows, onKeyboard, onPaste;
  final ValueChanged<String> onKey;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: context.panel,
        shape: StadiumBorder(side: BorderSide(color: context.border)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _KeyButton(
                'Control next key',
                text: 'Ctrl',
                selected: control,
                onPressed: enabled ? onControl : null,
              ),
              _KeyButton(
                'Escape',
                text: 'Esc',
                onPressed: enabled ? () => onKey('esc') : null,
              ),
              _KeyButton(
                'Tab',
                text: 'Tab',
                onPressed: enabled ? () => onKey('tab') : null,
              ),
              _KeyButton(
                'Arrow keys',
                icon: Icons.control_camera,
                selected: arrows,
                onPressed: onArrows,
              ),
              _KeyButton(
                'Paste into terminal',
                icon: Icons.content_paste,
                onPressed: enabled ? onPaste : null,
              ),
              if (onDictate != null)
                _KeyButton(
                  'Dictate message',
                  icon: Icons.mic_none,
                  onPressed: enabled ? onDictate : null,
                ),
              _KeyButton(
                keyboardVisible ? 'Hide keyboard' : 'Show keyboard',
                icon: keyboardVisible
                    ? Icons.keyboard_hide_outlined
                    : Icons.keyboard_outlined,
                onPressed: enabled ? onKeyboard : null,
              ),
              ?statusMenu,
            ],
          ),
        ),
      ),
    ),
  );
}

/// Connection details occupy one button, leaving the terminal its full height.
class MobileTerminalStatusMenu extends StatelessWidget {
  const MobileTerminalStatusMenu({
    super.key,
    required this.summary,
    required this.details,
    required this.warning,
    required this.onReconnect,
  });
  final String summary;
  final List<String> details;
  final bool warning;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) => Semantics(
    label: summary,
    liveRegion: warning,
    child: SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        tooltip: 'Terminal status & more',
        padding: EdgeInsets.zero,
        onPressed: () async {
          final reconnect = await showDialog<bool>(
            context: context,
            requestFocus: false,
            builder: (dialogContext) => AlertDialog(
              key: const ValueKey('terminal-status-overlay'),
              scrollable: true,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
              backgroundColor: dialogContext.panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: BorderSide(color: dialogContext.border),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Terminal status',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: dialogContext.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close terminal status',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              content: SizedBox(
                width: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Icon(
                            warning
                                ? Icons.info_outline
                                : Icons.check_circle_outline,
                            size: 18,
                            color: warning
                                ? dialogContext.attention
                                : const Color(0xff7ab894),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            summary,
                            style: TextStyle(
                              color: dialogContext.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    for (final text in {...details}..remove(summary))
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          text,
                          style: TextStyle(
                            color: dialogContext.mutedInk,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Reconnect terminal'),
                ),
              ],
            ),
          );
          if (reconnect == true && context.mounted) onReconnect();
        },
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.more_horiz, color: context.ink),
            Positioned(
              right: -2,
              top: -2,
              child: Icon(
                warning ? Icons.warning_amber_rounded : Icons.circle,
                size: warning ? 12 : 7,
                color: warning ? context.attention : const Color(0xff7ab894),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MobileTerminalArrowPad extends StatelessWidget {
  const MobileTerminalArrowPad({
    super.key,
    required this.enabled,
    required this.onKey,
    required this.onClose,
  });
  final bool enabled;
  final ValueChanged<String> onKey;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 216;
        Widget button(
          String key,
          String label,
          IconData icon, {
          bool primary = true,
        }) => _PadKey(
          label: label,
          icon: icon,
          size: compact ? 44 : 52,
          primary: primary,
          onPressed: enabled ? () => onKey(key) : null,
        );
        final left = button('left', 'Arrow left', Icons.chevron_left);
        final right = button('right', 'Arrow right', Icons.chevron_right);
        final up = button('up', 'Arrow up', Icons.keyboard_arrow_up);
        final down = button('down', 'Arrow down', Icons.keyboard_arrow_down);
        final enter = button(
          'enter',
          'Enter',
          Icons.keyboard_return,
          primary: false,
        );
        final backspace = button(
          'backspace',
          'Backspace',
          Icons.backspace_outlined,
          primary: false,
        );
        Widget row(List<Widget> children) =>
            Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: children);
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: compact ? 4 : 10),
            child: compact
                ? row([backspace, left, down, up, right, enter])
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 52,
                        height: 28,
                        child: IconButton(
                          tooltip: 'Hide arrow keys',
                          padding: EdgeInsets.zero,
                          onPressed: onClose,
                          icon: Container(
                            width: 34,
                            height: 5,
                            decoration: BoxDecoration(
                              color: context.mutedInk,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                      row([
                        backspace,
                        up,
                        button(
                          'ctrl+u',
                          'Clear line (Ctrl+U)',
                          Icons.clear_all,
                          primary: false,
                        ),
                      ]),
                      const SizedBox(height: 6),
                      row([left, enter, right]),
                      const SizedBox(height: 6),
                      down,
                    ],
                  ),
          ),
        );
      },
    ),
  );
}

class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.label,
    required this.icon,
    required this.size,
    required this.primary,
    this.onPressed,
  });
  final String label;
  final IconData icon;
  final double size;
  final bool primary;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark
        ? (primary ? const Color(0xff3d4852) : const Color(0xff202b35))
        : (primary ? const Color(0xffe0e7ee) : const Color(0xfff4f7fa));
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        enabled: onPressed != null,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x38000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Material(
            color: base,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: dark ? const Color(0xff53606b) : const Color(0xffc0ccd7),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Icon(
                icon,
                size: 24,
                color: onPressed == null ? context.mutedInk : context.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton(
    this.label, {
    this.text,
    this.icon,
    this.selected = false,
    this.onPressed,
  });
  final String label;
  final String? text;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      button: true,
      label: label,
      toggled: selected ? true : null,
      child: SizedBox(
        width: 44,
        height: 44,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(44, 44),
            foregroundColor: context.ink,
            backgroundColor: selected
                ? context.accent.withValues(alpha: .24)
                : null,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: icon != null
              ? Icon(icon, size: 22)
              : Text(text!, style: const TextStyle(fontSize: 13)),
        ),
      ),
    ),
  );
}
