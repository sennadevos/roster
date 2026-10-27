import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../app.dart';
import '../platform/platform.dart';
import '../models/agent.dart';
import '../models/misc.dart';
import '../models/transcript.dart';
import '../state/app_state.dart';
import '../state/conversation.dart';
import '../theme.dart';
import '../voice/engines.dart';
import '../voice/voice_session.dart';
import '../widgets/bits.dart';
import '../widgets/message_tile.dart';
import '../widgets/status.dart';
import '../widgets/voice_bar.dart';



/// Ctrl+C (Cmd+C) with text selected in the conversation: copy it. Caught at
/// the keyboard, before focus: Flutter's own selection copy runs first
/// otherwise, and throws on a plain-HTTP page. A focused text field (the
/// composer) keeps its own Ctrl+C.
bool _copyKey(KeyEvent e) {
  if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.keyC) return false;
  if (!(HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed)) return false;
  final text = conversationSelection.value;
  if (text == null || text.isEmpty) return false;
  // The composer keeps its own Ctrl+C; selectable message text is read-only.
  final field = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>();
  if (field != null && !field.readOnly) return false;
  copyText(text);
  final ctx = FocusManager.instance.primaryFocus?.context ?? navigatorKey.currentContext;
  if (ctx != null) {
    ScaffoldMessenger.maybeOf(ctx)
        ?.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(milliseconds: 1200)));
  }
  return true;
}

/// Registers the Ctrl+C handler once.
void installCopyKey() {
  HardwareKeyboard.instance
    ..removeHandler(_copyKey)
    ..addHandler(_copyKey);
}

