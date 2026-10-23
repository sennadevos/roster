import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../models/agent.dart';
import '../platform/platform.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/bits.dart';
import '../widgets/status.dart';
import 'agent_screen.dart';
import 'new_agent_sheet.dart';
import 'settings_screen.dart';

/// Every agent the hub reaches, live from `/v1/events`: the ones that need
/// the user on top, then each machine's. On a wide window the open agent
/// sits beside the list.
///
/// Keys (when no text field has focus): `/` searches, `j`/`k` or the arrows
/// move between agents (beside the list they open at once), Enter opens or
/// goes to the open agent's composer or dialog, Esc steps back.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  bool? _wide;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');
  final _keys = FocusNode(debugLabel: 'agents keys');

  /// The row the keyboard is on, on a narrow window (wide, it is the open one).
  String? _cursor;
  final _rowKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    installCopyKey();
    if (kIsWeb) {
      // Note the build now, then look for a newer one every two minutes.
      WidgetsBinding.instance.addPostFrameCallback((_) => AppScope.read(context).checkForUpdate());
      _updates = Timer.periodic(const Duration(minutes: 2), (_) => AppScope.read(context).checkForUpdate());
    }
  }

  Timer? _updates;

  @override
  void dispose() {
    _updates?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _keys.dispose();
    super.dispose();
  }

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

  List<Agent> _order(AppState app) => _ListModel(app, _search.text, recent: app.recentView).order;

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorStateOfType<EditableTextState>() != null);
  }

  void _move(int by) {
    final order = _order(AppScope.read(context));
    if (order.isEmpty) return;
    final current = splitView ? selectedAgent.value : _cursor;
    final k = order.indexWhere((a) => a.id == current);
    final next = order[k < 0 ? (by > 0 ? 0 : order.length - 1) : (k + by).clamp(0, order.length - 1)].id;
    if (splitView) {
      openAgent(next);
    } else {
      setState(() => _cursor = next);
    }
    final row = _rowKeys[next]?.currentContext;
    if (row != null) {
      Scrollable.ensureVisible(row,
          duration: const Duration(milliseconds: 120), alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      Scrollable.ensureVisible(row,
          duration: const Duration(milliseconds: 120), alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Only the topmost page: not while settings or a sheet is open.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_typing) {
        if (_searchFocus.hasFocus && _search.text.isNotEmpty) {
          _search.clear();
        } else {
          FocusManager.instance.primaryFocus?.unfocus();
          _keys.requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (_search.text.isNotEmpty) {
        _search.clear();
      } else if (splitView && selectedAgent.value != null) {
        selectedAgent.value = null;
      }
      return KeyEventResult.handled;
    }
    if (_typing || HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.slash) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyJ || key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (splitView) {
        if (selectedAgent.value == null) {
          _move(1);
        } else {
          AgentScreen.focusRequest.value++;
        }
      } else if (_cursor != null) {
        openAgent(_cursor!);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// From the search field: Enter opens the first match, the arrows move.
  void _searchSubmitted() {
    final order = _order(AppScope.read(context));
    if (order.isEmpty) return;
    openAgent(order.first.id);
    _searchFocus.unfocus();
    _keys.requestFocus();
    if (splitView) AgentScreen.focusRequest.value++;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final n = app.needsYou;
    return Title(
      title: n > 0 ? '($n) Roster' : 'Roster',
      color: Theme.of(context).colorScheme.primary,
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= splitViewWidth;
          _layout(wide);
          Widget list(String? selected) => _AgentList(
                selected: selected,
                cursor: wide ? null : _cursor,
                wide: wide,
                search: _search,
                searchFocus: _searchFocus,
                onSearchSubmitted: _searchSubmitted,
                rowKey: (id) => _rowKeys.putIfAbsent(id, GlobalKey.new),
              );
          if (!wide) return list(null);
          return ValueListenableBuilder<String?>(
            valueListenable: selectedAgent,
            builder: (context, agent, _) => Row(
              children: [
                SizedBox(width: box.maxWidth >= 1200 ? 400 : 360, child: list(agent)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    layoutBuilder: (current, previous) => Stack(children: [...previous, ?current]),
                    child: agent == null
                        ? _NoAgent(key: const ValueKey(''), onOpen: openAgent)
                        : AgentScreen(key: ValueKey(agent), agent: agent),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

/// What the list shows, in order: the agents that need the user, then each
/// machine with the rest of its agents (or, in the recent view, every other
/// agent by last activity), all narrowed by the search.
class _ListModel {
  _ListModel(AppState app, String query, {this.recent = false}) {
    final q = query.trim().toLowerCase();
    searching = q.isNotEmpty;
    bool match(Agent a) =>
        !searching ||
        a.name.toLowerCase().contains(q) ||
        (a.role ?? '').toLowerCase().contains(q) ||
        a.machine.toLowerCase().contains(q);
    needs = searching ? [] : app.snapshot.agents.where((a) => a.needsYou && a.stale == null).toList();
    final pinned = needs.map((a) => a.id).toSet();
    parked = [for (final a in app.snapshot.agents) if (a.parked && match(a)) a]..sort((a, b) => a.name.compareTo(b.name));
    pinned.addAll(parked.map((a) => a.id));
    groups = [
      for (final (m, agents) in app.snapshot.grouped())
        if (!searching || agents.any(match)) (m, agents.where((a) => match(a) && !pinned.contains(a.id)).toList()),
    ];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    recentAgents = [for (final g in groups) ...g.$2]
      ..sort((a, b) => (b.statusAt ?? epoch).compareTo(a.statusAt ?? epoch));
    order = recent ? [...needs, ...recentAgents] : [...needs, for (final g in groups) ...g.$2];
  }

  final bool recent;
  late final List<Agent> parked;
  late final List<Agent> recentAgents;
  late final bool searching;
  late final List<Agent> needs;
  late final List<(Machine, List<Agent>)> groups;
  late final List<Agent> order;
}

class _AgentList extends StatelessWidget {
  const _AgentList({
    this.selected,
    this.cursor,
    required this.wide,
    required this.search,
    required this.searchFocus,
    required this.onSearchSubmitted,
    required this.rowKey,
  });

  /// The agent open beside the list, highlighted.
  final String? selected;

  /// The row the keyboard is on.
  final String? cursor;
  final bool wide;
  final TextEditingController search;
  final FocusNode searchFocus;
  final VoidCallback onSearchSubmitted;
  final GlobalKey Function(String id) rowKey;

  Future<void> _refresh(BuildContext context, AppState app) => app.refresh().catchError((Object e) {
        if (context.mounted) showError(context, e, action: 'Retry', onAction: () => _refresh(context, app));
      });

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final model = _ListModel(app, search.text, recent: app.recentView);
    final live = app.snapshot.agents.where((a) => !a.ended).length;
    final working = app.snapshot.agents.where((a) => a.status == 'working').length;

    Widget body;
    if (!app.haveSnapshot) {
      body = app.link == Link.offline && app.linkError != null
          ? Delayed(
              child: _Empty(
                icon: Icons.cloud_off_outlined,
                title: 'Cannot reach the hub',
                detail: '${app.linkError}. Trying again by itself.',
                action: 'Try now',
                onAction: () => _refresh(context, app),
              ),
            )
          : const _ListSkeleton();
    } else if (app.snapshot.agents.isEmpty && app.snapshot.machines.isEmpty) {
      body = _Empty(
        icon: Icons.groups_outlined,
        title: 'No agents yet',
        detail: 'Start one, or join one from a terminal with roster join.',
        action: 'New agent',
        onAction: () => showNewAgentSheet(context),
      );
    } else if (model.order.isEmpty && model.searching) {
      body = _Empty(
        icon: Icons.search_off,
        title: 'Nothing matches “${search.text.trim()}”',
        detail: 'Names, roles and machines are searched.',
        action: 'Clear search',
        onAction: search.clear,
      );
    } else {
      Widget tile(Agent a, {bool showMachine = false, bool indent = true}) => AgentTile(
            a,
            key: rowKey(a.id),
            selected: a.id == selected,
            cursor: a.id == cursor,
            showMachine: showMachine,
            indent: indent && !model.searching,
          );
      body = ListView(
        padding: EdgeInsets.only(bottom: wide ? 24 : 96, top: 4),
        children: [
          if (model.needs.isNotEmpty) ...[
            _SectionHeader(
              icon: Icons.priority_high_rounded,
              color: statusColors(context).blocked,
              title: 'Needs you',
              count: model.needs.length,
            ),
            for (final a in model.needs) tile(a, showMachine: true, indent: false),
          ],
          if (model.recent) ...[
            if (model.needs.isNotEmpty)
              _SectionHeader(
                icon: Icons.history,
                color: cs.outline,
                title: 'By last activity',
                count: model.recentAgents.length,
              ),
            for (final a in model.recentAgents) tile(a, showMachine: true, indent: false),
          ] else
          for (final (machine, agents) in model.groups) ...[
            _MachineHeader(machine, count: agents.length),
            if (agents.isEmpty && machine.reachable)
              Padding(
                padding: const EdgeInsets.fromLTRB(46, 0, 16, 8),
                child: Text(
                  app.snapshot.agents.any((a) => a.machine == machine.name) ? 'Only agents that need you' : 'No agents',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ),
            for (final a in agents) tile(a),
          ],
          if (model.parked.isNotEmpty)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const PageStorageKey('parked'),
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(Icons.pause_circle_outline, size: 18, color: cs.outline),
                title: Text('Parked (${model.parked.length})',
                    style: theme.textTheme.labelLarge?.copyWith(color: cs.outline)),
                subtitle: Text('No process running; you can read them, and sending one a message resumes it.',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.outline)),
                children: [for (final a in model.parked) tile(a, showMachine: true, indent: false)],
              ),
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        toolbarHeight: 60,
        title: Row(
          children: [
            Text('Roster', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            if (app.haveSnapshot)
              Flexible(
                child: Text(
                  working > 0 ? '$live live · $working working' : '$live live',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
              ),
          ],
        ),
        actions: [
          _LinkDot(app),
          // Pull to refresh needs a touch screen.
          if (kIsWeb)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: () => _refresh(context, app),
            ),
          if (wide)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New agent',
              onPressed: () => showNewAgentSheet(context),
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) => switch (v) {
              'ended' => app.setShowEnded(!app.showEnded),
              'keys' => showShortcuts(context),
              _ => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'ended', checked: app.showEnded, child: const Text('Show ended agents')),
              if (kIsWeb) const PopupMenuItem(value: 'keys', child: Text('Keyboard shortcuts')),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(children: [
              _SearchField(controller: search, focus: searchFocus, onSubmitted: onSearchSubmitted),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, icon: Icon(Icons.dns_outlined, size: 16), label: Text('By machine')),
                    ButtonSegment(value: true, icon: Icon(Icons.history, size: 16), label: Text('Recent')),
                  ],
                  selected: {app.recentView},
                  onSelectionChanged: (s) => app.setRecentView(s.first),
                ),
              ),
            ]),
          ),
        ),
      ),
      floatingActionButton: wide
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showNewAgentSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('New agent'),
            ),
      body: Column(
        children: [
          if (app.updateReady)
            MaterialBanner(
              leading: const Icon(Icons.system_update_alt),
              content: const Text('Roster was updated.'),
              actions: [TextButton(onPressed: reloadPage, child: const Text('Reload'))],
            ),
          if (app.haveSnapshot && app.link != Link.live)
            Delayed(
              delay: const Duration(seconds: 3),
              child: _OfflineBar(app: app, onRetry: () => _refresh(context, app)),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _refresh(context, app),
              child: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: body),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focus, required this.onSubmitted});

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: controller,
        focusNode: focus,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSubmitted(),
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: 'Search agents',
          isDense: true,
          filled: true,
          fillColor: cs.surfaceContainerHigh,
          prefixIcon: Icon(Icons.search, size: 20, color: cs.outline),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: controller.clear,
                )
              : kIsWeb && MediaQuery.sizeOf(context).width >= 600
                  ? const Padding(padding: EdgeInsets.all(11), child: Keycap('/'))
                  : null,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
        ),
      ),
    );
  }
}

/// The event stream: quiet while live, a word when it is not.
class _LinkDot extends StatelessWidget {
  const _LinkDot(this.app);

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final sc = statusColors(context);
    final (color, tip) = switch (app.link) {
      Link.live => (sc.done, 'Live: updates arrive as they happen'),
      Link.connecting => (sc.working, 'Connecting to the hub…'),
      Link.offline => (sc.blocked, 'Offline: ${app.linkError ?? 'no connection'}. Retrying by itself.'),
    };
    return Tooltip(
      message: tip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar({required this.app, required this.onRetry});

  final AppState app;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: cs.outline)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Reconnecting… the list may be behind${app.linkError == null ? '' : ' (${app.linkError})'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.color, required this.title, required this.count});

  final IconData icon;
  final Color color;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('$count', style: theme.textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _MachineHeader extends StatelessWidget {
  const _MachineHeader(this.machine, {required this.count});

  final Machine machine;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = cs.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(machine.reachable ? Icons.dns_outlined : Icons.cloud_off_outlined, size: 16, color: muted),
              const SizedBox(width: 8),
              Expanded(
                child: Row(children: [
                  Flexible(
                    child: Text(
                      machine.name,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: machine.reachable ? cs.onSurfaceVariant : muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (machine.local) ...[const SizedBox(width: 8), const Tag('hub')],
                ]),
              ),
              if (count > 0) Text('$count', style: theme.textTheme.labelMedium?.copyWith(color: muted)),
            ],
          ),
          if (!machine.reachable)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 2),
              child: Text(
                'Unreachable${machine.error == null ? '' : ': ${machine.error}'} · last known state',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// One agent: its status, name (the leads above it dimmed), role, how long
/// in this status, unread mail, an API error, and its subagents.
class AgentTile extends StatelessWidget {
  const AgentTile(this.agent,
      {super.key, this.selected = false, this.cursor = false, this.showMachine = false, this.indent = true});

  final Agent agent;
  final bool selected;
  final bool cursor;
  final bool showMachine;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sc = statusColors(context);
    final a = agent;
    final dim = a.stale != null || a.ended;
    final blocked = a.status == 'blocked' && !dim;
    final stalled = a.stalled != null && !a.ended ? a.stalled : null;
    final Color bg = selected
        ? cs.secondaryContainer
        : a.needsYou && !dim
            ? sc.blocked.withValues(alpha: theme.brightness == Brightness.dark ? 0.12 : 0.07)
            : Colors.transparent;
    final muted = cs.outline;
    final nameStyle = theme.textTheme.bodyLarge?.copyWith(
      fontWeight: FontWeight.w600,
      fontSize: 15,
      color: selected ? cs.onSecondaryContainer : cs.onSurface,
      height: 1.3,
    );
    final subs = a.ended ? const <Subagent>[] : a.subagents;
    final tile = Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: cursor ? BorderSide(color: cs.primary, width: 1.5) : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openAgent(a.id),
            // Right click (or a long press on a phone): park, start or kill it.
            onSecondaryTapUp: (d) => showAgentMenu(context, a, d.globalPosition),
            onLongPress: () {
              final box = context.findRenderObject() as RenderBox?;
              if (box != null) showAgentMenu(context, a, box.localToGlobal(box.size.center(Offset.zero)));
            },
            child: Opacity(
              opacity: dim ? 0.55 : 1,
              child: Padding(
                padding: EdgeInsets.fromLTRB(12 + (indent ? a.depth * 14.0 : 0), 9, 12, 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: const EdgeInsets.only(top: 1), child: StatusDot(a.status, size: 10.5)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text.rich(
                                  TextSpan(children: [
                                    if (a.parentPrefix.isNotEmpty)
                                      TextSpan(
                                        text: a.parentPrefix,
                                        style: nameStyle?.copyWith(fontWeight: FontWeight.w400, color: muted),
                                      ),
                                    TextSpan(text: a.leaf),
                                    if (showMachine)
                                      TextSpan(
                                        text: ' @${a.machine}',
                                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                                      ),
                                  ]),
                                  style: nameStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (a.temp) ...[const SizedBox(width: 6), const Tag('quick')],
                              const SizedBox(width: 8),
                              if (a.unread > 0) ...[UnreadPill(a.unread), const SizedBox(width: 8)],
                              if (a.statusAt != null)
                                Ago(a.statusAt!,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: blocked ? sc.blocked : muted,
                                      fontWeight: blocked ? FontWeight.w700 : null,
                                    )),
                            ],
                          ),
                          if (a.role != null && a.role!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                a.role!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: selected ? cs.onSecondaryContainer.withValues(alpha: 0.75) : cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                          if (stalled != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Row(children: [
                                Icon(Icons.warning_amber_rounded,
                                    size: 14, color: stalled.transient ? sc.working : sc.blocked),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    stalled.gaveUp
                                        ? 'API error (${stalled.error}); gave up resuming'
                                        : stalled.transient
                                            ? 'API error (${stalled.error}); resumes by itself'
                                            : 'API error (${stalled.error}); needs you',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: stalled.transient ? sc.working : sc.blocked,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          if (subs.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Column(children: [
                                for (final s in subs.take(3))
                                  Padding(padding: const EdgeInsets.only(top: 1), child: SubagentLine(s, dense: true)),
                                if (subs.length > 3)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('+${subs.length - 3} more subagents',
                                        style: theme.textTheme.bodySmall?.copyWith(color: muted, fontSize: 11.5)),
                                  ),
                              ]),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!kIsWeb) return tile;
    // Over a row the right click is ours, not the browser's.
    return MouseRegion(
      onEnter: (_) => BrowserContextMenu.disableContextMenu(),
      onExit: (_) => BrowserContextMenu.enableContextMenu(),
      child: tile,
    );
  }
}

/// The row's menu. A live agent: Park, Kill. A parked one: Start, Kill. A gone one: Resume.
Future<void> showAgentMenu(BuildContext context, Agent a, Offset at) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final live = !a.ended && !a.parked;
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(Rect.fromPoints(at, at), Offset.zero & overlay.size),
    items: [
      if (live) const PopupMenuItem(value: 'park', child: Text('Park')),
      if (a.parked) const PopupMenuItem(value: 'resume', child: Text('Start')),
      if (a.status == 'gone') const PopupMenuItem(value: 'resume', child: Text('Resume')),
      if (live || a.parked) const PopupMenuItem(value: 'kill', child: Text('Kill…')),
    ],
  );
  if (action == null || !context.mounted) return;
  final client = AppScope.read(context).client;
  if (client == null) return;
  try {
    switch (action) {
      case 'park':
        await client.park(a.id);
        if (context.mounted) showError(context, 'Parked ${a.name}');
      case 'resume':
        await client.resume(a.id);
        if (context.mounted) showError(context, '${a.parked ? 'Starting' : 'Resuming'} ${a.name}…');
      case 'kill':
        if (!await confirmKill(context, a.name, parked: a.parked)) return;
        await client.kill(a.id);
        if (context.mounted) showError(context, 'Killed ${a.name}');
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        children: [
          const Bar(width: 120, height: 9),
          for (var k = 0; k < 9; k++)
            Padding(
              padding: EdgeInsets.only(top: k == 0 ? 18 : 22, left: k % 3 == 1 ? 14 : 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Bar(width: 12, height: 12),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Bar(width: 90.0 + (k * 37) % 80, height: 11),
                  const SizedBox(height: 8),
                  Bar(width: 160.0 + (k * 53) % 90, height: 8),
                ]),
              ]),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.detail, this.action, this.onAction});

  final IconData icon;
  final String title;
  final String detail;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 32),
      children: [
        Icon(icon, size: 40, color: cs.outline),
        const SizedBox(height: 14),
        Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(detail,
            textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        if (action != null) ...[
          const SizedBox(height: 16),
          Center(child: FilledButton.tonal(onPressed: onAction, child: Text(action!))),
        ],
      ],
    );
  }
}

/// The pane beside the list when no agent is open.
class _NoAgent extends StatelessWidget {
  const _NoAgent({super.key, required this.onOpen});

  final void Function(String agent) onOpen;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final needs = app.snapshot.agents.where((a) => a.needsYou && a.stale == null).toList();
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined, size: 44, color: cs.outlineVariant),
              const SizedBox(height: 14),
              Text(
                needs.isEmpty ? 'Nothing needs you right now' : 'Pick an agent',
                style: theme.textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (needs.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final a in needs.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => onOpen(a.id),
                      icon: StatusDot(a.status, size: 9),
                      label: Text('${a.name} needs you'),
                    ),
                  ),
              ],
              if (kIsWeb) ...[
                const SizedBox(height: 28),
                const ShortcutHints([
                  (['j', 'k'], 'move'),
                  (['Enter'], 'open'),
                  (['/'], 'search'),
                  (['Esc'], 'back'),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showShortcuts(BuildContext context) => showDialog<void>(
      context: context,
      builder: (c) {
        final theme = Theme.of(c);
        Widget row(List<String> keys, String what) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                SizedBox(
                  width: 130,
                  child: Wrap(spacing: 4, children: [for (final k in keys) Keycap(k)]),
                ),
                Expanded(child: Text(what, style: theme.textTheme.bodyMedium)),
              ]),
            );
        return AlertDialog(
          title: const Text('Keyboard shortcuts'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              row(['/'], 'Search agents'),
              row(['j', 'k'], 'Next or previous agent (also ↓ ↑)'),
              row(['Enter'], 'Open; then to its composer or dialog'),
              row(['1', '…', '9'], 'Pick a dialog option (dialog focused)'),
              row(['←', '→'], 'Back and Next in a form'),
              row(['Enter'], 'Send (Shift+Enter: new line)'),
              row(['Esc'], 'Leave the text field, then close'),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
        );
      },
    );
