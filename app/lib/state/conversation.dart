import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/hub_client.dart';
import '../models/misc.dart';
import '../models/transcript.dart';

/// One agent's conversation and terminal, for the agent screen.
///
/// The screen starts from the tail (no `after`: the last `limit` messages),
/// takes newer ones with `after`, and older ones with `before` = the oldest
/// line shown.
class Conversation extends ChangeNotifier {
  Conversation(this.client, this.agent, {this.pageSize = 100});

  final HubClient client;
  final String agent;
  final int pageSize;

  /// Oldest first.
  final List<Message> messages = [];
  String? sessionId;
  int? next;
  bool loading = false;
  bool loadingOlder = false;
  bool hasOlder = true;
  String? error;
  Screen? screen;

  bool _fetching = false;
  bool _again = false;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadTail() async {
    loading = true;
    error = null;
    _changed();
    try {
      final page = await client.transcript(agent, limit: pageSize);
      messages
        ..clear()
        ..addAll(page.messages);
      sessionId = page.sessionId;
      next = page.next;
      hasOlder = page.messages.length >= pageSize || (page.messages.isNotEmpty && page.messages.first.i > 1);
    } on HubException catch (e) {
      error = e.message;
    } finally {
      loading = false;
      _changed();
    }
  }

  /// Whatever came after the newest message shown. Calls while one runs are
  /// folded into one more round.
  Future<void> fetchNew() async {
    if (next == null) return loadTail();
    if (_fetching) {
      _again = true;
      return;
    }
    _fetching = true;
    try {
      do {
        _again = false;
        var first = true;
        while (true) {
          final after = first ? _cursor() : next!;
          first = false;
          final page = await client.transcript(agent, after: after, limit: pageSize);
          if (sessionId != null && page.sessionId != null && page.sessionId != sessionId) {
            // A new Claude session (resumed or cleared): start over from its tail.
            await loadTail();
            break;
          }
          _merge(page.messages);
          next = max(next!, page.next);
          error = null;
          _changed();
          if (page.messages.length < pageSize || page.next <= after) break;
        }
      } while (_again && !_disposed);
    } on HubException catch (e) {
      error = e.message;
      _changed();
    } finally {
      _fetching = false;
    }
  }

  Future<void> loadOlder() async {
    if (loadingOlder || !hasOlder || messages.isEmpty) return;
    loadingOlder = true;
    _changed();
    try {
      final page = await client.transcript(agent, before: messages.first.i, limit: pageSize);
      final seen = {for (final m in messages) m.key};
      messages.insertAll(0, page.messages.where((m) => seen.add(m.key)));
      hasOlder = page.messages.length == pageSize;
    } on HubException catch (e) {
      error = e.message;
    } finally {
      loadingOlder = false;
      _changed();
    }
  }

  void _merge(List<Message> fresh) {
    final at = {for (var k = 0; k < messages.length; k++) messages[k].key: k};
    for (final m in fresh) {
      final k = at[m.key];
      if (k != null) {
        messages[k] = m; // a tool row comes back with its result folded in
      } else {
        at[m.key] = messages.length;
        messages.add(m);
      }
    }
  }

  /// Where to fetch new messages from: just before the oldest recent tool
  /// call still without a result, since the result is folded into that
  /// earlier line; else [next].
  int _cursor() {
    final recent = messages.length > 20 ? messages.sublist(messages.length - 20) : messages;
    for (final m in recent) {
      if (m.role == 'tool' && m.result == null) return min(next!, m.i - 1);
    }
    return next!;
  }

  Future<void> fetchScreen() async {
    try {
      screen = await client.screen(agent);
    } on HubException catch (e) {
      error = e.message;
    }
    _changed();
  }

  Future<void> answer(DialogOption option) async {
    await client.keys(agent, [option.key]);
    screen = null;
    _changed();
    // The status event follows; this catches a second dialog right away.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!_disposed) await fetchScreen();
  }

  Future<void> send(String text) async {
    await client.prompt(agent, text);
    unawaited(Future<void>.delayed(const Duration(seconds: 1), () => _disposed ? null : fetchNew()));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