/// One agent: its conversation, its dialog when blocked, and a composer.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key, required this.agent, this.ownPage = false});

  /// `name@machine`.
  final String agent;

  /// On a page of its own (a narrow window), where Esc goes back.
  final bool ownPage;

  /// Bumped to move the keyboard into the open agent: its dialog when one is
  /// up, else its composer.
  static final focusRequest = ValueNotifier<int>(0);

  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  late Conversation _conv;
  AppState? _app;
  String? _seen;
  final _scroll = ScrollController();
  late final TextEditingController _input;
  final _inputFocus = FocusNode(debugLabel: 'composer');
  final _dialogFocus = FocusNode(debugLabel: 'dialog');

  /// The conversation is two lists that meet at this key: what was there
  /// when it was opened (and anything older) grows upwards, what arrives
  /// later grows downwards. So neither older pages nor new messages move
  /// what is on screen; the view follows new ones only when at the bottom.
  final _centerKey = GlobalKey(debugLabel: 'center');
  String? _anchor;
  bool _atBottom = true;
  int _unseen = 0;
  int _lastCount = 0;

  /// Hands-free voice chat with this agent, once the mic was tapped.
  VoiceSession? _voice;

  /// While the agent works its row does not change, so nothing else says
  /// there is more to read: look every few seconds.
  Timer? _poll;

  /// Stops the window-focus listener (web): back in the window, the keyboard
  /// goes to the composer, or to the dialog when the agent asks something.
  void Function()? _offWindowFocus;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_app != null) return;
    final app = _app = AppScope.read(context);
    _conv = app.conversation(widget.agent);
    _input = TextEditingController(text: _conv.draft);
    _input.addListener(() => _conv.draft = _input.text);
    _anchor = _conv.messages.isEmpty ? null : _conv.messages.last.key;
    _lastCount = _conv.messages.length;
    unawaited(_conv.open());
    AppState.onScreen = widget.agent;
    unawaited(app.push.clear(widget.agent).catchError((_) {}));
    final row = app.snapshot.byId(widget.agent);
    _seen = row?.fingerprint;
    if (row?.status == 'blocked') _conv.fetchScreen();
    app.addListener(_onApp);
    _conv.addListener(_onConv);
    _scroll.addListener(_onScroll);
    AgentScreen.focusRequest.addListener(_focusIn);
    _offWindowFocus = onWindowFocus(_windowFocused);
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      final status = _app!.snapshot.byId(widget.agent)?.status;
      if (status == 'working' || status == 'blocked' || _conv.messages.any((m) => m.queued)) {
        unawaited(_conv.fetchNew());
      }
    });
  }

  @override
  void dispose() {
    _app?.removeListener(_onApp);
    _conv.removeListener(_onConv);
    _voice?.dispose();
    _poll?.cancel();
    _offWindowFocus?.call();
    AgentScreen.focusRequest.removeListener(_focusIn);
    if (AppState.onScreen == widget.agent) AppState.onScreen = null;
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _dialogFocus.dispose();
    super.dispose();
  }

  void _windowFocused() {
    if (!mounted) return;
    // Only the agent on top (no sheet or dialog over it), and never away from
    // another text field the user is in, such as the search.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final focused = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>();
    if (focused != null && !focused.readOnly) return;
    _focusIn();
  }

  void _focusIn() {
    final row = _app!.snapshot.byId(widget.agent);
    if (row?.status == 'blocked' && _conv.screen?.dialog != null) {
      _dialogFocus.requestFocus();
    } else {
      _inputFocus.requestFocus();
    }
  }

  /// Every change to this agent's row (status, unread, anything) means
  /// there may be more to read, and a new dialog when it is blocked.
  void _onApp() {
    final row = _app!.snapshot.byId(widget.agent);
    if (row == null || row.fingerprint == _seen) return;
    _seen = row.fingerprint;
    _conv.fetchNew();
    if (row.status == 'blocked') _conv.fetchScreen();
  }

  void _onConv() {
    final msgs = _conv.messages;
    if (_anchor == null && msgs.isNotEmpty) {
      _anchor = msgs.last.key;
    } else if (_anchor != null && msgs.isNotEmpty && !msgs.any((m) => m.key == _anchor)) {
      // Started over (a new session): anchor on its tail.
      _anchor = msgs.last.key;
      _unseen = 0;
    }
    final added = msgs.length - _lastCount;
    _lastCount = msgs.length;
    if (added <= 0) return;
    if (_atBottom) {
      _stickToBottom();
    } else if (msgs.isNotEmpty && _anchor != null) {
      // Only what came in at the bottom counts as unseen, not older pages.
      final anchorAt = msgs.indexWhere((m) => m.key == _anchor);
      final below = msgs.length - 1 - anchorAt;
      if (below > 0) setState(() => _unseen = (_unseen + added).clamp(0, below));
    }
  }

  void _stickToBottom([int tries = 3]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels < p.maxScrollExtent) p.jumpTo(p.maxScrollExtent);
      if (tries > 1) _stickToBottom(tries - 1);
    });
  }

  void _onScroll() {
    final p = _scroll.position;
    final bottom = p.pixels >= p.maxScrollExtent - 48;
    if (bottom != _atBottom) {
      setState(() {
        _atBottom = bottom;
        if (bottom) _unseen = 0;
      });
    }
    // Load more before the top is reached, so it is there when it is.
    if (p.pixels < p.minScrollExtent + 1200 && p.userScrollDirection != ScrollDirection.reverse) {
      _conv.loadOlder();
    }
  }

  Future<void> _jumpToLatest() async {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final far = p.maxScrollExtent - p.pixels > 3000;
    if (far) p.jumpTo(p.maxScrollExtent - 600);
    await p.animateTo(p.maxScrollExtent, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    _stickToBottom(2);
  }

  Future<void> _toggleVoice() async {
    final engines = voiceEngines;
    if (engines == null) return;
    var v = _voice;
    if (v == null) {
      final (input, output) = engines();
      v = _voice = VoiceSession(
        conversation: _conv,
        row: () => _app!.snapshot.byId(widget.agent),
        changes: _app!,
        input: input,
        output: output,
      )..addListener(() {
          if (mounted) setState(() {});
        });
      setState(() {});
    }
    if (v.active) {
      await v.stop();
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
      await v.start();
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // Shown at once (pending); the field is free for the next one.
    _input.clear();
    _atBottom = true;
    _stickToBottom();
    try {
      await _conv.send(text);
    } catch (e) {
      if (!mounted) return;
      if (_input.text.isEmpty) _input.text = text;
      showError(context, e);
    }
  }

  Future<void> _menu(String action, Agent? row) async {
    final client = _app!.client!;
    try {
      // SDK agents: model:<name> and effort:<level> switch live; model:? asks for a name.
      if (action.startsWith('model:') || action.startsWith('effort:')) {
        final (what, value) = (action.split(':').first, action.substring(action.indexOf(':') + 1));
        final v = value == '?' ? await _askModel(row?.model) : value;
        if (v == null || v.isEmpty) return;
        if (what == 'model') {
          await client.setModel(widget.agent, v);
        } else {
          await client.setEffort(widget.agent, v);
        }
        if (mounted) showError(context, '${what == 'model' ? 'Model' : 'Effort'}: $v');
        return;
      }
      switch (action) {
        case 'interrupt':
          final did = await client.interrupt(widget.agent);
          if (mounted) showError(context, did ? 'Interrupted' : 'Nothing to interrupt');
        case 'refresh':
          await _conv.fetchNew();
          await _conv.fetchScreen();
        case 'copy':
          await copyText(widget.agent);
          if (mounted) showError(context, 'Copied ${widget.agent}');
        case 'resume':
          await client.resume(widget.agent);
          if (mounted) showError(context, 'Resuming ${row?.name ?? widget.agent}…');
        case 'kill':
          final ok = await confirmKill(context, row?.name ?? widget.agent, parked: row?.parked ?? false);
          if (ok) {
            await client.kill(widget.agent);
            if (mounted) showError(context, 'Killed ${row?.name ?? widget.agent}');
          }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Any model name, for the one not in the list (a full model id, say).
  Future<String?> _askModel(String? current) {
    final field = TextEditingController(text: current ?? '');
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Model'),
        content: TextField(
          controller: field,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'an alias (opus) or a full model name'),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, field.text.trim()), child: const Text('Switch')),
        ],
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape && widget.ownPage) {
      if (_inputFocus.hasFocus || _dialogFocus.hasFocus) {
        FocusManager.instance.primaryFocus?.unfocus();
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final row = app.snapshot.byId(widget.agent);
    final status = row?.status ?? 'unknown';
    final ended = row?.ended ?? false;
    final blocked = status == 'blocked';
    final stale = row?.stale != null;
    final ownPage = ModalRoute.of(context)?.canPop ?? false;
    return Focus(
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: _Header(
          agent: widget.agent,
          row: row,
          backButton: ownPage,
          listHidden: _app!.listHidden,
          onToggleList: ownPage ? null : () => _app!.setListHidden(!_app!.listHidden),
          onMenu: (a) => _menu(a, row),
        ),
        body: SafeArea(
          top: false,
          child: ListenableBuilder(
            listenable: _conv,
            builder: (context, _) {
              final c = _conv;
              return Column(
                children: [
                  if (row?.stalled != null && !ended) _StalledBanner(row!.stalled!),
                  if (stale) _InfoBanner(icon: Icons.cloud_off_outlined, text: '@${row!.machine} is unreachable (${row.stale}). This is its last known state.'),
                  if (c.error != null)
                    _InfoBanner(
                      icon: Icons.error_outline,
                      text: friendlyError(c.error!),
                      action: 'Retry',
                      onAction: c.messages.isEmpty ? c.loadTail : c.fetchNew,
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: _conversation(c, status)),
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: AnimatedScale(
                            scale: _atBottom ? 0 : 1,
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOut,
                            child: _JumpButton(unseen: _unseen, onPressed: _jumpToLatest),
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
                    child: blocked && !stale
                        ? inColumn(DialogCard(
                            screen: c.screen,
                            answered: c.answered,
                            focusNode: _dialogFocus,
                            onPick: c.answer,
                            onAnswerText: c.answerText,
                            onRefresh: c.fetchScreen,
                          ))
                        : const SizedBox(width: double.infinity),
                  ),
                  if (_voice != null) VoiceBar(_voice!),
                  _Composer(
                    controller: _input,
                    focusNode: _inputFocus,
                    agentName: row?.name ?? widget.agent.split('@').first,
                    parked: row?.parked ?? false,
                    disabledReason: ended
                        ? 'This agent has ended.'
                        : stale
                            ? '@${row!.machine} is unreachable.'
                            : blocked
                                ? 'Answer the question above first.'
                                : null,
                    onResume: ended ? () => _menu('resume', row) : null,
                    onSend: _send,
                    onVoice: voiceEngines != null && !ended && !stale ? _toggleVoice : null,
                    voiceOn: _voice?.active ?? false,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _conversation(Conversation c, String status) {
    final msgs = c.messages;
    if (c.loading && msgs.isEmpty) return inColumn(const _ConversationSkeleton());
    if (msgs.isEmpty && c.pending.isEmpty) {
      return Center(
        child: Text(c.error == null ? 'No messages yet' : '',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.outline)),
      );
    }
    final items = _items(msgs);
    var boundary = items.length;
    if (_anchor != null) {
      final k = items.indexWhere((it) => it.keys.contains(_anchor));
      if (k >= 0) boundary = k + 1;
    }
    final older = items.sublist(0, boundary).reversed.toList();
    final newer = items.sublist(boundary);
    final working = status == 'working';
    final theme = Theme.of(context);
    return CustomScrollView(
        controller: _scroll,
        center: _centerKey,
        anchor: 1.0,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.only(top: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, k) {
                  if (k == older.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: c.loadingOlder || c.hasOlder
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : Text('Start of the conversation',
                                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
                      ),
                    );
                  }
                  return older[k].build();
                },
                childCount: older.length + 1,
                findChildIndexCallback: (key) {
                  final k = older.indexWhere((it) => it.key == key);
                  return k < 0 ? null : k;
                },
              ),
            ),
          ),
          SliverList(
            key: _centerKey,
            delegate: SliverChildBuilderDelegate(
              (context, k) => newer[k].build(),
              childCount: newer.length,
              findChildIndexCallback: (key) {
                final k = newer.indexWhere((it) => it.key == key);
                return k < 0 ? null : k;
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in c.pending) inColumn(UserBubble(p, key: ValueKey('pending/$p'), pending: true)),
                inColumn(AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: working ? const _WorkingLine() : const SizedBox(height: 12),
                )),
              ],
            ),
          ),
        ],
    );
  }

  /// Messages as what is drawn: a time label when far apart, and runs of
  /// tool calls as one group.
  List<_Item> _items(List<Message> msgs) {
    final out = <_Item>[];
    DateTime? last;
    for (var k = 0; k < msgs.length; k++) {
      final m = msgs[k];
      final at = m.at;
      if (at != null && (last == null || at.difference(last).inMinutes >= 20)) {
        out.add(_Item('t/${m.key}', [m.key], () => TimeSeparator(at, key: ValueKey('t/${m.key}'))));
      }
      if (at != null) last = at;
      if (m.role == 'tool') {
        final run = <Message>[m];
        while (k + 1 < msgs.length && msgs[k + 1].role == 'tool') {
          run.add(msgs[++k]);
          if (run.last.at != null) last = run.last.at;
        }
        final key = 'g/${run.first.key}';
        out.add(_Item(key, [for (final r in run) r.key], () => ToolGroup(run, key: ValueKey(key))));
      } else if (m.role == 'user') {
        out.add(_Item(m.key, [m.key],
            () => StayPut(child: UserBubble(m.text, key: ValueKey(m.key), queued: m.queued, withdrawn: m.withdrawn))));
      } else if (m.role == 'event') {
        out.add(_Item(m.key, [m.key], () => StayPut(child: EventLine(m.text, key: ValueKey(m.key)))));
      } else {
        out.add(_Item(m.key, [m.key], () => StayPut(child: AssistantBlock(m.text, key: ValueKey(m.key)))));
      }
    }
    return out;
  }
}

class _Item {
  _Item(String key, this.keys, this._build) : key = ValueKey(key);

  final ValueKey<String> key;

  /// The messages it shows.
  final List<String> keys;
  final Widget Function() _build;

  Widget build() => KeyedSubtree(key: key, child: inColumn(_build()));
}

class _WorkingLine extends StatelessWidget {
  const _WorkingLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 16, 14),
      child: Row(children: [
        const StatusDot('working', size: 8),
        const SizedBox(width: 8),
        Text('Working…', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      ]),
    );
  }
}

