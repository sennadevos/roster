import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../state/secure_store.dart';
import '../state/store.dart';

export '../push/push.dart' show Push;

const pushAvailable = true;

Store platformStore() => SecureStore();

http.Client streamingClient() => http.Client();

/// The app is not served by the hub, so the user names it.
Uri? pageHubUrl() => null;

/// A link from a message, in the browser or the app that handles it.
Future<void> openLink(Uri url) async {
  await launchUrl(url, mode: LaunchMode.externalApplication);
}

/// The Android app updates through its APK, not by reloading.
void reloadPage() {}
