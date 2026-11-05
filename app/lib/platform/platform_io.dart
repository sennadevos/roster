import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
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

/// Put text on the clipboard.
Future<bool> copyText(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  return true;
}

/// The Android app updates through its APK, not by reloading.
void reloadPage() {}

/// The Android app has no window to focus.
void Function() onWindowFocus(void Function() callback) => () {};

/// Images pasted into the page. On Android the paste arrives through the text
/// field itself (ContentInsertionConfiguration), not here, so this does
/// nothing and stops nothing.
void Function() onImagePaste(void Function(String name, Uint8List bytes) got) => () {};

/// Outside the browser there is no cross-origin rule, so a drawing at a URL is
/// fetched and parsed like any other: nothing special is needed here.
Widget? platformImageView(Uri url, {void Function(double aspect)? onSize}) => null;