class _JumpButton extends StatelessWidget {
  const _JumpButton({required this.unseen, required this.onPressed});

  final int unseen;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      elevation: 3,
      shadowColor: Colors.black38,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: unseen > 0 ? 14 : 10, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_downward, size: 18, color: cs.onSurface),
            if (unseen > 0) ...[
              const SizedBox(width: 6),
              Text('$unseen new', style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Name, status and how long, role; then machine, model, folder and the
/// subagents it runs.
/// A tag in the header strip that opens a menu of choices; the current one ticked.
class _Picker extends StatelessWidget {
  const _Picker(
      {required this.label, required this.icon, required this.tooltip, required this.current, required this.choices,
      required this.onPick, this.other});

  final String label;
  final IconData icon;
  final String tooltip;
  final String? current;
  final List<String> choices;
  final void Function(String) onPick;

  /// A last entry that asks for a value of its own (picked as `?`).
  final String? other;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      onSelected: onPick,
      itemBuilder: (_) => [
        for (final c in choices)
          CheckedPopupMenuItem(value: c, checked: c == current, child: Text(c)),
        if (other != null) PopupMenuItem(value: '?', child: Text(other!)),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Tag(label, icon: icon),
        const Icon(Icons.arrow_drop_down, size: 16),
      ]),
    );
  }
}

