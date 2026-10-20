import 'package:flutter/services.dart';

/// Device-local, app-scoped shortcut. Never registers a global system hotkey.
class DictationShortcut {
  const DictationShortcut({
    this.enabled = true,
    this.key = 'D',
    this.command = true,
    this.control = false,
    this.option = false,
    this.shift = true,
  });
  final bool enabled, command, control, option, shift;
  final String key;
  static final keys = <String, LogicalKeyboardKey>{
    for (var code = 65; code <= 90; code++)
      String.fromCharCode(code): LogicalKeyboardKey(code + 32),
    for (var code = 48; code <= 57; code++)
      String.fromCharCode(code): LogicalKeyboardKey(code),
    'Space': LogicalKeyboardKey.space,
  };
  String get label =>
      '${control ? '⌃' : ''}${option ? '⌥' : ''}${command ? '⌘' : ''}${shift ? '⇧' : ''}$key';
  String? get validationError {
    if (!keys.containsKey(key)) return 'Choose a letter, number or Space.';
    if (!command && !control) return 'Include Command or Control.';
    // Preserve native editing, navigation and window/system commands.
    if (command &&
        !control &&
        !option &&
        !shift &&
        {
          'A',
          'C',
          'D',
          'F',
          'E',
          'G',
          'J',
          'H',
          'M',
          'N',
          'O',
          'P',
          'Q',
          'R',
          'S',
          'V',
          'W',
          'X',
          'Z',
          '0',
          '1',
          'Space',
        }.contains(key)) {
      return 'This shortcut is already used by macOS or AgentSpace. Add a modifier or choose another key.';
    }
    if (command && control && !option && !shift && key == 'F' ||
        command && option && !control && !shift && key == 'F' ||
        command && option && !control && shift && key == 'V' ||
        command &&
            !control &&
            !option &&
            shift &&
            {'Q', 'W', 'Z', 'G', '3', '4', '5'}.contains(key) ||
        command &&
            option &&
            !control &&
            {'H', 'M', 'W', 'Space'}.contains(key) ||
        control &&
            !command &&
            !option &&
            !shift &&
            {'F', 'Space'}.contains(key)) {
      return 'This shortcut is already used by macOS or AgentSpace. Choose another combination.';
    }
    return null;
  }

  bool matches(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return enabled &&
        validationError == null &&
        event.logicalKey == keys[key] &&
        keyboard.isMetaPressed == command &&
        keyboard.isControlPressed == control &&
        keyboard.isAltPressed == option &&
        keyboard.isShiftPressed == shift;
  }

  DictationShortcut copyWith({
    bool? enabled,
    String? key,
    bool? command,
    bool? control,
    bool? option,
    bool? shift,
  }) => DictationShortcut(
    enabled: enabled ?? this.enabled,
    key: key ?? this.key,
    command: command ?? this.command,
    control: control ?? this.control,
    option: option ?? this.option,
    shift: shift ?? this.shift,
  );
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'key': key,
    'command': command,
    'control': control,
    'option': option,
    'shift': shift,
  };
  static DictationShortcut fromJson(dynamic value) {
    if (value is! Map ||
        value['key'] is! String ||
        [
          'enabled',
          'command',
          'control',
          'option',
          'shift',
        ].any((name) => value[name] != null && value[name] is! bool)) {
      return const DictationShortcut();
    }
    final result = DictationShortcut(
      enabled: value['enabled'] != false,
      key: value['key'],
      command: value['command'] == true,
      control: value['control'] == true,
      option: value['option'] == true,
      shift: value['shift'] == true,
    );
    return result.validationError == null ? result : const DictationShortcut();
  }
}
