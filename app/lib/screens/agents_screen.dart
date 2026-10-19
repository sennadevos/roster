import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../app.dart';
import '../models/agent.dart';
import '../state/app_state.dart';
import '../widgets/status.dart';
import 'agent_screen.dart';
import 'new_agent_sheet.dart';
import 'settings_screen.dart';

/// Every agent the hub reaches, grouped by machine, live from `/v1/events`.
/// On a wide window the open agent sits beside the list.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  bool? _wide;

  /// Moves the open agent when the window crosses [splitViewWidth]: from its
  /// own page into the pane beside the list, or back.
  void _layout(bool wide) {
    final was = _wide;
    _wide = wide;
    splitView = wide;
    if (was == null || was == wide) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = navigatorKey.currentState;
      if (!mounted || nav == null || splitView != wide) return;
      final agent = selectedAgent.value;
      if (wide) {
        nav.popUntil((r) => r.settings.name != agentRouteName);
      } else if (agent != null && (ModalRoute.of(context)?.isCurrent ?? false)) {
        pushAgent(nav, agent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= splitViewWidth;
      _layout(wide);
      if (!wide) return const _AgentList();
      return ValueListenableBuilder<String?>(
        valueListenable: selectedAgent,
        builder: (context, agent, _) => Row(
          children: [
            SizedBox(width: 380, child: _AgentList(selected: agent)),
            const VerticalDivider(width: 1),
            Expanded(
              child: agent == null
                  ? const _NoAgent()
                  : AgentScreen(key: ValueKey(agent), agent: agent),
            ),
          ],
        ),
      );
    });
  }
}

class _NoAgent extends StatelessWidget {
  const _NoAgent();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Text('Pick an agent on the left', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline)),
      ),
    );
  }
}

class _AgentList extends StatelessWidget {
  const _AgentList({this.selected});

  /// The agent open beside the list, highlighted.
  final String? selected;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final groups = app.snapshot.grouped();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roster'),
        actions: [
          _LinkDot(app),
          // Pull to refresh needs a touch screen.
          if (kIsWeb)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => app.refresh().catchError((Object e) {
                if (context.mounted) showError(context, e);
              }),
            ),
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
                    for (final a in agents) AgentTile(a, selected: a.id == selected),
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
  const AgentTile(this.agent, {super.key, this.selected = false});

  final Agent agent;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = agent.stale != null || agent.ended;
    return Opacity(
      opacity: dim ? 0.6 : 1,
      child: ListTile(
        selected: selected,
        selectedTileColor: cs.secondaryContainer,
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