class _Header extends StatelessWidget implements PreferredSizeWidget {
  const _Header(
      {required this.agent,
      required this.row,
      required this.backButton,
      required this.onMenu,
      this.listHidden = false,
      this.onToggleList});

  /// Beside the list (a wide window): fold the list away or bring it back.
  final VoidCallback? onToggleList;
  final bool listHidden;

  final String agent;
  final Agent? row;
  final bool backButton;
  final void Function(String) onMenu;

  bool get _hasStrip => row != null;

  @override
  Size get preferredSize => Size.fromHeight(65 + (_hasStrip ? 38 : 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sc = statusColors(context);
    final r = row;
    final status = r?.status ?? 'unknown';
    final name = r?.name ?? agent.split('@').first;
    final prefix = name.contains('/') ? name.substring(0, name.lastIndexOf('/') + 1) : '';
    final leaf = name.split('/').last;
    final color = sc.of(status);
    final ended = r?.ended ?? false;
    // An SDK agent that runs (or is parked: switching resumes it) takes model,
    // effort and interrupt from here.
    final live = (r?.sdk ?? false) && !ended && r?.stale == null;
    final subs = ended ? const <Subagent>[] : (r?.subagents ?? const <Subagent>[]);
    return Material(
      color: cs.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  if (backButton)
                    const BackButton()
                  else if (onToggleList != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, right: 2),
                      child: IconButton(
                        onPressed: onToggleList,
                        icon: Icon(listHidden ? Icons.menu_rounded : Icons.menu_open_rounded),
                        tooltip: listHidden ? 'Show the agent list (Ctrl+B)' : 'Hide the agent list (Ctrl+B)',
                      ),
                    )
                  else
                    const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text.rich(
                              TextSpan(children: [
                                TextSpan(text: prefix, style: TextStyle(color: cs.outline, fontWeight: FontWeight.w400)),
                                TextSpan(text: leaf),
                              ]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(fontSize: 17),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _StatusPill(status: status, color: color, since: r?.statusAt),
                        ]),
                        if (r?.role != null && r!.role!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(r.role!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                          ),
                      ],
                    ),
                  ),
                  if (kIsWeb)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh',
                      onPressed: () => onMenu('refresh'),
                    ),
                  if (live && (status == 'working' || status == 'blocked'))
                    IconButton(
                      icon: const Icon(Icons.stop_circle_outlined),
                      tooltip: 'Interrupt',
                      onPressed: () => onMenu('interrupt'),
                    ),
                  if (ended)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: FilledButton.tonalIcon(
                        onPressed: () => onMenu('resume'),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('Resume'),
                      ),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: onMenu,
                    itemBuilder: (_) => [
                      if (!kIsWeb) const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                      const PopupMenuItem(value: 'copy', child: Text('Copy name@machine')),
                      if (live) const PopupMenuItem(value: 'interrupt', child: Text('Interrupt')),
                      if (live) const PopupMenuItem(value: 'model:?', child: Text('Switch model…')),
                      if (ended) const PopupMenuItem(value: 'resume', child: Text('Resume')),
                      if (!ended) const PopupMenuItem(value: 'kill', child: Text('Kill…')),
                    ],
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            if (_hasStrip)
              SizedBox(
                height: 38,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 4, 16, 10),
                  children: [
                    for (final t in [
                      Tag('@${r!.machine}', icon: Icons.dns_outlined, tooltip: r.local ? 'On the hub machine' : 'On ${r.machine}'),
                      if (live) ...[
                        _Picker(
                          label: r.model ?? 'model',
                          icon: Icons.memory,
                          tooltip: 'Model: tap to switch',
                          current: r.model,
                          choices: const ['opus', 'sonnet', 'haiku', 'fable'],
                          other: 'Other…',
                          onPick: (v) => onMenu('model:$v'),
                        ),
                        _Picker(
                          label: r.effort == null ? 'effort' : 'effort ${r.effort}',
                          icon: Icons.speed,
                          tooltip: 'Effort: tap to switch',
                          current: r.effort,
                          choices: const ['low', 'medium', 'high', 'xhigh', 'max'],
                          onPick: (v) => onMenu('effort:$v'),
                        ),
                      ] else if (r.model != null || r.effort != null)
                        Tag([?r.model, ?r.effort].join(' · '), icon: Icons.memory, tooltip: 'Model and effort'),
                      if (r.cwd != null) Tag(_shortPath(r.cwd!), icon: Icons.folder_outlined, tooltip: r.cwd),
                      if (r.temp) const Tag('quick', icon: Icons.bolt),
                    ])
                      Padding(padding: const EdgeInsets.only(right: 6), child: t),
                    for (final s in subs)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Tooltip(
                          message: '${s.type} subagent, ${s.running ? 'running' : 'done'}\n${s.label}',
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              border: Border.all(color: cs.outlineVariant),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              s.running
                                  ? const RunningSpinner(size: 9)
                                  : Icon(Icons.check, size: 12, color: sc.done),
                              const SizedBox(width: 5),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 220),
                                child: Text('${s.type}: ${s.label}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, height: 1.35)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }
}

String _shortPath(String p) {
  final home = RegExp(r'^/(?:var/)?home/[^/]+');
  return p.replaceFirst(home, '~');
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.color, this.since});

  final String status;
  final Color color;
  final DateTime? since;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color, height: 1.3);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        StatusDot(status, size: 8),
        Text(statusWord(status), style: style),
        if (since != null) Ago(since!, prefix: ' · ', style: style.copyWith(fontWeight: FontWeight.w400)),
      ]),
    );
  }
}

