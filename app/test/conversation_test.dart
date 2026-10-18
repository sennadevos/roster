import 'package:flutter_test/flutter_test.dart';
import 'package:roster/state/conversation.dart';

import 'fake_hub.dart';

/// A transcript of messages on every other line, i = 2, 4, … 2n.
List<Map<String, dynamic>> lines(int n, {bool lastToolDone = true}) => [
      for (var k = 1; k <= n; k++)
        {'i': 2 * k, 'role': k == n ? 'tool' : 'assistant', 'text': 'm$k', 'tool': k == n ? 'Bash' : null,
          'result': k == n && lastToolDone ? 'ok' : null},
    ];

void main() {
  test('tail, then new messages, then older ones through the after window', () async {
    var transcript = lines(30, lastToolDone: false);
    final hub = FakeHub({
      'GET /v1/transcript': (_, q) {
        final limit = int.parse(q['limit'] ?? '200');
        final after = q['after'] == null ? null : int.parse(q['after']!);
        final rows = after == null
            ? transcript.sublist((transcript.length - limit).clamp(0, transcript.length))
            : transcript.where((m) => (m['i'] as int) > after).take(limit).toList();
        return {'agent': 'a@m', 'session_id': 's', 'messages': rows,
          'next': rows.isEmpty ? (after ?? 0) + 1 : (rows.last['i'] as int) + 1};
      },
    });
    final c = Conversation(hub.client(Uri.parse('https://hub'), 'tok-1'), 'a@m', pageSize: 10);

    await c.loadTail();
    expect(c.messages.map((m) => m.text), [for (var k = 21; k <= 30; k++) 'm$k']);
    expect(c.messages.last.result, isNull);
    expect(c.hasOlder, isTrue);

    // The tool finishes and two more messages arrive: the result is folded
    // into the earlier line, so the fetch goes back to it.
    transcript = lines(32);
    transcript[29] = {...transcript[29], 'role': 'tool', 'tool': 'Bash', 'result': 'done'};
    await c.fetchNew();
    expect(c.messages.map((m) => m.text).skip(8), ['m29', 'm30', 'm31', 'm32']);
    expect(c.messages.firstWhere((m) => m.text == 'm30').result, 'done');

    await c.loadOlder();
    expect(c.messages.first.text, 'm7');
    expect(c.messages.map((m) => m.i).toList(), [for (var k = 7; k <= 32; k++) 2 * k]);
    await c.loadOlder();
    expect(c.messages.first.text, 'm1');
    expect(c.hasOlder, isFalse);
  });
}
