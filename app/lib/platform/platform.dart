/// What differs between the Android app and the web app, picked at compile
/// time so that neither build sees the other's plugins:
///
/// - `Store platformStore()`: the keystore on Android, localStorage on web.
/// - `http.Client streamingClient()`: a client that hands over a response as
///   it arrives, for the event stream (package:http's BrowserClient buffers
///   the whole body, so web uses fetch).
/// - `Push`: UnifiedPush and local notifications on Android, nothing on web,
///   with `pushAvailable` saying which.
/// - `Uri? pageHubUrl()`: on web, the hub the page was served from.
/// - `openLink(Uri)`: a link from a message, in a new tab or the right app.
/// - `reloadPage()`: on web, load the new version of the app.
/// - `copyText(String)`: the clipboard, also on a plain-HTTP page.
/// - `onWindowFocus(callback)`: on web, called when the browser window gains
///   focus; returns a function that stops it. Nothing on Android.
library;

export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