class _StalledBanner extends StatelessWidget {
  const _StalledBanner(this.stalled);

  final Stalled stalled;

  @override
  Widget build(BuildContext context) {
    final text = stalled.gaveUp
        ? 'API error (${stalled.error}); roster gave up resuming. Fix the cause, then send a prompt to go on.'
        : stalled.transient
            ? 'API error (${stalled.error}); it resumes by itself when the API answers.'
            : 'API error (${stalled.error}); this needs you${stalled.message == null ? '' : ': ${stalled.message}'}.';
    return _InfoBanner(icon: Icons.warning_amber_rounded, text: text, strong: !stalled.transient);
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.icon, required this.text, this.strong = false, this.action, this.onAction});

  final IconData icon;
  final String text;
  final bool strong;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = strong ? statusColors(context).blocked : cs.onSurfaceVariant;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: EdgeInsets.fromLTRB(12, 8, action == null ? 12 : 4, 8),
      decoration: BoxDecoration(
        color: strong ? c.withValues(alpha: 0.10) : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: strong ? c : cs.onSurface))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

class _ConversationSkeleton extends StatelessWidget {
  const _ConversationSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Align(alignment: Alignment.centerRight, child: Bar(width: 260, height: 34)),
            SizedBox(height: 18),
            Bar(width: 420, height: 10),
            SizedBox(height: 8),
            Bar(width: 360, height: 10),
            SizedBox(height: 8),
            Bar(width: 200, height: 10),
            SizedBox(height: 18),
            Bar(width: 240, height: 8),
            SizedBox(height: 8),
            Bar(width: 280, height: 8),
            SizedBox(height: 18),
            Align(alignment: Alignment.centerRight, child: Bar(width: 180, height: 34)),
            SizedBox(height: 18),
            Bar(width: 380, height: 10),
            SizedBox(height: 8),
            Bar(width: 300, height: 10),
          ],
        ),
      ),
    );
  }
}

