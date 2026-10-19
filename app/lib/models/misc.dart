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

/// A choice dialog on an agent's screen. A form of several questions has
/// [tabs] and [actions] (Back and Next) to move between them; a question that
/// takes several answers has tick boxes ([DialogOption.checked]).
class ScreenDialog {
  const ScreenDialog({required this.title, required this.options, this.multi = false,
      this.tabs = const [], this.actions = const []});

  final String title;
  final List<DialogOption> options;
  final bool multi;
  final List<DialogTab> tabs;
  final List<DialogOption> actions;

  factory ScreenDialog.fromJson(Map<String, dynamic> json) => ScreenDialog(
        title: json['title'] as String? ?? '',
        multi: json['multi'] == true,
        options: [
          for (final o in (json['options'] as List? ?? const []))
            if (o is Map)
              DialogOption(
                key: '${o['key']}',
                label: '${o['label'] ?? ''}',
                detail: '${o['detail'] ?? ''}',
                checked: o['checked'] is bool ? o['checked'] as bool : null,
              ),
        ],
        tabs: [
          for (final t in (json['tabs'] as List? ?? const []))
            if (t is Map) DialogTab(label: '${t['label'] ?? ''}', done: t['done'] == true),
        ],
        actions: [
          for (final a in (json['actions'] as List? ?? const []))
            if (a is Map)
              DialogOption(
                key: '',
                label: '${a['label'] ?? ''}',
                actionKeys: [for (final k in (a['keys'] as List? ?? const [])) '$k'],
              ),
        ],
      );
}

class DialogOption {
  const DialogOption({required this.key, required this.label, this.detail = '', this.checked, this.actionKeys});

  /// The key that picks this option.
  final String key;
  final String label;
  final String detail;

  /// Ticked or not, on a question that takes several answers; null otherwise.
  final bool? checked;
  /// An action's own keys (Back, Next); null for an option, which is its number.
  final List<String>? actionKeys;

  /// The keys to send for it.
  List<String> get keys => actionKeys ?? [key];
}

class DialogTab {
  const DialogTab({required this.label, required this.done});

  final String label;
  final bool done;
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
