import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roster/api/hub_client.dart';
import 'package:roster/app.dart';
import 'package:roster/screens/agents_screen.dart';
import 'package:roster/state/app_state.dart';
import 'package:roster/state/store.dart';

import 'fake_hub.dart';

/// localStorage in memory, or one that refuses everything.
class MapStorage implements StringStorage {
  MapStorage({this.broken = false});

  final bool broken;
  final Map<String, String> items = {};

  void _check() {
    if (broken) throw StateError('storage disabled');
  }

  @override
  String? getItem(String key) {
    _check();
    return items[key];
  }

  @override
  void setItem(String key, String value) {
    _check();
    items[key] = value;
  }

  @override
  void removeItem(String key) {
    _check();
    items.remove(key);
  }
}

const agents = {
  'agents': [
    {'name': 'infra', 'role': 'servers', 'status': 'idle', 'unread': 0, 'machine': 'srv', 'agent': 'infra@srv'},
  ],
  'machines': [
    {'name': 'srv', 'local': true, 'reachable': true, 'error': null},
  ],
};

void main() {
  test('the hub of a web page is the page origin, or its directory', () {
    expect(hubUrlForPage(Uri.parse('http://10.137.42.3:8790/')).toString(), 'http://10.137.42.3:8790');
    expect(hubUrlForPage(Uri.parse('http://10.137.42.3:8790/#/agents?x=1')).toString(), 'http://10.137.42.3:8790');
    expect(hubUrlForPage(Uri.parse('http://10.137.42.3:8790/index.html?a=b')).toString(), 'http://10.137.42.3:8790');
    expect(hubUrlForPage(Uri.parse('https://roster.example/app/')).toString(), 'https://roster.example/app');
  });

  test('LocalStore keeps prefixed strings, removes on null, survives a refusing storage', () async {
    final storage = MapStorage();
    final store = LocalStore(storage);
    expect(await store.read(Keys.token), isNull);
    await store.write(Keys.token, 'tok');
    expect(storage.items, {'roster.token': 'tok'});
    expect(await LocalStore(storage).read(Keys.token), 'tok');
    await store.write(Keys.token, null);
    expect(storage.items, isEmpty);

    final broken = LocalStore(MapStorage(broken: true));
    expect(await broken.read(Keys.token), isNull);
    await broken.write(Keys.token, 'tok');
    expect(await broken.read(Keys.token), 'tok');
    await broken.write(Keys.token, null);
    expect(await broken.read(Keys.token), isNull);
  });

  testWidgets('with a fixed hub, pairing asks only for the code and a name', (tester) async {
    final hub = FakeHub({
      'POST /v1/pair': (body, _) => {'token': 'tok-1', 'device_id': 'dev-1'},
    });
    final store = MemoryStore()..values[Keys.hubUrl] = 'https://elsewhere.example';
    final page = hubUrlForPage(Uri.parse('http://10.137.42.3:8790/'));
    final state = AppState(store: store, clientFor: hub.client, fixedHubUrl: page);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();

    expect(state.hubUrl, page);
    expect(find.text('Hub URL'), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.enterText(find.byKey(const Key('code')), 'abcd2345');
    await tester.tap(find.text('Pair'));
    await tester.pump();
    await tester.pump();
    expect(hub.requests.first.url.toString(), 'http://10.137.42.3:8790/v1/pair');
    expect(store.values[Keys.token], 'tok-1');
    expect(store.values[Keys.hubUrl], 'http://10.137.42.3:8790');

    // Changing the hub is not possible; it stays the page's.
    await state.setHubUrl('https://other.example');
    expect(state.hubUrl, page);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });

  testWidgets('a wide window shows the open agent beside the list, a narrow one on top', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final hub = FakeHub({
      'GET /v1/transcript': (_, _) => {'agent': 'infra@srv', 'session_id': 's', 'messages': [], 'next': 1},
    });
    final store = MemoryStore()..values[Keys.token] = 'tok-1';
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();
    hub.sendAgents(agents);
    await tester.pump();
    await tester.pump();

    expect(find.text('Nothing needs you right now'), findsOneWidget);
    await tester.tap(find.text('infra'));
    await tester.pumpAndSettle();
    // Both at once: the row in the list and the conversation with its composer.
    expect(find.text('Roster'), findsOneWidget);
    expect(find.text('Message infra'), findsOneWidget);
    expect(AppState.onScreen, 'infra@srv');
    expect(tester.widget<AgentTile>(find.byType(AgentTile)).selected, isTrue);

    // Narrow: the agent moves onto a page of its own over the list.
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(find.text('Roster'), findsNothing);
    expect(find.text('Message infra'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    // Back to the list, and wide again: nothing is open.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(selectedAgent.value, isNull);
    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();
    expect(find.text('Nothing needs you right now'), findsOneWidget);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });
}
