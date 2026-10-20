# Roster for Android and the web

The app for roster-hub, on an Android phone and in a browser: every agent on every linked machine, grouped by machine and live; an agent's conversation as a chat with a composer; the dialog of a blocked agent as buttons; starting, resuming and killing agents; and a notification when an agent is blocked, asks, finishes or hits an API error. It talks only to roster-hub, per section 2 and 3 of [docs/hub-api.md](../docs/hub-api.md). Application id `nl.sennadevos.roster`, Material 3 with light and dark themes. On a window at least 840 px wide (a laptop) the agents list and the open agent sit side by side; narrower, the agent opens over the list.

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

The web app:

```sh
cd app
tool/build_web.sh
```

That runs `tool/flutter.sh flutter build web --release --no-web-resources-cdn` and then `tool/web_fonts.sh` in the same image. The output, `build/web`, is what roster-hub serves, at the root of its own origin (`http://10.137.42.3:8790/` for now). Nothing in it comes from elsewhere: `--no-web-resources-cdn` puts CanvasKit in `build/web/canvaskit` instead of loading it from gstatic.com, and `web_fonts.sh` copies every fallback font this Flutter's engine can ask for (Noto symbols, emoji, CJK and other scripts; the paths are read from `main.dart.js`) into `build/web/fonts`, which `web/flutter_bootstrap.js` sets as `fontFallbackBaseUrl` in place of fonts.gstatic.com. Those fonts are downloaded from fonts.gstatic.com at build time, once, into the podman volume `roster-app-webfonts`. `build/web` is about 63 MB on disk, most of it CanvasKit variants and fonts of which a browser loads only what it needs. There is no service worker.

To look at the web app without a hub, `tool/preview/shoot.sh [out dir] [only]` serves `build/web` with a pretend hub (`tool/preview/fake_hub.mjs`: agents on three machines in every status, a blocked one with a form dialog, a stalled one, subagents, unread mail, an unreachable peer, long transcripts) and screenshots it in headless Chromium at desktop and phone sizes, light and dark, some after keys, typing or scrolling (the list of shots is in `tool/preview/shoot.mjs`). All of it runs in the Playwright image `mcr.microsoft.com/playwright:v1.64.0-noble`, with the npm package cached in the podman volume `roster-app-playwright`; the screenshots land in `screenshots/`, which git ignores. `node tool/preview/fake_hub.mjs 8790 build/web` on its own is a hub to click around in. The icons (`web/favicon.png`, `web/icons/`, the Android `mipmap-*/ic_launcher.png`) are rendered from `web/favicon.svg` by `tool/preview/icons.mjs` in the same image.

To move to a newer Flutter, change `FLUTTER_VERSION` and `FLUTTER_SHA256` in `Containerfile` (both from https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json), the image tag in `tool/flutter.sh`, and the NDK version in `Containerfile` to that release's `flutter.ndkVersion`.

## Use

1. On the hub machine, `roster-hub pair` prints a code.
2. In the app, enter the hub URL (default `https://roster.sennadevos.com`) and the code. The device token goes into the Android keystore (`flutter_secure_storage`). In the browser the hub is the one that served the page, so it asks only for the code and a name, and the token goes into `localStorage` (keys `roster.*`): `flutter_secure_storage` on web needs WebCrypto, which a browser only offers in a secure context, and plain HTTP on an IP address is not one.
3. For notifications on Android, install the ntfy app (the UnifiedPush distributor). The app registers with it and hands the endpoint to the hub; turn notifications off and on in Settings. The web app has no notifications (UnifiedPush and local notifications are Android only, and the browser's Notification API also needs a secure context), so Settings does not offer them; it keeps the event stream open while the tab is in the background instead.

## Layout

- `lib/api/`: `hub_client.dart` (every endpoint, errors as `HubException`) and `sse.dart` (the `text/event-stream` parser).
- `lib/models/`: agents and machines, transcript messages, screen and dialog, devices, push payloads, each from the contract's JSON.
- `lib/state/`: `app_state.dart` (pairing, the agents list, the event stream with reconnects), `conversation.dart` (one agent's transcript and screen), `store.dart` (the store interface and the localStorage one), `secure_store.dart` (the keystore one).
- `lib/push/push.dart`: UnifiedPush in, local notifications out.
- `lib/platform/`: what differs between Android and web, chosen at compile time by a conditional export (`platform_io.dart` or `platform_web.dart`), so the web build never compiles the Android plugins: the store, the client for the event stream, push, and the hub URL of the page.
- `web/`: the page around the app, with a splash in the app's background colour while the engine loads; `flutter_bootstrap.js` points the engine at the local fonts and removes the splash once the app runs.
- `lib/theme.dart`: light and dark themes, the status colours (`StatusColors`) and the bundled monospace font (JetBrains Mono 2.304, `fonts/JetBrainsMono`, SIL OFL; on the web `monospace` would fall back to Roboto), used without ligatures.
- `lib/screens/`, `lib/widgets/`: the UI.

State is plain Flutter: `ChangeNotifier`s, handed down with an `InheritedNotifier` (`AppScope`) and rebuilt with `ListenableBuilder`. No state package.

## Behaviour worth knowing

- The event stream is a plain streamed HTTP request with the bearer token. On web it goes through `fetch` (`fetch_client`), since package:http's browser client hands over a response only when it is complete. It reconnects with exponential backoff (1 s doubling to 60 s, with jitter) and `Last-Event-ID`, treats 70 s without an event (the hub pings every 25 s) as a dead link, and on Android is dropped while the app is in the background, where push takes over. A 401 on the event stream or the agents list (a revoked device) sends the app back to pairing.
- The agent screen loads the transcript's tail, then new messages after `next` whenever the agent's row changes in an `agents` event, and older ones with `before` the oldest shown. A tool call fetched before its result exists is fetched again, since the result is folded into the earlier line.
- A push for the agent that is on screen while the app is in front is dropped. Each agent has one notification; a newer one replaces it, and opening the agent clears it.
- `unifiedpush` depends on `unifiedpush_linux`, which pulls in `webcrypto` and its native build (BoringSSL through CMake, for every target, Android ABIs included). `packages/unifiedpush_linux` is an empty stand-in, set as a `dependency_overrides` in `pubspec.yaml`.
- The list puts the agents that need the user (blocked, or an API error that does not clear by itself) in a Needs you section on top, then each machine's agents as a tree. Subagents are lines under their agent, never rows of their own. The window title counts the agents that need the user.
- Conversations of the last 12 agents opened stay in memory, so going back to one shows it at once and fetches only what is new; the composer's draft stays with its agent.
- The conversation is two lists that meet at the newest message there was when it was opened: older pages grow upwards and new messages downwards, so neither moves what is on screen. It follows new messages only when scrolled to the bottom; otherwise a button counts them and jumps there.
- A prompt shows at once, dimmed, until the transcript has it; a refused one is taken back into the composer with the hub's reason.
- Keys, when no text field has focus (Keyboard shortcuts in the list's menu has them): `/` searches, `j`/`k` or the arrows move between agents (beside the list they open at once), Enter goes into the open agent (its dialog when one is up, else its composer), Esc leaves a text field, clears the search, then closes the agent. In a focused dialog the number keys pick and the arrows are Back and Next. Enter in the composer sends and Shift+Enter starts a new line.
- A refresh button in the list's bar stands in for pull to refresh in the browser. A dropped event stream shows only as the dot in the list's bar turning amber or red; after three seconds without it a quiet bar says so.
