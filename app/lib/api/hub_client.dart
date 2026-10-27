import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../models/agent.dart';
import '../models/misc.dart';
import '../models/transcript.dart';
import 'sse.dart';

/// An error answer from the hub (`{"error": "…"}` with 4xx/5xx), or a
/// transport failure (status 0).
class HubException implements Exception {
  const HubException(this.status, this.message);

  final int status;
  final String message;

  bool get unauthorized => status == 401;

  @override
  String toString() => status == 0 ? message : '$message ($status)';
}

const defaultHubUrl = 'https://roster.sennadevos.com';

/// `https://` when no scheme is given, and no trailing slash.
Uri normalizeHubUrl(String raw) {
  var s = raw.trim();
  if (!s.contains('://')) s = 'https://$s';
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return Uri.parse(s);
}

/// The hub that served the web app at [page] (`Uri.base`): the page's
/// directory, query and fragment dropped, which is its origin when the app
/// is served at `/`.
Uri hubUrlForPage(Uri page) => normalizeHubUrl(page.resolve('.').toString());

/// The roster-hub API, section 2 of docs/hub-api.md.
class HubClient {
  HubClient(this.base, {this.token, http.Client? client, http.Client Function()? streamClient})
      : _client = client ?? http.Client(),
        _streamClient = streamClient ?? http.Client.new;

  final Uri base;
  final String? token;
  final http.Client _client;
  final http.Client Function() _streamClient;

  static const _timeout = Duration(seconds: 30);

  HubClient withToken(String token) =>
      HubClient(base, token: token, client: _client, streamClient: _streamClient);

