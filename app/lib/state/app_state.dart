import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../api/hub_client.dart';
import '../models/agent.dart';
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

/// The app's state: pairing, the agents list and the live event stream.
/// Screens rebuild from it with ListenableBuilder (see AppScope).
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    required this.store,
    this.push = const NoPush(),
    HubClient Function(Uri base, String? token)? clientFor,
  }) : _clientFor = clientFor ?? ((base, token) => HubClient(base, token: token));

  final Store store;
  final PushControl push;
  final HubClient Function(Uri base, String? token) _clientFor;

  /// The agent whose screen is open, so its pushes can be dropped. Static
  /// because the push callback runs outside the widget tree.
  static String? onScreen;

  bool loaded = false;
  Uri hubUrl = normalizeHubUrl(defaultHubUrl);
  HubClient? client;
  String? deviceId;
  bool notifications = true;
  String? pushProblem;
  bool showEnded = false;

  /// Why the app went back to the pair screen, when it was not the user.
  String? unpairedReason;

  AgentsSnapshot snapshot = const AgentsSnapshot();
  bool haveSnapshot = false;
  Link link = Link.offline;
  String? linkError;

  bool get paired => client != null;

  int _gen = 0;
  String? _lastEventId;
  Completer<void>? _wake;
  StreamSubscription<Object?>? _sub;
  Completer<Object?>? _streamDone;

  Future<void> load() async {
    final url = await store.read(Keys.hubUrl);
    if (url != null) hubUrl = normalizeHubUrl(url);
    final token = await store.read(Keys.token);
    deviceId = await store.read(Keys.deviceId);
    notifications = (await store.read(Keys.notifications)) != 'off';
    if (token != null) client = _clientFor(hubUrl, token);
    loaded = true;
    notifyListeners();
    if (paired) {
      _start();
      if (notifications) unawaited(_enablePush());
    }
  }

  Future<void> pair(String url, String code, String deviceName) async {
    final base = normalizeHubUrl(url);
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
    deviceId = null;
    snapshot = const AgentsSnapshot();
    haveSnapshot = false;
    unpairedReason = reason;
    notifyListeners();
  }

  Future<void> setHubUrl(String url) async {
    hubUrl = normalizeHubUrl(url);
    await store.write(Keys.hubUrl, hubUrl.toString());
    final token = await store.read(Keys.token);
    if (token != null) {
      client = _clientFor(hubUrl, token);
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
      if (e.unauthorized) await unpair(revoke: false, reason: 'The hub no longer knows this phone.');
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
        await unpair(revoke: false, reason: 'The hub no longer knows this phone.');
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
    if (state == AppLifecycleState.paused) {
      _stop();
    } else if (state == AppLifecycleState.resumed && link == Link.offline) {
      _start();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}
