# Roster for Android

The phone app for roster-hub: every agent on every linked machine, grouped by machine and live; an agent's conversation as a chat with a composer; the dialog of a blocked agent as buttons; starting, resuming and killing agents; and a notification when an agent is blocked, asks, finishes or hits an API error. It talks only to roster-hub, per section 2 and 3 of [docs/hub-api.md](../docs/hub-api.md). Application id `nl.sennadevos.roster`, Android only, Material 3 with light and dark themes.

## Build

Nothing is installed on the host: Flutter and the Android SDK live in a container image built from `Containerfile` (the Cirrus Labs Android SDK image plus Flutter 3.47.7, checked against the sha256 in Google's releases JSON, plus the NDK, CMake and platform the Gradle build needs). `tool/flutter.sh` builds that image the first time (`localhost/roster-app-build:3.47.7`) and runs any command in it with this directory mounted at `/app`; pub and Gradle caches stay in the podman volumes `roster-app-pub` and `roster-app-gradle`, and `~/.android` (with the debug key that signs the APK, so a new build installs over the last one) in `roster-app-android`.

```sh
cd app
tool/flutter.sh flutter pub get
tool/flutter.sh flutter analyze
tool/flutter.sh flutter test
tool/flutter.sh flutter build apk --release
```

The APK lands in `build/app/outputs/flutter-apk/app-release.apk`. For now the release build is signed with the debug key, so it installs (`adb install`) but cannot be published; release signing comes later.

To move to a newer Flutter, change `FLUTTER_VERSION` and `FLUTTER_SHA256` in `Containerfile` (both from https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json), the image tag in `tool/flutter.sh`, and the NDK version in `Containerfile` to that release's `flutter.ndkVersion`.

## Use

1. On the hub machine, `roster-hub pair` prints a code.
2. In the app, enter the hub URL (default `https://roster.sennadevos.com`) and the code. The device token goes into the Android keystore (`flutter_secure_storage`).
3. For notifications, install the ntfy app (the UnifiedPush distributor). The app registers with it and hands the endpoint to the hub; turn notifications off and on in Settings.

## Layout

- `lib/api/`: `hub_client.dart` (every endpoint, errors as `HubException`) and `sse.dart` (the `text/event-stream` parser).
- `lib/models/`: agents and machines, transcript messages, screen and dialog, devices, push payloads, each from the contract's JSON.
- `lib/state/`: `app_state.dart` (pairing, the agents list, the event stream with reconnects), `conversation.dart` (one agent's transcript and screen), `store.dart` (secure storage).
- `lib/push/push.dart`: UnifiedPush in, local notifications out.
- `lib/screens/`, `lib/widgets/`: the UI.

State is plain Flutter: `ChangeNotifier`s, handed down with an `InheritedNotifier` (`AppScope`) and rebuilt with `ListenableBuilder`. No state package.

## Behaviour worth knowing

- The event stream is a plain streamed HTTP request with the bearer token. It reconnects with exponential backoff (1 s doubling to 60 s, with jitter) and `Last-Event-ID`, treats 70 s without an event (the hub pings every 25 s) as a dead link, and is dropped while the app is in the background, where push takes over. A 401 on the event stream or the agents list (a revoked device) sends the app back to pairing.
- The transcript endpoint pages forward only (`after`, `limit`). The agent screen loads the tail, then new messages after `next` whenever the agent's row changes in an `agents` event. Older messages come from a window of lines before the oldest one shown (`after = oldest - window`, keeping what is older), which relies on `limit` taking the first messages after `after`; a `before` parameter on the hub would make it exact. A tool call fetched before its result exists is fetched again, since the result is folded into the earlier line.
- A push for the agent that is on screen while the app is in front is dropped. Each agent has one notification; a newer one replaces it, and opening the agent clears it.
- `unifiedpush` depends on `unifiedpush_linux`, which pulls in `webcrypto` and its native build (BoringSSL through CMake, for every target, Android ABIs included). `packages/unifiedpush_linux` is an empty stand-in, set as a `dependency_overrides` in `pubspec.yaml`.
