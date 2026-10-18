import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:roster/api/sse.dart';

Future<List<SseEvent>> parse(List<String> chunks) =>
    Stream<List<int>>.fromIterable(chunks.map(utf8.encode)).transform(const SseParser()).toList();

void main() {
  test('events, ids and pings as the hub sends them', () async {
    final events = await parse([
      'id: 1\nevent: agents\ndata: {"agents": [], "machines": []}\n\n',
      'id: 2\nevent: ping\ndata: {}\n\n',
    ]);
    expect(events.map((e) => (e.event, e.id, e.data)), [
      ('agents', '1', '{"agents": [], "machines": []}'),
      ('ping', '2', '{}'),
    ]);
  });

  test('chunks split anywhere, even inside a UTF-8 character', () async {
    final bytes = utf8.encode('event: agents\ndata: {"role": "▲ blocked"}\n\n');
    final chunks = [for (var k = 0; k < bytes.length; k += 3) bytes.sublist(k, (k + 3).clamp(0, bytes.length))];
    final events = await Stream<List<int>>.fromIterable(chunks).transform(const SseParser()).toList();
    expect(events.single.data, '{"role": "▲ blocked"}');
  });

  test('multi-line data, comments, CRLF, no space after the colon', () async {
    final events = await parse([': hello\r\nevent:x\r\ndata:a\r\ndata: b\r\n\r\n']);
    expect(events.single.event, 'x');
    expect(events.single.data, 'a\nb');
  });

  test('the last id carries over; no data means no event; default type', () async {
    final events = await parse(['id: 7\nevent: agents\n\n', 'data: one\n\n']);
    expect(events.single.event, 'message');
    expect(events.single.id, '7');
    expect(events.single.data, 'one');
  });
}
