import 'dart:convert';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roster/api/hub_client.dart';
import 'package:roster/app.dart';
import 'package:roster/models/agent.dart';
import 'package:roster/models/misc.dart';
import 'package:roster/screens/agent_screen.dart';
import 'package:roster/screens/agents_screen.dart';
import 'package:roster/state/app_state.dart';
import 'package:roster/state/conversation.dart';
import 'package:roster/state/store.dart';
import 'package:roster/theme.dart';
import 'package:roster/widgets/bits.dart';
import 'package:roster/widgets/status.dart';

import 'fake_hub.dart';

Map<String, dynamic> row(String name, String machine, String status, {Map<String, dynamic> extra = const {}}) => {
      'name': name, 'machine': machine, 'status': status, 'agent': '$name@$machine', 'unread': 0,
      'local': machine == 'srv', 'status_at': '2026-10-20T10:00:00+0200', ...extra,
    };

const machines = [
  {'name': 'srv', 'local': true, 'reachable': true, 'error': null},
  {'name': 'laptop', 'local': false, 'reachable': true, 'error': null},
];

void main() {
  test('row extras: status time, model, subagents, needs you, the name in parts', () {
    final a = Agent.fromJson(row('rator-firmware/ui', 'srv', 'idle', extra: {
      'model': 'opus', 'effort': 'high', 'temp': true,
      'subagents': [
        {'id': 'x', 'type': 'Explore', 'label': 'find the parser', 'status': 'running', 'started_at': '2026-10-20T10:01:00+0200'},
        {'id': 'y', 'type': 'general-purpose', 'label': 'write tests', 'status': 'done', 'ended_at': '2026-10-20T10:02:00+0200'},
      ],
    }));
    expect(a.statusAt!.toUtc(), DateTime.utc(2026, 10, 20, 8));
    expect((a.model, a.effort, a.temp), ('opus', 'high', true));
    expect(a.subagents.map((s) => (s.type, s.running)), [('Explore', true), ('general-purpose', false)]);
    expect((a.leaf, a.parentPrefix, a.depth), ('ui', 'rator-firmware/', 1));
    expect(a.needsYou, isFalse);

    expect(Agent.fromJson(row('a', 'm', 'blocked')).needsYou, isTrue);
    // A transient API error resumes by itself; others need the user.
    expect(Agent.fromJson(row('a', 'm', 'idle', extra: {'stalled': {'error': 'overloaded'}})).needsYou, isFalse);
    expect(Agent.fromJson(row('a', 'm', 'idle', extra: {'stalled': {'error': 'billing_error'}})).needsYou, isTrue);
    expect(Agent.fromJson(row('a', 'm', 'idle', extra: {'stalled': {'error': 'overloaded', 'gave_up': true}})).needsYou,
        isTrue);
    expect(Agent.fromJson(row('a', 'm', 'gone', extra: {'stalled': {'error': 'billing_error'}})).needsYou, isFalse);
  });

  test('relative and clock times', () {
    final now = DateTime(2026, 10, 20, 15, 30);
    expect(ago(now.subtract(const Duration(seconds: 10)), now), 'now');
    expect(ago(now.subtract(const Duration(minutes: 4)), now), '4m');
    expect(ago(now.subtract(const Duration(hours: 3)), now), '3h');
    expect(ago(now.subtract(const Duration(days: 2)), now), '2d');
    expect(clockTime(DateTime(2026, 10, 20, 9, 5), now), '09:05');
    expect(clockTime(DateTime(2026, 10, 19, 9, 5), now), 'Yesterday 09:05');
    expect(clockTime(DateTime(2026, 9, 2, 9, 5), now), '2 Sep 09:05');
  });

  test('hub errors read as sentences', () {
    expect(friendlyError(const HubException(409, 'roster: a dialog is open')), 'A dialog is open.');
    expect(friendlyError(const HubException(0, 'cannot reach the hub: x')), startsWith('Cannot reach the hub.'));
  });

  test('a sent prompt shows as pending until the transcript has it; a refused one is taken back', () async {
    final transcript = <Map<String, dynamic>>[
      {'i': 1, 'role': 'assistant', 'text': 'hello'},
    ];
    var refuse = false;
    final hub = FakeHub({
      'GET /v1/transcript': (_, q) {
        final after = int.tryParse(q['after'] ?? '');
        final rows = after == null ? transcript : transcript.where((m) => (m['i'] as int) > after).toList();
        return {'agent': 'a@m', 'session_id': 's', 'messages': rows, 'next': transcript.last['i'] as int};
      },
      'POST /v1/prompt': (body, _) {
        if (refuse) return (409, 'roster: a dialog is open');
        transcript.add({'i': transcript.length + 1, 'role': 'user', 'text': body['text']});
        return {'ok': true};
      },
    });
    final c = Conversation(hub.client(Uri.parse('https://hub'), 'tok-1'), 'a@m');
    await c.loadTail();
    final sent = c.send('  do the thing ');
    expect(c.pending, ['do the thing']);
    await sent;
    expect(c.pending, isEmpty);
    expect(c.messages.last.text, 'do the thing');

    refuse = true;
    await expectLater(c.send('again'), throwsA(isA<HubException>()));
    expect(c.pending, isEmpty);
  });

  testWidgets('keys: j/k open the next and previous agent beside the list, / searches, Esc clears', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final hub = FakeHub({
      'GET /v1/transcript': (_, q) => {'agent': q['agent'], 'session_id': 's', 'messages': [], 'next': 1},
      'GET /v1/screen': (_, q) => {'agent': q['agent'], 'status': 'blocked', 'text': '', 'dialog': null},
    });
    final store = MemoryStore()..values[Keys.token] = 'tok-1';
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();
    hub.sendAgents({
      'agents': [
        row('alpha', 'srv', 'idle'),
        row('beta', 'srv', 'done', extra: {
          'subagents': [{'id': 's1', 'type': 'Explore', 'label': 'look around', 'status': 'done'}],
        }),
        row('gamma', 'laptop', 'blocked'),
      ],
      'machines': machines,
    });
    await tester.pump();
    await tester.pumpAndSettle();

    // The blocked one comes first, under Needs you; the window title counts it.
    expect(find.text('Needs you'), findsOneWidget);
    expect(tester.widget<Title>(find.byType(Title).last).title, '(1) Roster');
    // A subagent is a line under its agent, not an agent.
    expect(find.byType(AgentTile), findsNWidgets(3));
    expect(find.byType(SubagentLine), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(selectedAgent.value, 'gamma@laptop');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(selectedAgent.value, 'alpha@srv');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selectedAgent.value, 'beta@srv');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(selectedAgent.value, 'alpha@srv');

    // Enter goes into the open agent: its composer.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'composer');
    // Esc leaves the field; then j moves again instead of typing.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(selectedAgent.value, 'beta@srv');

    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search');
    await tester.enterText(find.byType(TextField).first, 'gam');
    await tester.pumpAndSettle();
    expect(find.byType(AgentTile), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AgentTile), findsNWidgets(3));

    // Esc with nothing to clear closes the open agent.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(selectedAgent.value, isNull);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });

  testWidgets('dialog card: a number key picks, a tick box flips at once', (tester) async {
    final picked = <List<String>>[];
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final screen = Screen.fromJson(jsonDecode('''
      {"status": "blocked", "text": "", "dialog": {"title": "Which ones?", "multi": true,
        "options": [{"key": "1", "label": "Hub", "checked": false}, {"key": "2", "label": "Devices", "checked": false}],
        "tabs": [{"label": "Sections", "done": false}, {"label": "Submit", "done": false}],
        "actions": [{"label": "Back", "keys": ["Left"]}, {"label": "Next", "keys": ["Right"]}]}}''') as Map<String, dynamic>);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: DialogCard(
          screen: screen,
          focusNode: focus,
          onPick: (o) async => picked.add(o.keys),
          onRefresh: () async {},
        ),
      ),
    ));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(picked, [['2']]);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(picked.last, ['Right']);
    await tester.tap(find.text('Back'));
    await tester.pump();
    expect(picked.last, ['Left']);
  });

  testWidgets('right click on a row: park or kill a live agent, start or kill a parked one', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final hub = FakeHub({
      'POST /v1/park': (b, _) { calls.add('park ${b['agent']}'); return {'ok': true}; },
      'POST /v1/resume': (b, _) { calls.add('resume ${b['agent']}'); return {'ok': true}; },
      'POST /v1/kill': (b, _) { calls.add('kill ${b['agent']}'); return {'ok': true}; },
    });
    final store = MemoryStore()..values[Keys.token] = 'tok-1';
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();
    hub.sendAgents({
      'agents': [row('alpha', 'srv', 'idle'), row('beta', 'srv', 'parked')],
      'machines': machines,
    });
    await tester.pump();
    await tester.pumpAndSettle();

    Future<void> rightClick(String name) async {
      await tester.tap(find.textContaining(name).first, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
    }

    await rightClick('alpha');
    expect(find.text('Park'), findsOneWidget);
    expect(find.text('Kill…'), findsOneWidget);
    expect(find.text('Start'), findsNothing);
    await tester.tap(find.text('Park'));
    await tester.pumpAndSettle();
    expect(calls, ['park alpha@srv']);

    // Parked agents sit in a folded section.
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    await rightClick('beta');
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Park'), findsNothing);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(calls.last, 'resume beta@srv');

    // Kill asks first.
    await rightClick('beta');
    await tester.tap(find.text('Kill…'));
    await tester.pumpAndSettle();
    expect(find.text('Kill beta?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Kill'));
    await tester.pumpAndSettle();
    expect(calls.last, 'kill beta@srv');

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });

  testWidgets('right click on another row keeps the open agent beside the list intact', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final hub = FakeHub({
      'GET /v1/transcript': (_, q) => {'agent': q['agent'], 'session_id': 's', 'messages': [
            {'i': 1, 'at': '2026-10-20T10:00:00+0200', 'role': 'user', 'text': 'hello there'},
          ], 'next': 2},
      'GET /v1/screen': (_, q) => {'agent': q['agent'], 'status': 'idle', 'text': '', 'dialog': null},
    });
    final store = MemoryStore()..values[Keys.token] = 'tok-1';
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();
    hub.sendAgents({'agents': [row('alpha', 'srv', 'idle'), row('beta', 'srv', 'idle')], 'machines': machines});
    await tester.pump();
    await tester.pumpAndSettle();
    openAgent('alpha@srv');
    await tester.pumpAndSettle();
    expect(find.text('hello there'), findsOneWidget);
    // No SelectionArea over the conversation: Flutter's SelectableRegion fails
    // a null check when rows are torn down mid-turn, and the release build
    // then paints the chat gray. Message text selects by itself instead.
    expect(find.byType(SelectionArea), findsNothing);
    expect(find.byType(SelectableText), findsWidgets);

    await tester.tap(find.textContaining('beta').first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Park'), findsOneWidget);
    expect(find.text('hello there'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('hello there'), findsOneWidget);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });

  testWidgets('an SDK agent switches model and effort and is interrupted from its header', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final hub = FakeHub({
      'GET /v1/transcript': (_, q) => {'agent': q['agent'], 'session_id': 's', 'messages': [], 'next': 0},
      'GET /v1/screen': (_, q) => {'agent': q['agent'], 'status': 'working', 'text': '', 'dialog': null},
      'POST /v1/model': (b, _) { calls.add('model ${b['model']}'); return {'ok': true, 'model': b['model']}; },
      'POST /v1/effort': (b, _) { calls.add('effort ${b['effort']}'); return {'ok': true, 'effort': b['effort']}; },
      'POST /v1/interrupt': (b, _) { calls.add('interrupt ${b['agent']}'); return {'ok': true, 'interrupted': true}; },
    });
    final store = MemoryStore()..values[Keys.token] = 'tok-1';
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();
    hub.sendAgents({
      'agents': [
        row('native', 'srv', 'working', extra: {'harness': 'sdk', 'model': 'opus', 'effort': 'high'}),
        row('classic', 'srv', 'idle', extra: {'harness': 'claude', 'model': 'opus'}),
      ],
      'machines': machines,
    });
    await tester.pump();
    await settle(tester);
    openAgent('native@srv');
    await settle(tester);

    await tester.tap(find.text('effort high'));
    await settle(tester);
    await tester.tap(find.text('max'));
    await settle(tester);
    expect(calls, ['effort max']);

    await tester.tap(find.byTooltip('Model: tap to switch'));
    await settle(tester);
    await tester.tap(find.text('sonnet').last);
    await settle(tester);
    expect(calls.last, 'model sonnet');

    await tester.tap(find.byTooltip('Interrupt'));
    await settle(tester);
    expect(calls.last, 'interrupt native@srv');

    // A Claude Code agent shows its model, with nothing to switch.
    openAgent('classic@srv');
    await settle(tester);
    expect(find.byTooltip('Model: tap to switch'), findsNothing);
    expect(find.byTooltip('Interrupt'), findsNothing);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });


  testWidgets('capture: Jev unsure, a candidate picked, sent there', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final asked = <Map<String, dynamic>>[];
    final hub = FakeHub({
      'POST /v1/capture': (b, _) {
        asked.add(b);
        if (b['to'] == null && b['new'] == null) {
          return {'action': 'ask', 'choice': 'infra@srv', 'confidence': 0.5, 'candidates': [
            {'agent': 'infra@srv', 'p': 0.5}, {'agent': 'new', 'p': 0.49},
          ]};
        }
        return {'action': 'sent', 'agent': b['to'], 'choice': b['to'], 'confidence': 1.0, 'candidates': []};
      },
    });
    final store = MemoryStore()..values[Keys.token] = 'tok-1';
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();
    hub.sendAgents({'agents': [row('infra', 'srv', 'idle')], 'machines': machines});
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Capture: say or type a thought, Jev routes it'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'is the server disk failing?');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(asked.single['text'], 'is the server disk failing?');
    expect(find.textContaining('Jev is not sure'), findsOneWidget);

    await tester.tap(find.textContaining('infra · 50%'));
    await tester.pumpAndSettle();
    expect(asked.last['to'], 'infra@srv');
    expect(find.text('Sent to infra@srv'), findsWidgets);
    expect(find.textContaining('Jev is not sure'), findsNothing);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });
}

/// For screens with a spinner, which never settles: pump long enough for
/// menus, dialogs and requests to be done.
Future<void> settle(WidgetTester tester) async {
  for (var k = 0; k < 6; k++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}
