import 'package:flutter/material.dart';

import 'api/hub_client.dart';
import 'app.dart';
import 'platform/platform.dart';
import 'state/app_state.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = platformStore();
  await Push.init(store);
  // Started by the push distributor to deliver a message: no UI.
  if (args.contains('--unifiedpush-bg')) return;

  final state = AppState(
    store: store,
    push: Push(store),
    clientFor: (base, token) => HubClient(base, token: token, streamClient: streamingClient),
    fixedHubUrl: pageHubUrl(),
    // Without push, the event stream is the only way news arrives.
    keepStreamInBackground: !pushAvailable,
  );
  WidgetsBinding.instance.addObserver(state);
  Push.onOpen = openAgent;
  runApp(RosterApp(state: state));
  await state.load();
  final launched = await Push.launchAgent();
  if (launched != null && state.paired) openAgent(launched);
}
