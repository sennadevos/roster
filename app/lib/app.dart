import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/agent_screen.dart';
import 'screens/agents_screen.dart';
import 'screens/pair_screen.dart';
import 'state/app_state.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// The agent that is open: beside the list in the split view, on top of it
/// otherwise.
final selectedAgent = ValueNotifier<String?>(null);

/// Whether the agents screen shows the list and the open agent side by side
/// (a wide window); kept up to date by AgentsScreen.
bool splitView = false;

/// Width from which the list and the agent sit side by side.
const splitViewWidth = 840.0;

const agentRouteName = 'agent';

/// Opens an agent, from a row, a notification or a new agent.
void openAgent(String agent) {
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  nav.popUntil((r) => r.isFirst);
  selectedAgent.value = agent;
  if (!splitView) pushAgent(nav, agent);
}

/// The agent as a page of its own, on a narrow window. Going back closes it.
void pushAgent(NavigatorState nav, String agent) {
  unawaited(nav
      .push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: agentRouteName),
        builder: (_) => AgentScreen(agent: agent),
      ))
      .then((_) {
    // Not when the window got wide and the agent moved beside the list.
    if (!splitView && selectedAgent.value == agent) selectedAgent.value = null;
  }));
}

/// Hands the AppState down; widgets that call [of] rebuild when it changes.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Without subscribing, for initState and callbacks.
  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

ThemeData _theme(Brightness b) => ThemeData(
      colorSchemeSeed: const Color(0xFF00796B),
      brightness: b,
      visualDensity: VisualDensity.standard,
    );

class RosterApp extends StatefulWidget {
  const RosterApp({super.key, required this.state});

  final AppState state;

  @override
  State<RosterApp> createState() => _RosterAppState();
}

class _RosterAppState extends State<RosterApp> {
  bool _wasPaired = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  /// Back to the root when the device gets unpaired, whatever is open.
  void _onState() {
    final paired = widget.state.paired;
    if (_wasPaired && !paired) {
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
      selectedAgent.value = null;
    }
    _wasPaired = paired;
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'Roster',
        navigatorKey: navigatorKey,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final s = widget.state;
            if (!s.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
            return s.paired ? const AgentsScreen() : const PairScreen();
          },
        ),
      ),
    );
  }
}