  Uri _uri(String path, [Map<String, String>? query]) => base.replace(
        path: '${base.path}$path',
        queryParameters: query == null || query.isEmpty ? null : query,
      );

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// [timeout] for requests the hub itself gives longer (new, resume).
  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, String>? query, Object? body, Duration timeout = _timeout}) async {
    final req = http.Request(method, _uri(path, query))..headers.addAll(_headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } on TimeoutException {
      throw const HubException(0, 'the hub did not answer in time');
    } on http.ClientException catch (e) {
      throw HubException(0, 'cannot reach the hub: ${e.message}');
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      json = null;
    }
    if (res.statusCode >= 400) {
      final msg = json is Map && json['error'] != null ? '${json['error']}' : 'HTTP ${res.statusCode}';
      throw HubException(res.statusCode, msg);
    }
    if (json is! Map<String, dynamic>) {
      throw HubException(res.statusCode, 'the hub sent something that is not JSON');
    }
    return json;
  }

  Future<Map<String, dynamic>> version() => _send('GET', '/v1/version');

  /// Trades a one-time code for a device token: `(token, deviceId)`.
  Future<(String, String)> pair(String code, String deviceName) async {
    final json = await _send('POST', '/v1/pair', body: {'code': code, 'device_name': deviceName});
    final token = json['token'];
    if (token is! String || token.isEmpty) throw const HubException(0, 'the hub sent no token');
    return (token, '${json['device_id'] ?? ''}');
  }

  Future<AgentsSnapshot> agents({bool all = false}) async =>
      AgentsSnapshot.fromJson(await _send('GET', '/v1/agents', query: all ? {'all': '1'} : null));

  Future<TranscriptPage> transcript(String agent, {int? after, int? before, int? limit}) async =>
      TranscriptPage.fromJson(await _send('GET', '/v1/transcript', query: {
        'agent': agent,
        if (after != null) 'after': '$after',
        if (before != null) 'before': '$before',
        if (limit != null) 'limit': '$limit',
      }));

  Future<Screen> screen(String agent) async =>
      Screen.fromJson(await _send('GET', '/v1/screen', query: {'agent': agent}));

  /// A prompt; [images] (name, bytes) go along and are kept on the agent's
  /// machine, the prompt naming their paths.
  Future<void> prompt(String agent, String text, {List<(String, Uint8List)> images = const []}) => _send(
        'POST',
        '/v1/prompt',
        body: {
          'agent': agent,
          'text': text,
          if (images.isNotEmpty) 'images': [for (final (name, bytes) in images) {'name': name, 'data': base64Encode(bytes)}],
        },
        timeout: images.isEmpty ? _timeout : const Duration(seconds: 90),
      );

  Future<void> keys(String agent, List<String> keys) =>
      _send('POST', '/v1/keys', body: {'agent': agent, 'keys': keys});

  /// Types an own answer into the dialog's free-text option and submits it.
  Future<void> answer(String agent, String key, String text) =>
      _send('POST', '/v1/answer', body: {'agent': agent, 'key': key, 'text': text});

  /// Starts an agent; answers its `name@machine`.
  Future<String> newAgent({
    required String machine,
    String? cwd,
    String? name,
    String? role,
    String? prompt,
    String? model,
    String? effort,
  }) async {
    String? blank(String? s) => s == null || s.trim().isEmpty ? null : s.trim();
    final json = await _send('POST', '/v1/new', body: {
      'machine': machine,
      if (blank(cwd) != null) 'cwd': blank(cwd),
      if (blank(name) != null) 'name': blank(name),
      if (blank(role) != null) 'role': blank(role),
      if (blank(prompt) != null) 'prompt': blank(prompt),
      if (blank(model) != null) 'model': blank(model),
      if (blank(effort) != null) 'effort': blank(effort),
    }, timeout: const Duration(seconds: 100)); // the hub allows starting one 90 s
    return '${json['agent']}';
  }

  /// Starts an agent from a pasted brief; the hub decides where and how.
  /// Answers its `name@machine` and the plan it followed.
  Future<(String, Map<String, dynamic>)> newFromBrief(String brief) async {
    // The hub plans it first (a headless Claude), and allows that 240 s.
    final json = await _send('POST', '/v1/new', body: {'brief': brief}, timeout: const Duration(seconds: 250));
    return ('${json['agent']}', (json['plan'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{});
  }

  Future<void> resume(String agent) =>
      _send('POST', '/v1/resume', body: {'agent': agent}, timeout: const Duration(seconds: 100));

  Future<void> kill(String agent) => _send('POST', '/v1/kill', body: {'agent': agent});

  /// SDK agents: stop the turn in progress; true when there was one.
  Future<bool> interrupt(String agent) async =>
      (await _send('POST', '/v1/interrupt', body: {'agent': agent}))['interrupted'] == true;

  /// SDK agents: switch the model, live.
  Future<void> setModel(String agent, String model) =>
      _send('POST', '/v1/model', body: {'agent': agent, 'model': model});

  /// SDK agents: switch the effort level, live.
  Future<void> setEffort(String agent, String effort) =>
      _send('POST', '/v1/effort', body: {'agent': agent, 'effort': effort});

  /// A thought for Jev to route: to the agent it fits, or a new agent; [to] or
  /// [newAgent] send it without asking. Answers the action taken (`sent`,
  /// `started`) or `ask` with the candidates when Jev was unsure.
  Future<Map<String, dynamic>> capture(String text, {String? to, bool newAgent = false}) => _send(
        'POST',
        '/v1/capture',
        body: {'text': text, 'to': ?to, if (newAgent) 'new': true},
        timeout: const Duration(seconds: 250), // a new agent is planned first
      );

  /// Stops an idle agent's process; it stays on the roster and starts again when used.
  Future<void> park(String agent) => _send('POST', '/v1/park', body: {'agent': agent});

  /// The UnifiedPush endpoint the hub posts to, or null to stop pushes.
  Future<void> setPush(String? endpoint) => _send('POST', '/v1/push', body: {'endpoint': endpoint});

  Future<List<Device>> devices() async {
    final json = await _send('GET', '/v1/devices');
    return [
      for (final d in (json['devices'] as List? ?? const []))
        if (d is Map<String, dynamic>) Device.fromJson(d),
    ];
  }

  Future<void> revokeDevice(String id) => _send('DELETE', '/v1/devices/${Uri.encodeComponent(id)}');

  /// One connection to `GET /v1/events`. The stream ends when the connection
  /// drops; reconnecting is the caller's job. Cancelling closes the connection.
  Stream<SseEvent> events({String? lastEventId}) {
    final client = _streamClient();
    late final StreamController<SseEvent> out;
    StreamSubscription<SseEvent>? sub;
    out = StreamController<SseEvent>(
      onListen: () async {
        final req = http.Request('GET', _uri('/v1/events'))
          ..headers.addAll({
            ..._headers,
            'Accept': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Last-Event-ID': ?lastEventId,
          })
          // fetch's keepalive is for short requests that outlive the page.
          ..persistentConnection = !kIsWeb;
        try {
          final res = await client.send(req).timeout(_timeout);
          if (res.statusCode != 200) {
            final body = await res.stream.bytesToString().catchError((_) => '');
            String msg = 'HTTP ${res.statusCode}';
            try {
              final json = jsonDecode(body);
              if (json is Map && json['error'] != null) msg = '${json['error']}';
            } on FormatException {
              // keep the status line
            }
            throw HubException(res.statusCode, msg);
          }
          sub = res.stream.transform(const SseParser()).listen(
                out.add,
                onError: out.addError,
                onDone: out.close,
              );
        } catch (e) {
          if (!out.isClosed) {
            out.addError(e is http.ClientException ? HubException(0, e.message) : e);
            await out.close();
          }
        }
      },
      onCancel: () async {
        await sub?.cancel();
        client.close();
      },
    );
    return out.stream;
  }

  void close() => _client.close();
}
