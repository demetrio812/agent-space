import 'package:flutter/material.dart';

import 'dictation_shortcut.dart';

Future<DictationShortcut?> editDictationShortcut(
  BuildContext context,
  DictationShortcut initial,
) {
  var value = initial;
  return showDialog<DictationShortcut>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Dictation shortcut'),
        scrollable: true,
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose modifiers and a key. Include Command or Control.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('⌘ Command'),
                    selected: value.command,
                    onSelected: (selected) =>
                        update(() => value = value.copyWith(command: selected)),
                  ),
                  FilterChip(
                    label: const Text('⌃ Control'),
                    selected: value.control,
                    onSelected: (selected) =>
                        update(() => value = value.copyWith(control: selected)),
                  ),
                  FilterChip(
                    label: const Text('⌥ Option'),
                    selected: value.option,
                    onSelected: (selected) =>
                        update(() => value = value.copyWith(option: selected)),
                  ),
                  FilterChip(
                    label: const Text('⇧ Shift'),
                    selected: value.shift,
                    onSelected: (selected) =>
                        update(() => value = value.copyWith(shift: selected)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('shortcut-key'),
                initialValue: value.key,
                decoration: const InputDecoration(labelText: 'Key'),
                isExpanded: true,
                items: [
                  for (final key in DictationShortcut.keys.keys)
                    DropdownMenuItem(value: key, child: Text(key)),
                ],
                onChanged: (key) {
                  if (key != null) {
                    update(() => value = value.copyWith(key: key));
                  }
                },
              ),
              const SizedBox(height: 12),
              Text(value.label, style: Theme.of(context).textTheme.titleLarge),
              if (value.validationError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    value.validationError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: value.validationError == null
                ? () => Navigator.pop(context, value)
                : null,
            child: const Text('Save shortcut'),
          ),
        ],
      ),
    ),
  );
}
