import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'controller.dart';
import 'conversation.dart';
import 'models.dart';
import 'ui_common.dart';

/// Opt-in transcript reader. Terminal is always available for native prompts.
class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.app,
    required this.session,
    required this.active,
    required this.onTerminal,
  });
  final AppController app;
  final SessionInfo session;
  final bool active;
  final VoidCallback onTerminal;
  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final scroll = ScrollController();
  final draft = TextEditingController();
  final center = GlobalKey();
  final history = <ConversationMessage>[], live = <ConversationMessage>[];
  Timer? timer;
  ConversationPage? page;
  String before = '';
  // Pinned independently of transient pages; only explicit Reload may rebind.
  String boundSession = '';
  String? error;
  bool busy = false, earlierBusy = false, hasEarlier = false, limitHit = false;
  bool wasRunning = false;
  int epoch = 0, newMessages = 0, scrollIntent = 0;
  bool get running =>
      widget.active &&
      widget.app.isActive &&
      widget.app.layout.selectedId == widget.session.key.id;
  bool get atBottom => !scroll.hasClients || scroll.position.extentAfter < 80;

  @override
  void initState() {
    super.initState();
    widget.app.claimConversationComposer(widget.session.key.id, this);
    _syncDraft();
    widget.app.addListener(_appChanged);
    scroll.addListener(_scrolled);
    wasRunning = running;
    if (running) unawaited(_read());
  }

  void _syncDraft() {
    final value = widget.app.layout.drafts[widget.session.key.id] ?? '';
    if (value != draft.text) {
      draft.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  void _appChanged() {
    if (!mounted) return;
    _syncDraft();
    _activity();
    setState(() {});
  }

  void _activity() {
    if (running == wasRunning) return;
    wasRunning = running;
    epoch++;
    timer?.cancel();
    timer = null;
    busy = false;
    earlierBusy = false;
    if (running) unawaited(_read());
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app ||
        oldWidget.session.key != widget.session.key) {
      oldWidget.app.releaseConversationComposer(oldWidget.session.key.id, this);
      oldWidget.app.removeListener(_appChanged);
      widget.app.claimConversationComposer(widget.session.key.id, this);
      widget.app.addListener(_appChanged);
      epoch++;
      timer?.cancel();
      busy = false;
      earlierBusy = false;
      page = null;
      boundSession = '';
      history.clear();
      live.clear();
      before = '';
      hasEarlier = false;
      limitHit = false;
      error = null;
      newMessages = 0;
      wasRunning = false;
    }
    _syncDraft();
    _activity();
  }

  void _schedule() {
    timer?.cancel();
    timer = null;
    if (running && !limitHit && page?.status != 'session_changed') {
      timer = Timer(const Duration(seconds: 2), () => unawaited(_read()));
    }
  }

  bool _fits(List<ConversationMessage> values) =>
      values.length <= 500 &&
      values.fold<int>(0, (n, m) => n + m.text.length) <= 4 * 1024 * 1024;

  Future<void> _read({bool earlier = false, bool reset = false}) async {
    if (!running || busy || earlierBusy || limitHit && !reset) return;
    if (reset) {
      epoch++;
      page = null;
      boundSession = '';
      live.clear();
      history.clear();
      before = '';
      hasEarlier = false;
      error = null;
      limitHit = false;
      newMessages = 0;
    }
    final currentEpoch = epoch,
        initial = page == null,
        follow = atBottom,
        readScrollIntent = scrollIntent;
    setState(() {
      if (earlier) {
        earlierBusy = true;
      } else {
        busy = true;
      }
    });
    try {
      final result = await widget.app.readConversation(
        widget.session,
        conversationSession: boundSession,
        before: earlier ? before : '',
      );
      if (!mounted || currentEpoch != epoch || !running) return;
      if (boundSession.isNotEmpty &&
          result.session != boundSession &&
          result.status != 'unbound') {
        const changed = ConversationPage(
          session: '',
          status: 'session_changed',
          messages: [],
        );
        setState(() {
          page = changed;
          error = changed.explanation;
        });
        return;
      }
      if (boundSession.isEmpty && result.status != 'session_changed') {
        boundSession = result.session;
      }
      if (!result.available) {
        setState(() {
          page = result;
          error = result.explanation;
        });
        return;
      }
      final oldIds = live.map((m) => m.id).toSet();
      final incoming = result.messages;
      if (earlier) {
        final ids = {...history.map((m) => m.id), ...oldIds};
        final additions = incoming.where((m) => !ids.contains(m.id)).toList();
        if (!_fits([...additions, ...history, ...live])) {
          setState(() {
            limitHit = true;
            error = 'History limit reached. Reload Chat to start from the latest messages.';
          });
          return;
        }
        setState(() {
          history.insertAll(0, additions);
          before = result.before;
          hasEarlier = result.hasEarlier;
          error = null;
        });
      } else {
        var prefix = 0;
        if (incoming.isNotEmpty) {
          prefix = live.indexWhere((m) => m.id == incoming.first.id);
        }
        final replacement = [if (prefix > 0) ...live.take(prefix), ...incoming];
        if (!_fits([...history, ...replacement])) {
          setState(() {
            limitHit = true;
            error = 'History limit reached. Reload Chat to start from the latest messages.';
          });
          return;
        }
        final added = incoming.where((m) => !oldIds.contains(m.id)).length;
        final followNow =
            follow && atBottom && readScrollIntent == scrollIntent;
        setState(() {
          // No shared anchor means a rewind/compaction changed the chain. Do
          // not retain messages that the authoritative transcript has dropped.
          if (!initial && prefix < 0) history.clear();
          live
            ..clear()
            ..addAll(replacement);
          page = result;
          error = null;
          if (initial || history.isEmpty && prefix <= 0) {
            before = result.before;
            hasEarlier = result.hasEarlier;
          }
          if (!initial && !followNow) newMessages += added;
        });
        if (initial || followNow) _bottom();
      }
    } catch (_) {
      if (mounted && currentEpoch == epoch && running) {
        setState(
          () => error = 'Chat could not refresh. The messages shown are cached; open Terminal or try again.',
        );
      }
    } finally {
      if (mounted && currentEpoch == epoch) {
        setState(() {
          busy = false;
          earlierBusy = false;
        });
        _schedule();
      }
    }
  }

  void _scrolled() {
    if (newMessages > 0 && atBottom && mounted) setState(() => newMessages = 0);
  }

  void _bottom() => _settleBottom(++scrollIntent, 0);

  void _settleBottom(int intent, int attempts) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !scroll.hasClients ||
          !running ||
          intent != scrollIntent) {
        return;
      }
      scroll.jumpTo(scroll.position.maxScrollExtent);
      if (newMessages != 0) setState(() => newMessages = 0);
      if (attempts < 2) _settleBottom(intent, attempts + 1);
    });
  }

  Future<void> _copy(ConversationMessage message) async {
    try {
      await Clipboard.setData(ClipboardData(text: message.text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              message.truncated
                  ? 'Preview copied; this message is truncated.'
                  : 'Response copied',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not copy this response.')),
        );
      }
    }
  }

  Future<void> _link(String? value) async {
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _send() async {
    final current = page;
    if (current == null ||
        !current.available ||
        !current.canSend ||
        current.session != boundSession ||
        !widget.session.inputEnabled ||
        error != null ||
        !running) {
      return;
    }
    final app = widget.app, generation = app.dictationGeneration;
    app.updateDraft(widget.session.key.id, draft.text);
    final sent = await app.sendDraft(
      widget.session.key.id,
      conversationSession: boundSession,
      expectedSession: widget.session,
      expectedGeneration: generation,
    );
    if (mounted && sent && running) {
      _syncDraft();
      _bottom();
      unawaited(_read());
    }
  }

  @override
  void dispose() {
    epoch++;
    timer?.cancel();
    widget.app.releaseConversationComposer(widget.session.key.id, this);
    widget.app.removeListener(_appChanged);
    scroll.removeListener(_scrolled);
    scroll.dispose();
    draft.dispose();
    super.dispose();
  }

  Widget _message(ConversationMessage message) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Container(
        key: ValueKey('chat-message-${message.id}'),
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
        decoration: BoxDecoration(
          color: message.role == 'user' ? context.panel : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    switch (message.role) {
                      'user' => 'You',
                      'assistant' => 'Claude',
                      _ => 'Session',
                    },
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: context.mutedInk,
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('copy-response-${message.id}'),
                  tooltip: 'Copy response',
                  onPressed: message.text.isEmpty
                      ? null
                      : () => unawaited(_copy(message)),
                  icon: const Icon(Icons.content_copy, size: 18),
                ),
              ],
            ),
            if (message.text.isNotEmpty)
              SelectionArea(
                child: MarkdownBody(
                  data: message.text,
                  onTapLink: (_, href, _) => unawaited(_link(href)),
                  imageBuilder: (_, _, alt) => Text(
                    '[${alt?.isNotEmpty == true ? alt : 'Image — open Terminal to view'}]',
                  ),
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                        p: TextStyle(
                          color: context.ink,
                          fontSize: 14,
                          height: 1.5,
                        ),
                        code: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: context.panel,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                ),
              ),
            if (message.tools.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Tools · ${message.tools.join(' · ')}',
                  style: TextStyle(color: context.mutedInk, fontSize: 12),
                ),
              ),
            if (message.truncated)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'This message exceeds the preview limit. Copy includes only the preview.',
                ),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final state = widget.app.sendStates[widget.session.key.id];
    final last = [
      ...history,
      ...live,
    ].where((m) => m.role == 'assistant' && m.text.isNotEmpty).lastOrNull;
    final command = RegExp(r'^\s*[/!]').hasMatch(draft.text);
    final canSend =
        running &&
        widget.session.inputEnabled &&
        page?.session == boundSession &&
        page?.canSend == true &&
        error == null &&
        !command &&
        state?.sending != true &&
        state?.uncertain != true &&
        !widget.app.terminalInputPending(widget.session.key.id) &&
        draft.text.trim().isNotEmpty;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
          if (canSend) unawaited(_send());
        },
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (canSend) unawaited(_send());
        },
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Chat · experimental',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.mutedInk, fontSize: 11),
                  ),
                ),
                if (newMessages > 0)
                  Badge(
                    label: Text(newMessages > 99 ? '99+' : '$newMessages'),
                    child: IconButton(
                      tooltip: 'Jump to latest',
                      onPressed: _bottom,
                      icon: const Icon(Icons.arrow_downward),
                    ),
                  ),
                IconButton(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    visualDensity: VisualDensity.standard,
                  ),
                  tooltip: 'Copy last response',
                  onPressed: last == null ? null : () => unawaited(_copy(last)),
                  icon: const Icon(Icons.content_copy, size: 18),
                ),
                IconButton(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    visualDensity: VisualDensity.standard,
                  ),
                  tooltip: 'Reload Chat',
                  onPressed: busy || earlierBusy
                      ? null
                      : () => unawaited(_read(reset: true)),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                IconButton(
                  style: IconButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    visualDensity: VisualDensity.standard,
                  ),
                  tooltip: 'Open Terminal',
                  onPressed: widget.onTerminal,
                  icon: const Icon(Icons.terminal, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: live.isEmpty && history.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        busy
                            ? 'Loading conversation…'
                            : error ?? 'No conversation messages yet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : NotificationListener<UserScrollNotification>(
                    onNotification: (notification) {
                      if (notification.direction != ScrollDirection.idle) {
                        scrollIntent++;
                      }
                      return false;
                    },
                    child: CustomScrollView(
                      key: const ValueKey('chat-history'),
                      controller: scroll,
                      center: center,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Center(
                            child: hasEarlier
                                ? TextButton(
                                    onPressed: earlierBusy || busy || limitHit
                                        ? null
                                        : () => unawaited(_read(earlier: true)),
                                    child: Text(
                                      earlierBusy
                                          ? 'Loading…'
                                          : 'Load earlier messages',
                                    ),
                                  )
                                : const SizedBox(height: 8),
                          ),
                        ),
                        SliverList.builder(
                          itemCount: history.length,
                          itemBuilder: (_, i) =>
                              _message(history[history.length - 1 - i]),
                        ),
                        SliverList.builder(
                          key: center,
                          itemCount: live.length,
                          itemBuilder: (_, i) => _message(live[i]),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                      ],
                    ),
                  ),
          ),
          if (error != null && (live.isNotEmpty || history.isNotEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                error!,
                style: TextStyle(color: context.attention, fontSize: 12),
              ),
            ),
          if (state?.message != null && state?.uncertain != true)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                state!.message!,
                style: TextStyle(color: context.mutedInk, fontSize: 12),
              ),
            ),
          if (page?.canSend != true || command)
            TextButton(
              onPressed: widget.onTerminal,
              child: Text(
                command ? 'Open Terminal for this command' : 'Open Terminal',
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('chat-composer'),
                      controller: draft,
                      minLines: 1,
                      maxLines: 5,
                      onChanged: (text) {
                        widget.app.updateDraft(widget.session.key.id, text);
                        setState(() {});
                      },
                      decoration: const InputDecoration(
                        hintText: 'Message Claude',
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      textInputAction: TextInputAction.newline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send text + Enter',
                    onPressed: canSend ? () => unawaited(_send()) : null,
                    icon: state?.sending == true
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
