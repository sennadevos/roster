import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../api/hub_client.dart';
import '../state/app_state.dart';
import '../state/store.dart';

/// UnifiedPush and local notifications are Android only, and the browser's
/// Notification API needs a secure context, which plain HTTP is not.
const pushAvailable = false;

Store platformStore() => LocalStore(_LocalStorage());

/// fetch streams the body as it comes; same origin, so CORS mode lets the
/// Authorization header through (the package's default, no-cors, would drop
/// it), and the event stream must never come from the cache.
http.Client streamingClient() => FetchClient(mode: RequestMode.cors, cache: RequestCache.noStore);

Uri? pageHubUrl() => hubUrlForPage(Uri.base);

/// A link from a message, in a new tab.
Future<void> openLink(Uri url) async {
  web.window.open(url.toString(), '_blank', 'noopener,noreferrer');
}

/// Load the page again, for a new version of the app.
void reloadPage() => web.window.location.reload();

class _LocalStorage implements StringStorage {
  @override
  String? getItem(String key) => web.window.localStorage.getItem(key);

  @override
  void setItem(String key, String value) => web.window.localStorage.setItem(key, value);

  @override
  void removeItem(String key) => web.window.localStorage.removeItem(key);
}

/// Push on web: nothing to set up, nothing to show.
class Push extends NoPush {
  Push(Store store);

  static void Function(String agent)? onOpen;

  static Future<void> init(Store store) async {}

  static Future<String?> launchAgent() async => null;
}
