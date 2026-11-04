import 'package:flutter/material.dart';

import '../app.dart';
import '../models/chat.dart';
import '../state/chats.dart';
import 'chat_screen.dart';

/// The chats: conversations with a model that are not agents.
///
/// An agent has a session, a machine and work in front of it. A chat has none
/// of that - the whole history is sent every turn - so this is where something
/// is thought through, including as an agent, by forking its conversation.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  ChatsState? _state;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = AppScope.of(context).client;
    if (client == null) return;
    if (_state == null) {
      _state = ChatsState(client)..load();
    } else {
      _state!.client = client;
    }
  }

  @override
  void dispose() {
    _state?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final state = _state;
    if (state == null) return;
    final chat = await state.start();
    if (chat != null && mounted) _open(chat);
  }

  void _open(Chat chat) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(chats: _state!, id: chat.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final state = _state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New chat',
            onPressed: state == null ? null : _start,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: state == null
          ? const SizedBox.expand()
          : ListenableBuilder(
              listenable: state,
              builder: (context, _) {
                if (state.error != null && state.chats.isEmpty) {
                  return _Empty(
                    icon: Icons.cloud_off,
                    title: 'Cannot reach the chats',
                    body: state.error!,
                    action: ('Try again', state.load),
                  );
                }
                if (state.chats.isEmpty) {
                  return _Empty(
                    icon: Icons.forum_outlined,
                    title: state.loading ? 'Reading the chats…' : 'No chats yet',
                    body: state.loading
                        ? ''
                        : 'A chat is a conversation with a model, with no agent behind it. '
                            'Start one here, or fork an agent into one from its own screen.',
                    action: state.loading ? null : ('New chat', _start),
                  );
                }
                return RefreshIndicator(
                  onRefresh: state.load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: state.chats.length,
                    separatorBuilder: (_, _) => Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),
                    itemBuilder: (context, i) {
                      final chat = state.chats[i];
                      return ListTile(
                        title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(chat.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete chat',
                          onPressed: () => _confirmDelete(context, state, chat),
                        ),
                        onTap: () => _open(chat),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}

Future<void> _confirmDelete(BuildContext context, ChatsState state, Chat chat) async {
  final gone = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete “${chat.title}”?'),
      content: const Text('The chat and everything said in it go. Nothing else is touched.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
      ],
    ),
  );
  if (gone == true) await state.remove(chat.id);
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: cs.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: action!.$2, child: Text(action!.$1)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Forks an agent into a chat: its conversation becomes the history, the agent
/// carries on untouched. Opens the chat when it is made.
Future<void> forkAgentIntoChat(BuildContext context, String agent, List<ChatTurn> messages) async {
  final client = AppScope.read(context).client;
  if (client == null) return;
  final state = ChatsState(client);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final chat = await state.start(fromAgent: agent, messages: messages);
  if (chat == null) {
    messenger.showSnackBar(SnackBar(content: Text(state.error ?? 'could not start the chat')));
    return;
  }
  await state.load();
  await navigator.push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chats: state, id: chat.id)));
}
