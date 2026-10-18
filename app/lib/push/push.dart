import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../api/hub_client.dart';
import '../models/misc.dart';
import '../state/app_state.dart';
import '../state/store.dart';

/// UnifiedPush (through the ntfy app on the phone) in, local notifications out.
///
/// [init] runs in the app and also when the distributor starts the app in the
/// background for a message (`--unifiedpush-bg`), so everything it needs
/// comes from the store, not from the widget tree.
class Push implements PushControl {
  Push(this.store);

  final Store store;

  static final _notes = FlutterLocalNotificationsPlugin();

  /// Where a tapped notification goes; set by the app.
  static void Function(String agent)? onOpen;

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'agents',
      'Agents',
      channelDescription: 'An agent is blocked, asking, finished or stuck on an API error',
      importance: Importance.high,
      priority: Priority.high,
    ),
  );

  static Future<void> init(Store store) async {
    await _notes.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: (r) {
        final agent = r.payload;
        if (agent != null && agent.isNotEmpty) onOpen?.call(agent);
      },
    );
    await UnifiedPush.initialize(
      onNewEndpoint: (endpoint, _) => unawaited(_tellHub(store, endpoint.url)),
      onUnregistered: (_) => unawaited(_tellHub(store, null)),
      onMessage: (message, _) => unawaited(_show(store, message)),
    );
  }

  /// The agent of the notification that started the app, if one did.
  static Future<String?> launchAgent() async {
    final details = await _notes.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return details.notificationResponse?.payload;
  }

  static Future<void> _tellHub(Store store, String? endpoint) async {
    await store.write(Keys.pushEndpoint, endpoint);
    final url = await store.read(Keys.hubUrl);
    final token = await store.read(Keys.token);
    if (url == null || token == null) return;
    final client = HubClient(normalizeHubUrl(url), token: token);
    try {
      await client.setPush(endpoint);
    } on HubException catch (e) {
      debugPrint('roster: could not give the hub the push endpoint: $e');
    } finally {
      client.close();
    }
  }

  static Future<void> _show(Store store, PushMessage message) async {
    if (await store.read(Keys.notifications) == 'off') return;
    // The hub posts plain JSON to the endpoint, so the content arrives as sent
    // (`decrypted` is false: there was no Web Push encryption to undo).
    final p = PushPayload.tryParse(message.content);
    if (p == null) return;
    final foreground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (foreground && AppState.onScreen == p.agent) return;
    await _notes.show(id: notificationId(p.agent), title: p.title, body: p.body, notificationDetails: _details, payload: p.agent);
  }

  /// One notification per agent: a newer one replaces the older.
  static int notificationId(String agent) {
    var h = 0x811c9dc5;
    for (final c in agent.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  @override
  Future<String?> enable() async {
    await _notes
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    if (!await UnifiedPush.tryUseCurrentOrDefaultDistributor()) {
      final found = await UnifiedPush.getDistributors();
      if (found.isEmpty) return 'No UnifiedPush distributor on this phone. Install the ntfy app.';
      await UnifiedPush.saveDistributor(found.firstWhere((d) => d.contains('ntfy'), orElse: () => found.first));
    }
    await UnifiedPush.register();
    return null;
  }

  @override
  Future<void> disable(HubClient? client) async {
    await UnifiedPush.unregister();
    await store.write(Keys.pushEndpoint, null);
    await client?.setPush(null);
  }

  @override
  Future<void> clear(String agent) => _notes.cancel(id: notificationId(agent));
}
