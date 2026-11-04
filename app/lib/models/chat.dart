import 'dart:convert';

import 'agent.dart' show parseStamp;

/// A chat: a conversation with a model and no session on the other side. The
/// whole history is sent every turn, which is why a message can be edited and
/// the chat carried on from there.
class Chat {
  const Chat({required this.id, required this.title, required this.model, this.params = const {}, this.updatedAt});

  final int id;
  final String title;
  final String model;

  /// How the model is set up for this chat: effort, temperature, max_tokens.
  final Map<String, dynamic> params;
  final DateTime? updatedAt;

  factory Chat.fromJson(Map<String, dynamic> json) => Chat(
        id: (json['id'] as num).toInt(),
        title: json['title'] as String? ?? 'New chat',
        model: json['model'] as String? ?? '',
        params: _params(json['params']),
        updatedAt: parseStamp(json['updated_at']),
      );

  /// The CLI stores params as a JSON string; the hub passes it through as it is.
  static Map<String, dynamic> _params(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final v = jsonDecode(raw);
        if (v is Map<String, dynamic>) return v;
      } on FormatException {
        return const {};
      }
    }
    return const {};
  }
}

/// One message in a chat. `cost` and `model` are set on an answer when the
/// provider reported them.
class ChatTurn {
  const ChatTurn({required this.id, required this.role, required this.text, this.at, this.cost, this.model});

  final int id;
  final String role;
  final String text;
  final DateTime? at;
  final double? cost;
  final String? model;

  bool get mine => role == 'user';

  factory ChatTurn.fromJson(Map<String, dynamic> json) => ChatTurn(
        id: (json['id'] as num?)?.toInt() ?? 0,
        role: json['role'] as String? ?? 'assistant',
        text: json['text'] as String? ?? '',
        at: parseStamp(json['at']),
        cost: (json['cost'] as num?)?.toDouble(),
        model: json['model'] as String?,
      );
}

/// A chat with its messages, as `GET /v1/chats/{id}` answers.
class ChatPage {
  const ChatPage({required this.chat, required this.messages});

  final Chat chat;
  final List<ChatTurn> messages;

  factory ChatPage.fromJson(Map<String, dynamic> json) => ChatPage(
        chat: Chat.fromJson(json),
        messages: [
          for (final m in (json['messages'] as List? ?? const []))
            if (m is Map<String, dynamic>) ChatTurn.fromJson(m),
        ],
      );
}

/// One model from `GET /v1/models`: OpenRouter's catalogue plus the Claude
/// models that go through Senna's own login.
class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    this.contextLength = 0,
    this.supported = const [],
    this.priceIn = 0,
    this.priceOut = 0,
  });

  final String id;
  final String name;
  final int contextLength;

  /// Which knobs this model takes: `reasoning`, `temperature`, `max_tokens`.
  final List<String> supported;

  /// Dollars per million tokens.
  final double priceIn;
  final double priceOut;

  bool takes(String param) => supported.contains(param);

  /// Claude models go through the CLI and have no price here.
  bool get isClaude => id.startsWith('claude:');

  /// `1M context · $2/$10 per Mtok`, for the line under the picker.
  String get summary {
    // 1048576 is 1M to anyone reading it, not 1.0M
    final millions = (contextLength / 1000000).toStringAsFixed(1);
    final ctx = contextLength >= 1000000
        ? '${millions.endsWith('.0') ? millions.substring(0, millions.length - 2) : millions}M context'
        : contextLength > 0
            ? '${(contextLength / 1000).round()}k context'
            : '';
    final price = isClaude
        ? 'your login'
        : priceIn > 0 || priceOut > 0
            ? '\$${_money(priceIn)}/\$${_money(priceOut)} per Mtok'
            : 'free';
    return [ctx, price].where((s) => s.isNotEmpty).join(' · ');
  }

  static String _money(double v) => v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? json['id'] as String? ?? '',
        contextLength: (json['context_length'] as num?)?.toInt() ?? 0,
        supported: [for (final s in (json['supported'] as List? ?? const [])) '$s'],
        priceIn: (json['price_in'] as num?)?.toDouble() ?? 0,
        priceOut: (json['price_out'] as num?)?.toDouble() ?? 0,
      );
}
