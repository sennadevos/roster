import 'package:flutter/material.dart';

import 'app.dart';
import 'push/push.dart';
import 'state/app_state.dart';
import 'state/store.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureStore();
  await Push.init(store);
  // Started by the push distributor to deliver a message: no UI.
  if (args.contains('--unifiedpush-bg')) return;

  final state = AppState(store: store, push: Push(store));
  WidgetsBinding.instance.addObserver(state);
  Push.onOpen = openAgent;
  runApp(RosterApp(state: state));
  await state.load();
  final launched = await Push.launchAgent();
  if (launched != null && state.paired) openAgent(launched);
}
