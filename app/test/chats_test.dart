import 'package:flutter_test/flutter_test.dart';
import 'package:roster/models/chat.dart';
import 'package:roster/state/chats.dart';

import 'fake_hub.dart';

void main() {
  test('a chat is listed, opened, said to, and what it cost adds up', () async {
    var messages = <Map<String, dynamic>>[
      {'id': 1, 'role': 'user', 'text': 'what is a notecarrier?', 'cost': null},
    ];
    Map<String, dynamic>? said;
    final hub = FakeHub({
      // The hub hands the `chats` CLI's own JSON through, and that is a list.
      'GET /v1/chats': (_, _) => [
            {'id': 7, 'title': 'notecarrier', 'model': 'moonshotai/kimi-k3.1-pro', 'params': '{"effort":"medium"}'},
          ],
      'GET /v1/chats/7': (_, _) => {
            'id': 7,
            'title': 'notecarrier',
            'model': 'moonshotai/kimi-k3.1-pro',
            'params': '{"effort":"medium"}',
            'messages': messages,
          },
      'POST /v1/chats/7/say': (b, _) {
        said = b;
        messages = [
          ...messages,
          {'id': 2, 'role': 'assistant', 'text': 'a carrier board for a Notecard.', 'cost': 0.0032,
            'model': 'moonshotai/kimi-k3.1-pro'},
        ];
        return {'id': 7, 'text': 'a carrier board for a Notecard.', 'cost': 0.0032};
      },
      'GET /v1/models': (_, _) => [
            {'id': 'claude:sonnet', 'name': 'Claude Sonnet (your login)', 'context_length': 1000000},
            {'id': 'moonshotai/kimi-k3.1-pro', 'name': 'Kimi K3.1 Pro', 'context_length': 1048576,
              'price_in': 2.0, 'price_out': 10.0, 'supported': ['reasoning', 'temperature']},
          ],
    });
    final client = hub.client(Uri.parse('https://hub'), 'tok-1');

    final chats = ChatsState(client);
    await chats.load();
    expect(chats.chats.single.title, 'notecarrier');
    // params come back as the CLI's JSON string and are read as a map
    expect(chats.chats.single.params['effort'], 'medium');

    final session = ChatSession(client, 7);
    await session.load();
    expect(session.messages.single.mine, isTrue);

    await session.send('and the antenna?');
    expect(said!['text'], 'and the antenna?');
    expect(session.messages.last.text, 'a carrier board for a Notecard.');
    expect(session.messages.last.mine, isFalse);
    expect(session.spent, closeTo(0.0032, 1e-9));
    expect(session.sending, isFalse);
  });

  test('forking an agent sends its words and leaves the agent out of it', () async {
    Map<String, dynamic>? posted;
    final hub = FakeHub({
      'POST /v1/chats': (b, _) {
        posted = b;
        return {'id': 9, 'title': 'about kdrive-reorg', 'model': 'claude:sonnet'};
      },
    });
    final chats = ChatsState(hub.client(Uri.parse('https://hub'), 'tok-1'));
    final chat = await chats.start(fromAgent: 'kdrive-reorg', messages: const [
      ChatTurn(id: 1, role: 'user', text: 'file Lukas his brackets'),
      ChatTurn(id: 2, role: 'assistant', text: 'printing now'),
    ]);
    expect(chat!.id, 9);
    expect(posted!['from_agent'], 'kdrive-reorg');
    expect((posted!['messages'] as List).map((m) => m['role']), ['user', 'assistant']);
    // the chat is the new one at the top of the list, nothing happened to the agent
    expect(chats.chats.single.title, 'about kdrive-reorg');
  });

  test('a model reads as what it costs, and Claude as his own login', () {
    const kimi = ModelInfo(id: 'moonshotai/kimi-k3.1-pro', name: 'Kimi K3.1 Pro',
        contextLength: 1048576, priceIn: 2, priceOut: 10);
    expect(kimi.summary, '1M context · \$2.00/\$10 per Mtok');
    const sonnet = ModelInfo(id: 'claude:sonnet', name: 'Claude Sonnet', contextLength: 200000);
    expect(sonnet.isClaude, isTrue);
    expect(sonnet.summary, '200k context · your login');
  });
}
