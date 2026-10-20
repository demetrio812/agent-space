import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'controller.dart';
import 'dictation.dart';
import 'dictation_shortcut_settings.dart';

class DictationSettings extends StatefulWidget {
  const DictationSettings({super.key, required this.app, this.keys});
  final AppController app;
  final DictationKeys? keys;
  @override
  State<DictationSettings> createState() => _DictationSettingsState();
}

class _DictationSettingsState extends State<DictationSettings> {
  late final keys = widget.keys ?? SecureDictationKeys();
  final input = TextEditingController();
  bool saved = false, busy = false;
  String? message;
  int request = 0;
  DictationProvider get provider =>
      DictationProvider.parse(widget.app.snapshot.dictationProvider);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++request;
    input.clear();
    setState(() {
      saved = false;
      busy = true;
      message = null;
    });
    try {
      final value = await keys.read(provider);
      if (mounted && token == request) {
        setState(() => saved = value?.isNotEmpty == true);
      }
    } catch (_) {
      if (mounted && token == request) {
        setState(() => message = 'Could not read secure storage. Try again.');
      }
    } finally {
      if (mounted && token == request) setState(() => busy = false);
    }
  }

  Future<void> save({bool remove = false}) async {
    final selected = provider, value = input.text.trim();
    if (!remove &&
        (value.isEmpty ||
            value.length > 4096 ||
            value.contains(RegExp(r'[\r\n]')))) {
      setState(() => message = 'Enter a valid API key.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (remove) {
        await keys.delete(selected);
      } else {
        await keys.write(selected, value);
      }
      if (!mounted) return;
      input.clear();
      setState(() {
        saved = !remove;
        message = remove ? 'API key removed.' : 'API key saved on this device.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not update secure storage. The key was not changed.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Dictation',
        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      if (defaultTargetPlatform == TargetPlatform.macOS) ...[
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keyboard shortcut'),
          subtitle: Text(widget.app.snapshot.dictationShortcut.label),
          value: widget.app.snapshot.dictationShortcut.enabled,
          onChanged: (enabled) => setState(
            () => widget.app.setDictationShortcut(
              widget.app.snapshot.dictationShortcut.copyWith(enabled: enabled),
            ),
          ),
        ),
        TextButton(
          onPressed: () async {
            final value = await editDictationShortcut(
              context,
              widget.app.snapshot.dictationShortcut,
            );
            if (value != null && mounted) {
              setState(() => widget.app.setDictationShortcut(value));
            }
          },
          child: const Text('Change shortcut'),
        ),
        const Text(
          'Starts dictation in the selected session while AgentSpace is active. Saved on this Mac. System shortcuts may take precedence.',
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 10),
      DropdownButtonFormField<DictationProvider>(
        key: ValueKey('dictation-provider-${provider.name}'),
        initialValue: provider,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Transcription provider'),
        items: [
          for (final p in DictationProvider.values)
            DropdownMenuItem(value: p, child: Text(p.label)),
        ],
        onChanged: busy
            ? null
            : (p) {
                if (p == null) return;
                widget.app.setDictationProvider(p.name);
                load();
              },
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('dictation-api-key'),
        controller: input,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        enabled: !busy,
        decoration: InputDecoration(
          labelText: '${provider.label} API key',
          hintText: saved
              ? 'A key is saved. Enter a replacement.'
              : 'Enter your API key',
        ),
        onSubmitted: (_) {
          if (!busy) save();
        },
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.tonal(
            onPressed: busy ? null : () => save(),
            child: const Text('Save API key'),
          ),
          if (saved)
            TextButton(
              onPressed: busy ? null : () => save(remove: true),
              child: const Text('Remove API key'),
            ),
        ],
      ),
      if (message != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!)),
      const SizedBox(height: 8),
      const Text(
        'Tap the microphone in a session to dictate. Audio is sent directly to your selected provider while recording; its API usage charges apply. Keys stay in secure storage on this device and must be added separately on your other devices. AgentSpace does not save audio recordings.',
      ),
    ],
  );
}