/// The dialog on a blocked agent's screen: its question, one row per option
/// (a tick box when it takes several), the form's steps, Back and Next.
/// With focus, the number keys pick and the arrows move between steps.
class DialogCard extends StatefulWidget {
  const DialogCard({
    super.key,
    required this.screen,
    required this.onPick,
    required this.onRefresh,
    this.onAnswerText,
    this.answered = false,
    this.focusNode,
  });

  final Screen? screen;
  final bool answered;
  final FocusNode? focusNode;
  final Future<void> Function(DialogOption) onPick;
  final Future<void> Function(DialogOption, String)? onAnswerText;
  final Future<void> Function() onRefresh;

  @override
  State<DialogCard> createState() => _DialogCardState();
}

class _DialogCardState extends State<DialogCard> {
  /// The option being sent.
  DialogOption? _busy;

  /// Tick boxes flipped here and not yet shown back by the screen.
  final Map<String, bool> _ticked = {};

  /// The own-answer field.
  final TextEditingController _own = TextEditingController();
  final FocusNode _ownFocus = FocusNode();
  String? _ownFor;

  @override
  void dispose() {
    _own.dispose();
    _ownFocus.dispose();
    super.dispose();
  }

  Future<void> _sendOwn(DialogOption o) async {
    final text = _own.text.trim();
    if (text.isEmpty || _busy != null || widget.onAnswerText == null) return;
    setState(() => _busy = o);
    try {
      await widget.onAnswerText!(o, text);
      _own.clear();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  void didUpdateWidget(DialogCard old) {
    super.didUpdateWidget(old);
    if (!identical(old.screen, widget.screen)) _ticked.clear();
  }

  Future<void> _pick(DialogOption o) async {
    if (_busy != null) return;
    setState(() {
      _busy = o;
      if (o.checked != null) _ticked[o.key] = !(_ticked[o.key] ?? o.checked!);
    });
    try {
      await widget.onPick(o);
    } catch (e) {
      if (mounted) {
        setState(() => _ticked.remove(o.key));
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final dialog = widget.screen?.dialog;
    if (dialog == null) return KeyEventResult.ignored;
    final ch = e.character;
    for (final o in dialog.options) {
      if (ch != null && ch == o.key) {
        if (o.input) {
          _ownFocus.requestFocus();
        } else {
          _pick(o);
        }
        return KeyEventResult.handled;
      }
    }
    final arrow = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowLeft => 'Left',
      LogicalKeyboardKey.arrowRight => 'Right',
      _ => null,
    };
    if (arrow != null) {
      for (final a in dialog.actions) {
        if (a.keys.contains(arrow)) {
          _pick(a);
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sc = statusColors(context);
    final dialog = widget.screen?.dialog;
    final accent = sc.blocked;
    Widget content;
    if (widget.answered) {
      content = Row(children: [
        Icon(Icons.check_circle_outline, size: 18, color: sc.done),
        const SizedBox(width: 10),
        Expanded(child: Text('Answer sent. Waiting for the agent…', style: theme.textTheme.bodyMedium)),
        const RunningSpinner(size: 14),
      ]);
    } else if (widget.screen == null) {
      content = const Skeleton(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Bar(width: 260, height: 12),
          SizedBox(height: 14),
          Bar(width: double.infinity, height: 36),
          SizedBox(height: 6),
          Bar(width: double.infinity, height: 36),
        ]),
      );
    } else if (dialog == null) {
      content = Row(children: [
        Icon(Icons.help_outline, size: 18, color: accent),
        const SizedBox(width: 10),
        Expanded(child: Text('Blocked, but no choice is on its screen yet.', style: theme.textTheme.bodyMedium)),
        TextButton(onPressed: widget.onRefresh, child: const Text('Look again')),
      ]);
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dialog.tabs.isNotEmpty) ...[
            _Steps(dialog.tabs),
            const SizedBox(height: 10),
          ],
          Text(dialog.title, style: theme.textTheme.titleSmall?.copyWith(fontSize: 15)),
          if (dialog.multi)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('Tick one or more, then Next.', style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            ),
          const SizedBox(height: 8),
          for (final o in dialog.options)
            if (o.input && widget.onAnswerText != null)
              _ownAnswer(context, o)
            else
              _OptionRow(
                option: o,
                checked: o.checked == null ? null : (_ticked[o.key] ?? o.checked!),
                busy: identical(_busy, o),
                enabled: _busy == null,
                onTap: () => _pick(o),
              ),
          if (dialog.actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              if (kIsWeb)
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.focusNode ?? Listenable.merge(const []),
                    builder: (context, _) => (widget.focusNode?.hasFocus ?? false)
                        ? const Align(
                            alignment: Alignment.centerLeft,
                            child: ShortcutHints([(['1', '…'], 'pick'), (['←', '→'], 'steps')]),
                          )
                        : const SizedBox(),
                  ),
                )
              else
                const Spacer(),
              for (final a in dialog.actions)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: a.label.toLowerCase() == 'back'
                      ? OutlinedButton(onPressed: _busy != null ? null : () => _pick(a), child: Text(a.label))
                      : FilledButton(onPressed: _busy != null ? null : () => _pick(a), child: Text(a.label)),
                ),
            ]),
          ],
        ],
      );
    }
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: widget.focusNode ?? Listenable.merge(const []),
        builder: (context, child) {
          final focused = widget.focusNode?.hasFocus ?? false;
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: focused ? 0.9 : 0.45), width: focused ? 2 : 1.2),
                boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, 4))],
              ),
              child: child,
            ),
          );
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Icon(Icons.priority_high_rounded, size: 15, color: accent),
                const SizedBox(width: 6),
                Text('Needs your answer',
                    style: theme.textTheme.labelMedium?.copyWith(color: accent, fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 8),
              AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: KeyedSubtree(
                key: ValueKey('${widget.answered}/${dialog?.title}/${dialog?.tabs.where((t) => t.done).length}'),
                child: content,
              )),
            ],
          ),
        ),
      ),
    );
  }
}

