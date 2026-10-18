import 'dart:async';
import 'dart:convert';

/// One Server-Sent Event.
class SseEvent {
  const SseEvent({required this.event, required this.data, this.id});

  final String event;
  final String data;
  final String? id;

  @override
  String toString() => 'SseEvent($event, id: $id, ${data.length} chars)';
}

/// Turns the bytes of a `text/event-stream` body into events, per the
/// WHATWG rules the hub needs: `event:`, `data:` (joined by newlines), `id:`,
/// comment lines starting with `:`, one optional space after the colon, and a
/// blank line to dispatch. `retry:` is ignored; the app has its own backoff.
class SseParser extends StreamTransformerBase<List<int>, SseEvent> {
  const SseParser();

  @override
  Stream<SseEvent> bind(Stream<List<int>> stream) async* {
    var event = '';
    final data = <String>[];
    String? id;
    await for (final line in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          yield SseEvent(event: event.isEmpty ? 'message' : event, data: data.join('\n'), id: id);
        }
        event = '';
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'data':
          data.add(value);
        case 'id':
          if (!value.contains('\u0000')) id = value;
      }
    }
  }
}
