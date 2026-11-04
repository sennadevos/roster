import 'package:flutter/material.dart';

import '../api/hub_client.dart';
import '../app.dart';
import '../models/chat.dart';
import '../state/chats.dart';
import '../widgets/message_tile.dart';

/// One chat. The whole history goes to the model every turn, so a message of
/// his can be rewritten and the chat carried on from there - that is steering,
/// not a trick. What is said here reaches an agent only when he hands it over.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chats, required this.id});

  final ChatsState chats;
  final int id;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatSession session = ChatSession(widget.chats.client, widget.id)..load();
  final composer = TextEditingController();
  final scroll = ScrollController();

  @override
  void dispose() {
    session.dispose();
    composer.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = composer.text.trim();
    if (text.isEmpty) return;
    composer.clear();
    await session.send(text);
    if (session.chat != null) widget.chats.replace(session.chat!);
    _toBottom();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
  }

  Future<void> _pickModel() async {
    final chosen = await showModelPicker(context, widget.chats, session.chat?.model ?? '');
    if (chosen == null) return;
    final updated = await session.set(model: chosen);
    if (updated != null) widget.chats.replace(updated);
  }

  /// Rewrites one of his messages and drops what came after it.
  Future<void> _edit(ChatTurn turn) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) {
        final field = TextEditingController(text: turn.text);
        return AlertDialog(
          title: const Text('Rewrite this message'),
          content: TextField(
            controller: field,
            autofocus: true,
            maxLines: 8,
            minLines: 2,
            decoration: const InputDecoration(
              helperText: 'Everything after it goes; the chat carries on from here.',
              helperMaxLines: 2,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Leave it')),
            FilledButton(onPressed: () => Navigator.of(context).pop(field.text), child: const Text('Rewrite')),
          ],
        );
      },
    );
    if (text == null || text.trim().isEmpty) return;
    await session.edit(turn.id, text);
  }

  /// Hands the chat to an agent: a new one started from it, or a running one
  /// that takes it in as its next prompt. The chat itself stays.
  Future<void> _handOver({required bool toNewAgent}) async {
    final client = AppScope.read(context).client;
    final messenger = ScaffoldMessenger.of(context);
    if (client == null) return;
    final text = await session.render();
    if (text == null || text.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(session.error ?? 'nothing to hand over yet')));
      return;
    }
    if (!mounted) return;
    if (toNewAgent) {
      await _startAgent(client, messenger, text);
      return;
    }
    final agent = await _pickAgent(context);
    if (agent == null) return;
    try {
      await client.prompt(agent, text);
      messenger.showSnackBar(SnackBar(content: Text('$agent has it')));
    } on HubException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _startAgent(HubClient client, ScaffoldMessengerState messenger, String text) async {
    messenger.showSnackBar(const SnackBar(content: Text('starting an agent from this chat…')));
    try {
      final (agent, _) = await client.newFromBrief(text);
      messenger.showSnackBar(SnackBar(content: Text('$agent is on it')));
      if (mounted) openAgent(agent);
    } on HubException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final chat = session.chat;
        final spent = session.spent;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(chat?.title ?? 'Chat', maxLines: 1, overflow: TextOverflow.ellipsis),
                if (chat != null)
                  Text(
                    spent > 0 ? '${chat.model} · ${money(spent)}' : chat.model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                  ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: 'Model',
                onPressed: chat == null ? null : _pickModel,
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => switch (v) {
                  'new-agent' => _handOver(toNewAgent: true),
                  _ => _handOver(toNewAgent: false),
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'new-agent', child: Text('Start an agent from this chat')),
                  PopupMenuItem(value: 'to-agent', child: Text('Send it to an agent…')),
                ],
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (session.error != null)
                Container(
                  width: double.infinity,
                  color: cs.errorContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(session.error!, style: TextStyle(color: cs.onErrorContainer)),
                ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                    for (final m in session.messages)
                      inColumn(m.mine
                          ? GestureDetector(
                              onLongPress: () => _edit(m),
                              onSecondaryTap: () => _edit(m),
                              child: UserBubble(m.text),
                            )
                          : _Answer(m)),
                    if (session.pending != null) ...[
                      inColumn(UserBubble(session.pending!, pending: true)),
                      const _Thinking(),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  child: inColumn(Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: composer,
                          minLines: 1,
                          maxLines: 6,
                          enabled: !session.sending,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: session.sending ? 'waiting for the answer…' : 'Say something',
                            border: const OutlineInputBorder(),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: session.sending ? null : _send,
                        icon: const Icon(Icons.arrow_upward),
                        tooltip: 'Send',
                      ),
                    ],
                  )),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What the model said, with what the answer cost where the provider said so.
class _Answer extends StatelessWidget {
  const _Answer(this.turn);

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AssistantBlock(turn.text),
        if (turn.cost != null || turn.model != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              [if (turn.model != null) turn.model!, if (turn.cost != null) money(turn.cost!)].join(' · '),
              style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
            ),
          ),
      ],
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Row(children: [
        SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: cs.outline)),
        const SizedBox(width: 10),
        Text('thinking…', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline)),
      ]),
    );
  }
}

/// Cents, the way a chat's cost is worth reading: `0.4c`, `12c`.
String money(double dollars) {
  final cents = dollars * 100;
  return cents >= 10 ? '${cents.round()}c' : '${cents.toStringAsFixed(cents >= 1 ? 1 : 2)}c';
}

/// The whole catalogue, searchable: OpenRouter's models and the Claude ones.
Future<String?> showModelPicker(BuildContext context, ChatsState chats, String current) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _ModelPicker(chats: chats, current: current),
  );
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.chats, required this.current});

  final ChatsState chats;
  final String current;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  final search = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.chats.models.isEmpty) widget.chats.loadModels();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListenableBuilder(
      listenable: widget.chats,
      builder: (context, _) {
        final want = search.text.trim().toLowerCase();
        final models = [
          for (final m in widget.chats.models)
            if (want.isEmpty || m.id.toLowerCase().contains(want) || m.name.toLowerCase().contains(want)) m,
        ];
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          builder: (context, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Search models',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              if (widget.chats.models.isEmpty)
                const Expanded(child: Center(child: CircularProgressIndicator()))
              else
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: models.length,
                    itemBuilder: (context, i) {
                      final m = models[i];
                      return ListTile(
                        dense: true,
                        selected: m.id == widget.current,
                        title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${m.id} · ${m.summary}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
                        onTap: () => Navigator.of(context).pop(m.id),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Which agent takes the chat on.
Future<String?> _pickAgent(BuildContext context) {
  final agents = AppScope.read(context).snapshot.agents;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => ListView(
      children: [
        const ListTile(title: Text('Which agent takes it on?')),
        for (final a in agents)
          ListTile(
            title: Text(a.name),
            subtitle: (a.role ?? '').isEmpty
                ? null
                : Text(a.role!, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.of(context).pop(a.name),
          ),
      ],
    ),
  );
}
