import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roster/app.dart';
import 'package:roster/state/app_state.dart';
import 'package:roster/state/store.dart';
import 'package:roster/widgets/status.dart';

import 'fake_hub.dart';

void main() {
  testWidgets('pairing stores the token and shows the live agents', (tester) async {
    String? sentCode;
    final hub = FakeHub({
      'POST /v1/pair': (body, _) {
        sentCode = body['code'] as String;
        return body['code'] == 'ABCD2345' ? {'token': 'tok-1', 'device_id': 'dev-9'} : (403, 'bad code');
      },
    });
    final store = MemoryStore();
    final state = AppState(store: store, clientFor: hub.client);
    await tester.pumpWidget(RosterApp(state: state));
    await state.load();
    await tester.pump();

    expect(find.text('Pair with a hub'), findsOneWidget);
    expect(find.text('https://roster.sennadevos.com'), findsOneWidget);

    // A wrong code shows the hub's error and stores nothing.
    await tester.enterText(find.byKey(const Key('code')), 'zzzz9999');
    await tester.tap(find.text('Pair'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Bad code.'), findsOneWidget);
    expect(store.values[Keys.token], isNull);

    await tester.enterText(find.byKey(const Key('code')), 'abcd2345');
    await tester.tap(find.text('Pair'));
    await tester.pump();
    await tester.pump();
    expect(sentCode, 'ABCD2345');
    expect(store.values[Keys.token], 'tok-1');
    expect(store.values[Keys.deviceId], 'dev-9');
    expect(store.values[Keys.hubUrl], 'https://roster.sennadevos.com');
    expect(find.text('Roster'), findsOneWidget);

    hub.sendAgents({
      'agents': [
        {'name': 'infra', 'role': 'servers', 'status': 'blocked', 'unread': 3, 'machine': 'srv', 'agent': 'infra@srv',
          'stalled': {'error': 'billing_error'}},
      ],
      'machines': [
        {'name': 'srv', 'local': true, 'reachable': true, 'error': null},
        {'name': 'laptop', 'local': false, 'reachable': false, 'error': 'timed out'},
      ],
    });
    await tester.pump();
    await tester.pump();
    expect(state.link, Link.live);
    // Blocked: pinned under Needs you, with its machine.
    expect(find.text('Needs you'), findsOneWidget);
    expect(find.textContaining('infra'), findsOneWidget);
    expect(find.textContaining('@srv'), findsOneWidget);
    expect(find.text('servers'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is StatusDot && w.status == 'blocked'), findsOneWidget);
    expect(find.text('API error (billing_error); needs you'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('Unreachable: timed out'), findsOneWidget);

    state.dispose();
    await hub.events.close();
    await tester.pump();
  });
}
