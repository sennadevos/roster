import 'package:flutter/material.dart';

import '../app.dart';
import '../models/agent.dart';
import '../state/app_state.dart';
import '../widgets/status.dart';
import 'new_agent_sheet.dart';
import 'settings_screen.dart';

/// Every agent the hub reaches, grouped by machine, live from `/v1/events`.
class AgentsScreen extends StatelessWidget {
  const AgentsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final groups = app.snapshot.grouped();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roster'),
        actions: [
          _LinkDot(app),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'ended' => app.setShowEnded(!app.showEnded),
              _ => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'ended', checked: app.showEnded, child: const Text('Show ended')),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showNewAgentSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('New agent'),
      ),
      body: RefreshIndicator(
        onRefresh: () => app.refresh().catchError((Object e) {
          if (context.mounted) showError(context, e);
        }),
        child: !app.haveSnapshot
            ? ListView(children: [
                const SizedBox(height: 120),
                Center(
                  child: app.link == Link.offline && app.linkError != null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Cannot reach the hub: ${app.linkError}', textAlign: TextAlign.center),
                        )
                      : const CircularProgressIndicator(),
                ),
              ])
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final (machine, agents) in groups) ...[
                    _MachineHeader(machine),
                    if (agents.isEmpty)
                      const ListTile(dense: true, title: Text('No agents')),
                    for (final a in agents) AgentTile(a),
                  ],
                ],
              ),
      ),
    );
  }
}

class _LinkDot extends StatelessWidget {
  const _LinkDot(this.app);

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (icon, color, tip) = switch (app.link) {
      Link.live => (Icons.cloud_done_outlined, cs.primary, 'Live'),
      Link.connecting => (Icons.cloud_sync_outlined, cs.outline, 'Connecting'),
      Link.offline => (Icons.cloud_off_outlined, cs.error, 'Offline: ${app.linkError ?? ''}'),
    };
    return Tooltip(message: tip, child: Padding(padding: const EdgeInsets.all(8), child: Icon(icon, color: color)));
  }
}

class _MachineHeader extends StatelessWidget {
  const _MachineHeader(this.machine);

  final Machine machine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(machine.reachable ? Icons.computer : Icons.portable_wifi_off,
              size: 18, color: machine.reachable ? theme.colorScheme.primary : theme.colorScheme.error),
          const SizedBox(width: 8),
          Text(machine.name, style: theme.textTheme.titleSmall),
          if (machine.local) Text('  hub', style: theme.textTheme.labelSmall),
          if (!machine.reachable)
            Expanded(
              child: Text('  unreachable${machine.error == null ? '' : ': ${machine.error}'}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}

class AgentTile extends StatelessWidget {
  const AgentTile(this.agent, {super.key});

  final Agent agent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = agent.stale != null || agent.ended;
    return Opacity(
      opacity: dim ? 0.6 : 1,
      child: ListTile(
        leading: StatusGlyph(agent.status),
        title: Text(agent.name, overflow: TextOverflow.ellipsis),
        subtitle: agent.role == null ? null : Text(agent.role!, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (agent.stalled != null)
              Tooltip(
                message: 'API error: ${agent.stalled!.error}',
                child: Text('⚠', style: TextStyle(color: cs.error, fontSize: 20)),
              ),
            if (agent.unread > 0) ...[
              const SizedBox(width: 8),
              Badge(label: Text('${agent.unread}'), child: const Icon(Icons.mail_outline)),
            ],
          ],
        ),
        onTap: () => openAgent(agent.id),
      ),
    );
  }
}
