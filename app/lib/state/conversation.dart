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

  /// Prompts sent but not yet seen in the transcript, shown dimmed.
  final List<String> pending = [];

  /// An answer to the dialog went out; the screen has not shown the next
  /// state yet.
  bool answered = false;

  /// Whether the tail was ever asked for, so a cached conversation is only
  /// brought up to date when opened again.
  bool started = false;

  /// Text typed into the composer and not sent, kept when switching agents.
  String draft = '';

  bool _fetching = false;
  bool _again = false;
  bool _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// The first time: the tail; after that, what is new.
  Future<void> open() {
    if (!started) {
      started = true;
      return loadTail();
    }
    return fetchNew();
  }

  Future<void> loadTail() async {
    started = true;
    loading = true;
    error = null;
    _changed();
    try {
      final page = await client.transcript(agent, limit: pageSize);
      messages
        ..clear()
        ..addAll(page.messages);
      for (final m in page.messages) {
        if (m.role == 'user') pending.remove(m.text.trim());
      }
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
    // A prompt shows up in the transcript as a user line: it is sent.
    for (final m in fresh) {
      if (m.role == 'user') pending.remove(m.text.trim());
    }
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
      answered = false;
    } on HubException catch (e) {
      error = e.message;
    }
    _changed();
  }

  /// Sends the keys for a dialog option. Ticking a box or moving between a
  /// form's questions keeps the card and refreshes it; picking an answer
  /// marks the dialog answered until the screen shows what comes next.
  /// Answers the dialog's free-text option with [text].
  Future<void> answerText(DialogOption option, String text) async {
    await client.answer(agent, option.key, text);
    answered = true;
    _changed();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!_disposed) await fetchScreen();
  }

  Future<void> answer(DialogOption option) async {
    final staysOpen = option.checked != null || option.actionKeys != null;
    await client.keys(agent, option.keys);
    if (!staysOpen) {
      answered = true;
      _changed();
    }
    // The status event follows; this catches the next state right away.
    await Future<void>.delayed(Duration(milliseconds: staysOpen ? 250 : 700));
    if (!_disposed) await fetchScreen();
  }

  /// Sends a prompt. It shows at once as pending, and goes when the
  /// transcript has it; on failure it is taken back and the error rethrown.
  Future<void> send(String text) async {
    final t = text.trim();
    pending.add(t);
    _changed();
    try {
      await client.prompt(agent, t);
    } catch (_) {
      pending.remove(t);
      _changed();
      rethrow;
    }
    for (final wait in const [Duration(milliseconds: 600), Duration(seconds: 2), Duration(seconds: 5)]) {
      await Future<void>.delayed(wait);
      if (_disposed || !pending.contains(t)) return;
      await fetchNew();
    }
    // Never seen (the transcript may word it differently): stop waiting.
    if (pending.remove(t)) _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
