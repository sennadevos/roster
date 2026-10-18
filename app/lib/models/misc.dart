import 'dart:convert';

/// `GET /v1/screen`: the agent's terminal and the dialog if one is open.
class Screen {
  const Screen({required this.status, required this.text, this.dialog});

  final String status;
  final String text;
  final ScreenDialog? dialog;

  factory Screen.fromJson(Map<String, dynamic> json) => Screen(
        status: json['status'] as String? ?? 'unknown',
        text: json['text'] as String? ?? '',
        dialog: json['dialog'] is Map<String, dynamic>
            ? ScreenDialog.fromJson(json['dialog'] as Map<String, dynamic>)
            : null,
      );
}

class ScreenDialog {
  const ScreenDialog({required this.title, required this.options});

  final String title;
  final List<DialogOption> options;

  factory ScreenDialog.fromJson(Map<String, dynamic> json) => ScreenDialog(
        title: json['title'] as String? ?? '',
        options: [
          for (final o in (json['options'] as List? ?? const []))
            if (o is Map) DialogOption(key: '${o['key']}', label: '${o['label'] ?? ''}'),
        ],
      );
}

class DialogOption {
  const DialogOption({required this.key, required this.label});

  /// The key that picks this option.
  final String key;
  final String label;
}

/// A paired phone, from `GET /v1/devices`.
class Device {
  const Device({
    required this.id,
    required this.name,
    this.created,
    this.lastSeen,
    this.push = false,
    this.current = false,
  });

  final String id;
  final String name;
  final String? created;
  final String? lastSeen;
  final bool push;
  final bool current;

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: '${json['id']}',
        name: json['name'] as String? ?? '',
        created: json['created']?.toString(),
        lastSeen: json['last_seen']?.toString(),
        push: json['push'] == true,
        current: json['current'] == true,
      );
}

/// The JSON body the hub pushes through UnifiedPush.
class PushPayload {
  const PushPayload({required this.type, required this.agent, required this.title, required this.body});

  /// `blocked`, `asking`, `finished` or `error`.
  final String type;
  final String agent;
  final String title;
  final String body;

  /// Null when the bytes are not a push from the hub.
  static PushPayload? tryParse(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic> || json['agent'] is! String) return null;
      return PushPayload(
        type: json['type'] as String? ?? '',
        agent: json['agent'] as String,
        title: json['title'] as String? ?? json['agent'] as String,
        body: json['body'] as String? ?? '',
      );
    } on FormatException {
      return null;
    }
  }
}
