/// One entry of `GET /v1/transcript`.
class Message {
  const Message({
    required this.i,
    required this.role,
    required this.text,
    this.at,
    this.tool,
    this.result,
    this.error = false,
  });

  /// The transcript JSONL line number; larger is newer.
  final int i;

  /// `user`, `assistant` or `tool`.
  final String role;
  final String text;
  final DateTime? at;
  final String? tool;
  final String? result;
  final bool error;

  /// Identity within a transcript, to drop duplicates when pages overlap.
  String get key => '$i/$role/${tool ?? ''}/${text.hashCode}';

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        i: (json['i'] as num).toInt(),
        role: json['role'] as String? ?? 'assistant',
        text: json['text'] as String? ?? '',
        at: _parseTime(json['at']),
        tool: json['tool'] as String?,
        result: json['result'] as String?,
        error: json['error'] == true,
      );
}

/// The contract's stamps look like `2026-10-18T16:32:11+0200`, which
/// DateTime.parse does not take without the colon in the offset.
DateTime? _parseTime(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final fixed = raw.replaceFirstMapped(RegExp(r'([+-]\d\d)(\d\d)$'), (m) => '${m[1]}:${m[2]}');
  return DateTime.tryParse(fixed)?.toLocal();
}

class TranscriptPage {
  const TranscriptPage({required this.agent, this.sessionId, required this.messages, required this.next});

  final String agent;
  final String? sessionId;
  final List<Message> messages;

  /// What to pass as `after` to get what comes later.
  final int next;

  factory TranscriptPage.fromJson(Map<String, dynamic> json) {
    final messages = [
      for (final m in (json['messages'] as List? ?? const []))
        if (m is Map<String, dynamic>) Message.fromJson(m),
    ];
    return TranscriptPage(
      agent: json['agent'] as String? ?? '',
      sessionId: json['session_id'] as String?,
      messages: messages,
      next: (json['next'] as num?)?.toInt() ?? (messages.isEmpty ? 0 : messages.last.i + 1),
    );
  }
}
