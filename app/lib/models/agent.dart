import 'dart:convert';

/// An API error that needs (or needed) the user, from a row's `stalled`.
class Stalled {
  const Stalled({required this.error, this.message, this.gaveUp = false});

  final String error;
  final String? message;
  final bool gaveUp;

  /// API errors that clear by themselves (roster's TRANSIENT): the agent
  /// resumes when the API answers, so they do not need the user.
  static const transientErrors = {'rate_limit', 'overloaded', 'server_error', 'unknown'};

  bool get transient => !gaveUp && transientErrors.contains(error);

  static Stalled? fromJson(Object? json) {
    if (json is! Map) return null;
    return Stalled(
      error: '${json['error'] ?? 'unknown'}',
      message: json['message'] as String?,
      gaveUp: json['gave_up'] == true,
    );
  }
}

/// A Claude subagent an agent runs, from a row's `subagents`. Shown under
/// its agent, never as an agent of its own.
class Subagent {
  const Subagent({required this.id, required this.type, required this.label, required this.running,
      this.startedAt, this.endedAt});

  final String id;

  /// `general-purpose`, `Explore` and the like.
  final String type;

  /// The first line of its task.
  final String label;
  final bool running;
  final DateTime? startedAt;
  final DateTime? endedAt;

  static List<Subagent> listFromJson(Object? json) => [
        if (json is List)
          for (final s in json)
            if (s is Map)
              Subagent(
                id: '${s['id'] ?? ''}',
                type: '${s['type'] ?? 'subagent'}',
                label: '${s['label'] ?? ''}',
                running: s['status'] != 'done',
                startedAt: parseStamp(s['started_at']),
                endedAt: parseStamp(s['ended_at']),
              ),
      ];
}

/// Roster's stamps look like `2026-10-18T16:32:11+0200`, which
/// DateTime.parse does not take without the colon in the offset.
DateTime? parseStamp(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  final fixed = raw.replaceFirstMapped(RegExp(r'([+-]\d\d)(\d\d)$'), (m) => '${m[1]}:${m[2]}');
  return DateTime.tryParse(fixed)?.toLocal();
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
    this.statusAt,
    this.model,
    this.effort,
    this.temp = false,
    this.harness,
    this.drift,
    this.subagents = const [],
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

  /// When the status last changed (or when it ended).
  final DateTime? statusAt;
  final String? model;
  final String? effort;

  /// A quick agent, started for one job.
  final bool temp;

  /// What runs it: `sdk` (roster's Agent SDK runner) or `claude` (Claude Code).
  final String? harness;

  /// Jev's score (0..1) when it judged that the name and role no longer fit
  /// the conversation (`roster drift`); null when they fit, or never checked.
  final double? drift;

  /// An SDK agent: its model and effort switch live, and it can be interrupted.
  bool get sdk => harness == 'sdk';
  final List<Subagent> subagents;

  /// The row as JSON, to tell whether anything about the agent changed.
  final String fingerprint;

  bool get ended => status == 'gone' || status == 'left';

  /// No process, still on the roster: opening, prompting or mailing it resumes it.
  bool get parked => status == 'parked';

  /// Waits on the user: a dialog on screen, or an API error that will not
  /// clear by itself.
  bool get needsYou => !ended && (status == 'blocked' || (stalled != null && !stalled!.transient));

  /// The last part of the name; the rest is the leads above it.
  String get leaf => name.split('/').last;

  /// `rator-firmware/` for `rator-firmware/ui`, empty for a lead.
  String get parentPrefix => name.contains('/') ? name.substring(0, name.lastIndexOf('/') + 1) : '';

  int get depth => '/'.allMatches(name).length;

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
      statusAt: parseStamp(json['ended_at']) ?? parseStamp(json['status_at']),
      model: json['model'] is String ? json['model'] as String : null,
      effort: json['effort'] is String ? json['effort'] as String : null,
      temp: json['temp'] == true,
      harness: json['harness'] is String ? json['harness'] as String : null,
      drift: json['drift'] is Map && (json['drift'] as Map)['fits'] is num
          ? ((json['drift'] as Map)['fits'] as num).toDouble()
          : null,
      subagents: Subagent.listFromJson(json['subagents']),
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
