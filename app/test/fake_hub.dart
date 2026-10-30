import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:roster/api/hub_client.dart';

/// A hub in memory: answers requests from [routes] and serves events from
/// [events], which stays open until closed.
class FakeHub {
  FakeHub(this.routes);

  /// `METHOD /path` → handler of the decoded body and query.
  final Map<String, Object Function(Map<String, dynamic> body, Map<String, String> query)> routes;
  final events = StreamController<String>.broadcast();
  final requests = <http.BaseRequest>[];
  String validToken = 'tok-1';

  HubClient client(Uri base, String? token) => HubClient(
        base,
        token: token,
        client: MockClient(_answer),
        streamClient: () => MockClient.streaming(_stream),
      );

  Future<http.Response> _answer(http.Request req) async {
    requests.add(req);
    final key = '${req.method} ${req.url.path}';
    final route = routes[key];
    if (route == null) return http.Response('{"error": "not found"}', 404);
    if (!key.endsWith('/v1/pair') && req.headers['Authorization'] != 'Bearer $validToken') {
      return http.Response('{"error": "unauthorized"}', 401);
    }
    // A raw upload: the handler gets its bytes, not JSON.
    final body = req.headers['Content-Type'] == 'application/octet-stream'
        ? <String, dynamic>{'bytes': req.bodyBytes}
        : req.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(req.body) as Map<String, dynamic>;
    final out = route(body, req.url.queryParameters);
    if (out is (int, String)) return http.Response('{"error": "${out.$2}"}', out.$1);
    return http.Response(jsonEncode(out), 200, headers: {'content-type': 'application/json'});
  }

  Future<http.StreamedResponse> _stream(http.BaseRequest req, http.ByteStream _) async {
    requests.add(req);
    if (req.headers['Authorization'] != 'Bearer $validToken') {
      return http.StreamedResponse(Stream.value(utf8.encode('{"error": "unauthorized"}')), 401);
    }
    return http.StreamedResponse(events.stream.map(utf8.encode), 200,
        headers: {'content-type': 'text/event-stream'});
  }

  void sendAgents(Map<String, dynamic> snapshot, {int id = 1}) =>
      events.add('id: $id\nevent: agents\ndata: ${jsonEncode(snapshot)}\n\n');
}