extension on _DialogCardState {
  /// Claude's "Type something" option as a text field with a send button.
  Widget _ownAnswer(BuildContext context, DialogOption o) {
    final theme = Theme.of(context);
    if (_ownFor != '${o.key}/${o.text}') {
      _ownFor = '${o.key}/${o.text}';
      _own.text = o.text;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 22,
          alignment: Alignment.center,
          child: Text(o.key, style: theme.textTheme.labelMedium),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _own,
            focusNode: _ownFocus,
            enabled: _busy == null,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendOwn(o),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Type your own answer',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(width: 6),
        identical(_busy, o)
            ? const Padding(padding: EdgeInsets.all(12), child: RunningSpinner(size: 16))
            : IconButton.filledTonal(
                tooltip: 'Send this answer',
                onPressed: _busy == null ? () => _sendOwn(o) : null,
                icon: const Icon(Icons.send_rounded, size: 18),
              ),
      ]),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps(this.tabs);

  final List<DialogTab> tabs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sc = statusColors(context);
    final current = tabs.indexWhere((t) => !t.done);
    return Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (var k = 0; k < tabs.length; k++) ...[
        if (k > 0) Icon(Icons.chevron_right, size: 16, color: cs.outlineVariant),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: k == current ? cs.primary.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(tabs[k].done ? Icons.check_circle : Icons.circle_outlined,
                size: 13, color: tabs[k].done ? sc.done : (k == current ? cs.primary : cs.outline)),
            const SizedBox(width: 5),
            Text(tabs[k].label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: k == current ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: k == current ? FontWeight.w700 : FontWeight.w500,
                )),
          ]),
        ),
      ],
    ]);
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.option, required this.checked, required this.busy, required this.enabled, required this.onTap});

  final DialogOption option;
  final bool? checked;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: checked == true ? cs.primary.withValues(alpha: 0.10) : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
            child: Row(
              children: [
                Keycap(option.key),
                const SizedBox(width: 10),
                if (checked != null) ...[
                  Icon(checked! ? Icons.check_box : Icons.check_box_outline_blank,
                      size: 20, color: checked! ? cs.primary : cs.outline),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(option.label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                      if (option.detail.isNotEmpty)
                        Text(option.detail, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (busy) const RunningSpinner(size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A text box that grows to six lines. Enter sends and Shift+Enter starts a
/// new line (with a keyboard); when the agent cannot take a prompt, it says
/// why.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.agentName,
    required this.onSend,
    this.disabledReason,
    this.parked = false,
    this.onResume,
    this.onVoice,
    this.voiceOn = false,
  });

  /// Starts or stops hands-free voice chat; null where there is no speech engine.
  final VoidCallback? onVoice;
  final bool voiceOn;

  final TextEditingController controller;
  final FocusNode focusNode;
  final String agentName;
  final VoidCallback onSend;
  final String? disabledReason;

  /// A parked agent: sending resumes it first, which takes a few seconds.
  final bool parked;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final enabled = disabledReason == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: conversationWidth - 24),
          child: ListenableBuilder(
            listenable: Listenable.merge([controller, focusNode]),
            builder: (context, _) {
              final canSend = enabled && controller.text.trim().isNotEmpty;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color: enabled ? cs.surfaceContainerLow : cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: focusNode.hasFocus ? cs.primary : cs.outlineVariant,
                    width: focusNode.hasFocus ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          if (kIsWeb)
                            const SingleActivator(LogicalKeyboardKey.enter): () {
                              if (canSend) onSend();
                            },
                        },
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 6,
                          textCapitalization: TextCapitalization.sentences,
                          style: theme.textTheme.bodyMedium,
                          decoration: InputDecoration(
                            hintText: disabledReason ??
                                (parked
                                    ? 'Parked: sending resumes $agentName'
                                    : kIsWeb && MediaQuery.sizeOf(context).width >= 600
                                        ? 'Message $agentName  ·  Shift+Enter for a new line'
                                        : 'Message $agentName'),
                            hintMaxLines: 1,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.fromLTRB(18, 13, 8, 13),
                          ),
                        ),
                      ),
                    ),
                    if (onVoice != null && onResume == null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 5, 0, 5),
                        child: IconButton(
                          onPressed: onVoice,
                          isSelected: voiceOn,
                          icon: const Icon(Icons.mic_none_rounded),
                          selectedIcon: Icon(Icons.mic_rounded, color: cs.primary),
                          tooltip: voiceOn ? 'Stop voice chat' : 'Voice chat',
                        ),
                      ),
                    if (onResume != null)
                      Padding(
                        padding: const EdgeInsets.all(5),
                        child: FilledButton.tonal(onPressed: onResume, child: const Text('Resume')),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.all(5),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: canSend ? 1 : 0.4,
                          child: IconButton.filled(
                            onPressed: canSend ? onSend : null,
                            icon: const Icon(Icons.arrow_upward_rounded),
                            tooltip: 'Send',
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
