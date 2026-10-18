import 'dart:convert';

/// An API error that needs (or needed) the user, from a row's `stalled`.
class Stalled {
  const Stalled({required this.error, this.message, this.gaveUp = false});

  final String error;
  final String? message;
  final bool gaveUp;

  static Stalled? fromJson(Object? json) {
    if (json is! Map) return null;
    return Stalled(
      error: '${json['error'] ?? 'unknown'}',
      message: json['message'] as String?,
      gaveUp: json['gave_up'] == true,
    );
  }
}

/// One row of `GET /v1/agents`: a `roster list --json` row plus `agent`.
class Agent {
  Agent({
    required this.id,
    required this.name,
    required this.machine,
    required this.status,
    this.role,
    this.cwd,
    this.unread = 0,
    this.local = false,
    this.stalled,
    this.stale,
    required this.fingerprint,
  });

  /// `name@machine`, how the hub and the app address an agent.
  final String id;
  final String name;
  final String machine;
  final String status;
  final String? role;
  final String? cwd;
  final int unread;
  final bool local;
  final Stalled? stalled;

  /// Set when the row is the last one known from an unreachable machine.
  final String? stale;

  /// The row as JSON, to tell whether anything about the agent changed.
  final String fingerprint;

  bool get ended => status == 'gone' || status == 'left';

  factory Agent.fromJson(Map<String, dynamic> json) {
    final name = '${json['name'] ?? '?'}';
    final machine = '${json['machine'] ?? ''}';
    return Agent(
      id: json['agent'] as String? ?? (machine.isEmpty ? name : '$name@$machine'),
      name: name,
      machine: machine,
      status: json['status'] as String? ?? 'unknown',
      role: json['role'] as String?,
      cwd: json['cwd'] as String?,
      unread: (json['unread'] as num?)?.toInt() ?? 0,
      local: json['local'] == true,
      stalled: Stalled.fromJson(json['stalled']),
      stale: json['stale'] is String ? json['stale'] as String : null,
      fingerprint: jsonEncode(json),
    );
  }
}

/// A machine the hub reaches, from `machines` in `GET /v1/agents`.
class Machine {
  const Machine({required this.name, this.local = false, this.reachable = true, this.error});

  final String name;
  final bool local;
  final bool reachable;
  final String? error;

  factory Machine.fromJson(Map<String, dynamic> json) => Machine(
        name: '${json['name']}',
        local: json['local'] == true,
        reachable: json['reachable'] != false,
        error: json['error'] as String?,
      );
}

/// The whole list, as `GET /v1/agents` answers and every `agents` event carries.
class AgentsSnapshot {
  const AgentsSnapshot({this.agents = const [], this.machines = const []});

  final List<Agent> agents;
  final List<Machine> machines;

  factory AgentsSnapshot.fromJson(Map<String, dynamic> json) => AgentsSnapshot(
        agents: [
          for (final row in (json['agents'] as List? ?? const []))
            if (row is Map<String, dynamic>) Agent.fromJson(row),
        ],
        machines: [
          for (final m in (json['machines'] as List? ?? const []))
            if (m is Map<String, dynamic>) Machine.fromJson(m),
        ],
      );

  Agent? byId(String id) {
    for (final a in agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Machines in hub order (local first), each with its agents; machines that
  /// only show up in rows are added at the end.
  List<(Machine, List<Agent>)> grouped() {
    final order = [...machines];
    for (final a in agents) {
      if (!order.any((m) => m.name == a.machine)) order.add(Machine(name: a.machine));
    }
    order.sort((a, b) => a.local == b.local ? 0 : (a.local ? -1 : 1));
    return [
      for (final m in order) (m, agents.where((a) => a.machine == m.name).toList()),
    ];
  }
}
