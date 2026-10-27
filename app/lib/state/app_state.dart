import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';

import '../api/hub_client.dart';
import '../models/agent.dart';
import 'conversation.dart';
import 'store.dart';

enum Link { offline, connecting, live }

/// What the app does about push; the real one is in push/push.dart.
abstract class PushControl {
  /// Registers with the distributor; the endpoint reaches the hub when it comes.
  /// Answers a reason when push cannot be turned on.
  Future<String?> enable();

  /// Unregisters and tells the hub to stop.
  Future<void> disable(HubClient? client);

  /// Removes the notification for an agent that is now on screen.
  Future<void> clear(String agent);
}

class NoPush implements PushControl {
  const NoPush();

  @override
  Future<String?> enable() async => null;

  @override
  Future<void> disable(HubClient? client) async {}

  @override
  Future<void> clear(String agent) async {}
}

/// What the app calls the device it runs on.
const deviceNoun = kIsWeb ? 'browser' : 'phone';

/// The app's state: pairing, the agents list and the live event stream.
/// Screens rebuild from it with ListenableBuilder (see AppScope).
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    required this.store,
    this.push = const NoPush(),
    HubClient Function(Uri base, String? token)? clientFor,
    this.fixedHubUrl,
    this.keepStreamInBackground = false,
  })  : _clientFor = clientFor ?? ((base, token) => HubClient(base, token: token)),
        hubUrl = fixedHubUrl ?? normalizeHubUrl(defaultHubUrl);

  final Store store;
  final PushControl push;
  final HubClient Function(Uri base, String? token) _clientFor;

  /// The hub, when it is not the user's choice: on web, the hub that served
  /// the page (the API is same-origin only).
  final Uri? fixedHubUrl;

  /// Keep the event stream while the app is in the background, for when no
  /// push covers that (web).
  final bool keepStreamInBackground;

  bool get hubLocked => fixedHubUrl != null;

  /// The agent whose screen is open, so its pushes can be dropped. Static
  /// because the push callback runs outside the widget tree.
  static String? onScreen;

  bool loaded = false;
  Uri hubUrl;
  HubClient? client;
  String? deviceId;
  bool notifications = true;
  String? pushProblem;
  bool showEnded = false;

  /// The agent list by machine, or everything by last activity.
  bool recentView = false;

  /// On web: the hub now serves a newer build of this app than the one running.
  bool updateReady = false;
  String? _webBuild;

  /// Asks the hub which web build it serves; a change means this page is old.
  Future<void> checkForUpdate() async {
    final c = client;
    if (!kIsWeb || c == null || updateReady) return;
    try {
      final web = (await c.version())['web'];
      if (web is! String) return;
      if (_webBuild == null) {
        _webBuild = web;
      } else if (web != _webBuild) {
        updateReady = true;
        notifyListeners();
      }
    } catch (_) {
      // The hub being away is shown elsewhere.
    }
  }

  /// Why the app went back to the pair screen, when it was not the user.
  String? unpairedReason;

  AgentsSnapshot snapshot = const AgentsSnapshot();
  bool haveSnapshot = false;
  Link link = Link.offline;
  String? linkError;

  bool get paired => client != null;

  /// Light, dark or the system's; its own notifier, so changing it rebuilds
  /// the app's theme without every agents event doing so.
  final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

  /// Agents waiting on the user, for the window title.
  int get needsYou => snapshot.agents.where((a) => a.needsYou && a.stale == null).length;

  /// The last few conversations opened, kept so going back to an agent shows
  /// it at once and only fetches what is new.
  final Map<String, Conversation> _conversations = {};
  static const _keepConversations = 12;

  Conversation conversation(String agent) {
    var c = _conversations.remove(agent);
    c ??= Conversation(client!, agent);
    _conversations[agent] = c;
    while (_conversations.length > _keepConversations) {
      final oldest = _conversations.keys.first;
      _conversations.remove(oldest)!.dispose();
    }
    return c;
  }

  void _dropConversations() {
    for (final c in _conversations.values) {
      c.dispose();
    }
    _conversations.clear();
  }

  Future<void> setRecentView(bool on) async {
    recentView = on;
    notifyListeners();
    await store.write(Keys.listView, on ? 'recent' : 'machines');
  }

  /// On a wide window: the agent list folded away, the open agent full width.
  bool listHidden = false;

  Future<void> setListHidden(bool hidden) async {
    listHidden = hidden;
    notifyListeners();
    await store.write(Keys.listHidden, hidden ? 'yes' : 'no');
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await store.write(Keys.theme, mode.name);
  }

  int _gen = 0;
  String? _lastEventId;
  Completer<void>? _wake;
  StreamSubscription<Object?>? _sub;
  Completer<Object?>? _streamDone;

  Future<void> load() async {
    final url = hubLocked ? null : await store.read(Keys.hubUrl);
    if (url != null) hubUrl = normalizeHubUrl(url);
    final token = await store.read(Keys.token);
    deviceId = await store.read(Keys.deviceId);
    notifications = (await store.read(Keys.notifications)) != 'off';
    recentView = (await store.read(Keys.listView)) == 'recent';
    listHidden = (await store.read(Keys.listHidden)) == 'yes';
    final theme = await store.read(Keys.theme);
    themeMode.value = ThemeMode.values.where((m) => m.name == theme).firstOrNull ?? ThemeMode.system;
    if (token != null) client = _clientFor(hubUrl, token);
    loaded = true;
    notifyListeners();
    if (paired) {
      _start();
      if (notifications) unawaited(_enablePush());
    }
  }

  /// [url] is ignored when the hub is fixed.
  Future<void> pair(String url, String code, String deviceName) async {
    final base = fixedHubUrl ?? normalizeHubUrl(url);
    final (token, id) = await _clientFor(base, null).pair(code.trim().toUpperCase(), deviceName.trim());
    hubUrl = base;
    deviceId = id;
    await store.write(Keys.hubUrl, base.toString());
    await store.write(Keys.token, token);
    await store.write(Keys.deviceId, id);
    client = _clientFor(base, token);
    unpairedReason = null;
    notifyListeners();
    _start();
    if (notifications) unawaited(_enablePush());
  }

  /// Forgets the token. With [revoke], also removes this device on the hub.
  Future<void> unpair({bool revoke = true, String? reason}) async {
    final c = client;
    if (c == null) return;
    _stop();
    await push.disable(revoke ? c : null).catchError((_) {});
    if (revoke && deviceId != null && deviceId!.isNotEmpty) {
      await c.revokeDevice(deviceId!).catchError((_) {});
    }
    await store.write(Keys.token, null);
    await store.write(Keys.deviceId, null);
    client = null;
    _dropConversations();
    deviceId = null;
    snapshot = const AgentsSnapshot();
    haveSnapshot = false;
    unpairedReason = reason;
    notifyListeners();
  }

  Future<void> setHubUrl(String url) async {
    if (hubLocked) return;
    hubUrl = normalizeHubUrl(url);
    await store.write(Keys.hubUrl, hubUrl.toString());
    final token = await store.read(Keys.token);
    if (token != null) {
      client = _clientFor(hubUrl, token);
      _dropConversations();
      _stop();
      _start();
    }
    notifyListeners();
  }

  Future<void> setNotifications(bool on) async {
    notifications = on;
    await store.write(Keys.notifications, on ? 'on' : 'off');
    pushProblem = null;
    notifyListeners();
    if (on) {
      await _enablePush();
    } else {
      await push.disable(client).catchError((_) {});
    }
  }

  Future<void> _enablePush() async {
    pushProblem = await push.enable().catchError((Object e) => '$e');
    notifyListeners();
  }

  void setShowEnded(bool on) {
    showEnded = on;
    notifyListeners();
    unawaited(refresh().catchError((_) {}));
  }

  /// `GET /v1/agents`, for pull to refresh and for showing ended agents.
  Future<void> refresh() async {
    final c = client;
    if (c == null) return;
    try {
      _apply(await c.agents(all: showEnded));
    } on HubException catch (e) {
      if (e.unauthorized) await unpair(revoke: false, reason: 'The hub no longer knows this $deviceNoun.');
      rethrow;
    }
    _kick();
  }

  void _apply(AgentsSnapshot s) {
    snapshot = s;
    haveSnapshot = true;
    notifyListeners();
  }

  // The event stream: one loop per generation; _stop bumps the generation.

  void _start() {
    final gen = ++_gen;
    unawaited(_run(gen));
  }

  void _stop() {
    _gen++;
    unawaited(_sub?.cancel());
    _sub = null;
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete(null);
    _kick();
    link = Link.offline;
  }

  /// Ends a backoff wait early.
  void _kick() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _run(int gen) async {
    var delay = const Duration(seconds: 1);
    final rnd = Random();
    while (gen == _gen && client != null) {
      link = Link.connecting;
      notifyListeners();
      // The hub pings every 25 s; silence for much longer means a dead link.
      final events = client!.events(lastEventId: _lastEventId).timeout(const Duration(seconds: 70));
      final done = _streamDone = Completer<Object?>();
      _sub = events.listen(
        (ev) {
          delay = const Duration(seconds: 1);
          _onEvent(ev.event, ev.data, ev.id);
        },
        onError: (Object e) => done.isCompleted ? null : done.complete(e),
        onDone: () => done.isCompleted ? null : done.complete('connection closed'),
        cancelOnError: true,
      );
      final err = await done.future;
      _sub = null;
      if (gen != _gen) return;
      if (err is HubException && err.unauthorized) {
        await unpair(revoke: false, reason: 'The hub no longer knows this $deviceNoun.');
        return;
      }
      linkError = switch (err) {
        HubException e => e.message,
        TimeoutException _ => 'no events for 70 s',
        _ => '$err',
      };
      link = Link.offline;
      notifyListeners();
      final wake = _wake = Completer<void>();
      final jitter = Duration(milliseconds: rnd.nextInt(500));
      await Future.any([Future<void>.delayed(delay + jitter), wake.future]);
      delay = Duration(seconds: min(delay.inSeconds * 2, 60));
    }
  }

  void _onEvent(String event, String data, String? id) {
    _lastEventId = id ?? _lastEventId;
    link = Link.live;
    linkError = null;
    if (event != 'agents') {
      notifyListeners();
    } else if (showEnded) {
      unawaited(refresh().catchError((_) {}));
    } else {
      try {
        _apply(AgentsSnapshot.fromJson(jsonDecode(data) as Map<String, dynamic>));
      } on Object catch (e) {
        linkError = 'bad agents event: $e';
        notifyListeners();
      }
    }
  }

  /// Drop the stream in the background (push covers that) and come back
  /// at once on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!paired) return;
    if (state == AppLifecycleState.paused && !keepStreamInBackground) {
      _stop();
    } else if (state == AppLifecycleState.resumed && link == Link.offline) {
      _start();
    }
  }

  @override
  void dispose() {
    _stop();
    _dropConversations();
    super.dispose();
  }
}
