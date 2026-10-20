import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'dictation.dart';
import 'dictation_settings.dart';
import 'models.dart';

Future<String?> showDictation(
  BuildContext context,
  AppController app,
  SessionInfo session,
) {
  final generation = app.dictationGeneration;
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        DictationDialog(app: app, session: session, generation: generation),
  );
}

class DictationDialog extends StatefulWidget {
  const DictationDialog({
    super.key,
    required this.app,
    required this.session,
    required this.generation,
    this.capture,
    this.keys,
  });
  final AppController app;
  final SessionInfo session;
  final int generation;
  final DictationCapture? capture;
  final DictationKeys? keys;
  @override
  State<DictationDialog> createState() => _DictationDialogState();
}

class _DictationDialogState extends State<DictationDialog>
    with WidgetsBindingObserver {
  late final capture =
      widget.capture ??
      DictationCapture(
        DictationProvider.parse(widget.app.snapshot.dictationProvider),
      );
  final edited = TextEditingController();
  bool needsKey = false, sending = false, stoppedInBackground = false;
  String? deliveryError;
  bool get targetValid =>
      widget.app.dictationTargetIsCurrent(widget.session, widget.generation);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    capture.addListener(update);
    widget.app.addListener(checkTarget);
    unawaited(start());
  }

  Future<void> start() async {
    try {
      if (!targetValid) {
        setState(
          () => deliveryError = 'Select a connected session before dictating.',
        );
        return;
      }
      final key = await (widget.keys ?? SecureDictationKeys()).read(
        capture.provider,
      );
      if (!mounted) return;
      if (key == null || key.trim().isEmpty) {
        setState(() => needsKey = true);
        return;
      }
      await capture.start(key);
    } catch (_) {
      if (mounted) {
        setState(
          () => deliveryError =
              'Could not read the API key. Check Dictation in Settings.',
        );
      }
    }
  }

  void update() {
    if (!mounted) return;
    if (capture.phase == DictationPhase.review ||
        capture.phase == DictationPhase.failed) {
      if (edited.text.isEmpty) edited.text = capture.text;
    }
    setState(() {});
  }

  void checkTarget() {
    if (!targetValid &&
        !sending &&
        (capture.phase == DictationPhase.starting ||
            capture.phase == DictationPhase.recording)) {
      stoppedInBackground = true;
      unawaited(capture.cancel());
      deliveryError =
          'The session changed or became unavailable. Nothing was sent.';
      edited.text = capture.text;
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (capture.phase != DictationPhase.starting &&
        capture.phase != DictationPhase.recording &&
        capture.phase != DictationPhase.finalizing) {
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      stoppedInBackground = true;
      unawaited(capture.cancel());
      edited.text = capture.text;
      if (mounted) {
        setState(
          () => deliveryError = 'Dictation stopped while the app was in the background. Review the text before sending.',
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.app.removeListener(checkTarget);
    capture.removeListener(update);
    capture.dispose();
    edited.dispose();
    super.dispose();
  }

  Future<void> finish({required bool send}) async {
    await capture.finish();
    if (!mounted) return;
    if (send &&
        !stoppedInBackground &&
        capture.phase == DictationPhase.review) {
      await submit();
    }
  }

  Future<void> submit() async {
    if (sending ||
        !targetValid ||
        capture.phase != DictationPhase.review ||
        edited.text.trim().isEmpty) {
      return;
    }
    setState(() {
      sending = true;
      deliveryError = null;
    });
    final ok = await widget.app.sendDictation(
      widget.session,
      widget.generation,
      edited.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      sending = false;
      deliveryError =
          widget.app.sendStates[widget.session.key.id]?.message ??
          'The session changed. Nothing was sent.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final phase = capture.phase;
    final reviewing =
        phase == DictationPhase.review ||
        phase == DictationPhase.failed ||
        phase == DictationPhase.cancelled;
    final uncertain =
        widget.app.sendStates[widget.session.key.id]?.uncertain == true;
    return PopScope(
      canPop: !sending,
      child: AlertDialog(
        key: const ValueKey('dictation-dialog'),
        scrollable: true,
        title: Text(
          needsKey ? 'Set up dictation' : 'Dictate to ${widget.session.title}',
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (needsKey) ...[
                DictationSettings(app: widget.app, keys: widget.keys),
                const SizedBox(height: 8),
                const Text(
                  'Save your key, close this dialog, then tap the microphone again.',
                ),
              ] else ...[
                Text(
                  '${capture.provider.label} · ${widget.app.computerLabel(widget.session.computerId, origin: widget.session.origin)} · ${widget.session.workspaceLabel}',
                ),
                const SizedBox(height: 12),
                Text(switch (phase) {
                  DictationPhase.starting =>
                    'Connecting and requesting microphone access…',
                  DictationPhase.recording =>
                    'Recording… Tap Review or Stop & Send when finished.',
                  DictationPhase.finalizing => 'Finishing transcript…',
                  DictationPhase.review => 'Review your message',
                  _ => 'Recording stopped',
                }),
                const SizedBox(height: 12),
                if (reviewing)
                  TextField(
                    key: const ValueKey('dictation-review'),
                    controller: edited,
                    minLines: 2,
                    maxLines: 6,
                    enabled: !sending,
                    decoration: const InputDecoration(
                      hintText: 'No speech detected',
                    ),
                    onChanged: (_) => setState(() {}),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 60,
                      maxHeight: 180,
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        capture.text.isEmpty
                            ? 'Your words will appear here.'
                            : capture.text,
                      ),
                    ),
                  ),
                if (capture.error != null || deliveryError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      deliveryError ?? capture.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: sending ? null : () => Navigator.pop(context),
            child: Text(needsKey ? 'Close' : 'Cancel'),
          ),
          if (!needsKey && phase == DictationPhase.recording) ...[
            TextButton(
              onPressed: () => finish(send: false),
              child: const Text('Review'),
            ),
            FilledButton(
              onPressed: targetValid ? () => finish(send: true) : null,
              child: const Text('Stop & Send'),
            ),
          ],
          if (!needsKey && reviewing) ...[
            TextButton(
              onPressed:
                  !sending && targetValid && edited.text.trim().isNotEmpty
                  ? () => Navigator.pop(context, edited.text.trim())
                  : null,
              child: const Text('Keep as draft'),
            ),
            FilledButton(
              onPressed:
                  !sending &&
                      !uncertain &&
                      phase == DictationPhase.review &&
                      targetValid &&
                      edited.text.trim().isNotEmpty
                  ? submit
                  : null,
              child: Text(sending ? 'Sending…' : 'Send'),
            ),
          ],
        ],
      ),
    );
  }
}
