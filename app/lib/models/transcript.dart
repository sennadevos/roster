import 'agent.dart' show parseStamp;

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
    this.queued = false,
    this.withdrawn = false,
  });

  /// The transcript JSONL line number; larger is newer.
  final int i;

  /// `user`, `assistant`, `tool` or `event` (a task finished, a command's output).
  final String role;
  final String text;
  final DateTime? at;
  final String? tool;
  final String? result;
  final bool error;

  /// A prompt sent while the agent worked, not yet taken in by Claude.
  final bool queued;

  /// A queued prompt pulled back into the input to edit: never sent as it was.
  final bool withdrawn;

  /// Identity within a transcript, to drop duplicates when pages overlap.
  String get key => '$i/$role/${tool ?? ''}/${text.hashCode}';

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        i: (json['i'] as num).toInt(),
        role: json['role'] as String? ?? 'assistant',
        text: json['text'] as String? ?? '',
        at: parseStamp(json['at']),
        tool: json['tool'] as String?,
        result: json['result'] as String?,
        error: json['error'] == true,
        queued: json['queued'] == true,
        withdrawn: json['withdrawn'] == true,
      );
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
