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
  });
  final bool enabled, control, arrows, keyboardVisible;
  final VoidCallback onControl, onArrows, onKeyboard, onPaste;
  final ValueChanged<String> onKey;

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              _KeyButton(
                keyboardVisible ? 'Hide keyboard' : 'Show keyboard',
                icon: keyboardVisible
                    ? Icons.keyboard_hide_outlined
                    : Icons.keyboard_outlined,
                onPressed: enabled ? onKeyboard : null,
              ),
            ],
          ),
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
  });
  final bool enabled;
  final ValueChanged<String> onKey;
  @override
  Widget build(BuildContext context) {
    Widget button(String key, String label, IconData icon) => _KeyButton(
      label,
      icon: icon,
      onPressed: enabled ? () => onKey(key) : null,
    );
    final left = button('left', 'Arrow left', Icons.chevron_left);
    final right = button('right', 'Arrow right', Icons.chevron_right);
    final up = button('up', 'Arrow up', Icons.keyboard_arrow_up);
    final down = button('down', 'Arrow down', Icons.keyboard_arrow_down);
    final enter = button('enter', 'Enter', Icons.keyboard_return);
    final backspace = button(
      'backspace',
      'Backspace',
      Icons.backspace_outlined,
    );
    return ExcludeFocus(
      child: LayoutBuilder(
        builder: (context, box) => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Material(
              color: context.panel,
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: context.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: box.maxHeight < 164
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [backspace, left, down, up, right, enter],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              backspace,
                              up,
                              button(
                                'ctrl+u',
                                'Clear line (Ctrl+U)',
                                Icons.clear_all,
                              ),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [left, enter, right],
                          ),
                          down,
                        ],
                      ),
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
