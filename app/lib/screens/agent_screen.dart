import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../models/agent.dart';
import '../models/misc.dart';
import '../state/app_state.dart';
import '../state/conversation.dart';
import '../widgets/message_tile.dart';
import '../widgets/status.dart';

/// One agent: its conversation, its dialog when blocked, and a composer.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key, required this.agent});

  /// `name@machine`.
  final String agent;

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  Conversation? _conv;
  AppState? _app;
  String? _seen;
  final _scroll = ScrollController();
  final _input = TextEditingController();
  bool _sending = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_conv != null) return;
    final app = _app = AppScope.read(context);
    _conv = Conversation(app.client!, widget.agent)..loadTail();
    AppState.onScreen = widget.agent;
    unawaited(app.push.clear(widget.agent).catchError((_) {}));
    _seen = app.snapshot.byId(widget.agent)?.fingerprint;
    if (app.snapshot.byId(widget.agent)?.status == 'blocked') _conv!.fetchScreen();
    app.addListener(_onApp);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _app?.removeListener(_onApp);
    if (AppState.onScreen == widget.agent) AppState.onScreen = null;
    _conv?.dispose();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  /// Every change to this agent's row (status, unread, anything) means
  /// there may be more to read, and a new dialog when it is blocked.
  void _onApp() {
    final row = _app!.snapshot.byId(widget.agent);
    if (row == null || row.fingerprint == _seen) return;
    _seen = row.fingerprint;
    _conv!.fetchNew();
    if (row.status == 'blocked') _conv!.fetchScreen();
  }

  void _onScroll() {
    final p = _scroll.position;
    if (p.pixels > p.maxScrollExtent - 400) _conv!.loadOlder();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _conv!.send(text);
      _input.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _menu(String action, Agent? row) async {
    final client = _app!.client!;
    try {
      switch (action) {
        case 'refresh':
          await _conv!.fetchNew();
          await _conv!.fetchScreen();
        case 'resume':
          await client.resume(widget.agent);
          if (mounted) showError(context, 'Resuming ${widget.agent}');
        case 'kill':
          final ok = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text('Kill ${row?.name ?? widget.agent}?'),
              content: const Text('Its Claude session ends. Its conversation stays in the transcript.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Kill')),
              ],
            ),
          );
          if (ok == true) {
            await client.kill(widget.agent);
            if (mounted) showError(context, 'Killed ${widget.agent}');
          }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final row = app.snapshot.byId(widget.agent);
    final status = row?.status ?? 'unknown';
    final ended = row?.ended ?? false;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        // Tight next to a back button; beside the list there is none.
        titleSpacing: (ModalRoute.of(context)?.canPop ?? false) ? 0 : null,
        title: Row(
          children: [
            StatusGlyph(status, size: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row?.name ?? widget.agent.split('@').first, overflow: TextOverflow.ellipsis),
                  Text('@${row?.machine ?? widget.agent.split('@').last} · $status',
                      style: theme.textTheme.labelSmall, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (a) => _menu(a, row),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
              if (ended) const PopupMenuItem(value: 'resume', child: Text('Resume')),
              if (!ended) const PopupMenuItem(value: 'kill', child: Text('Kill')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _conv!,
          builder: (context, _) {
            final c = _conv!;
            final msgs = c.messages;
            return Column(
              children: [
                if (row?.stalled != null) _Banner('⚠ API error (${row!.stalled!.error})${row.stalled!.gaveUp ? '; gave up resuming' : ''}'),
                if (c.error != null) _Banner(c.error!),
                Expanded(
                  child: c.loading && msgs.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: msgs.length + 1,
                          itemBuilder: (context, k) {
                            if (k == msgs.length) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: Center(
                                  child: c.loadingOlder
                                      ? const CircularProgressIndicator()
                                      : Text(c.hasOlder ? '' : 'Start of the conversation',
                                          style: theme.textTheme.labelSmall),
                                ),
                              );
                            }
                            return MessageTile(msgs[msgs.length - 1 - k]);
                          },
                        ),
                ),
                if (status == 'blocked') DialogCard(screen: c.screen, onPick: c.answer, onRefresh: c.fetchScreen),
                _Composer(controller: _input, enabled: !ended && !_sending, onSend: _send, ended: ended),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(text, style: TextStyle(color: cs.onErrorContainer)),
    );
  }
}

/// The dialog on a blocked agent's screen, one button per option.
class DialogCard extends StatefulWidget {
  const DialogCard({super.key, required this.screen, required this.onPick, required this.onRefresh});

  final Screen? screen;
  final Future<void> Function(DialogOption) onPick;
  final Future<void> Function() onRefresh;

  @override
  State<DialogCard> createState() => _DialogCardState();
}

class _DialogCardState extends State<DialogCard> {
  bool _busy = false;

  Future<void> _pick(DialogOption o) async {
    setState(() => _busy = true);
    try {
      await widget.onPick(o);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dialog = widget.screen?.dialog;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
      child: Card(
        color: cs.errorContainer,
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.screen == null)
                const Center(child: CircularProgressIndicator())
              else if (dialog == null) ...[
                Text('Blocked, but no choice is on its screen.', style: TextStyle(color: cs.onErrorContainer)),
                TextButton(onPressed: widget.onRefresh, child: const Text('Look again')),
              ] else ...[
                Text(dialog.title, style: theme.textTheme.titleSmall?.copyWith(color: cs.onErrorContainer)),
                const SizedBox(height: 8),
                for (final o in dialog.options)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: FilledButton.tonal(
                      onPressed: _busy ? null : () => _pick(o),
                      style: FilledButton.styleFrom(alignment: Alignment.centerLeft),
                      child: Text('${o.key}. ${o.label}'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.enabled, required this.onSend, required this.ended});

  final TextEditingController controller;
  final bool enabled;
  final bool ended;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            // With a keyboard (web), Enter sends and Shift+Enter starts a new line.
            child: CallbackShortcuts(
              bindings: {
                if (kIsWeb) const SingleActivator(LogicalKeyboardKey.enter): () {
                  if (enabled) onSend();
                },
              },
              child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: ended ? 'This agent has ended' : 'Prompt',
                border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
            ),
          ),
          IconButton.filled(onPressed: enabled ? onSend : null, icon: const Icon(Icons.send), tooltip: 'Send'),
        ],
      ),
    );
  }
}
