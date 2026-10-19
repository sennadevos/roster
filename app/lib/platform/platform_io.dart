import 'package:http/http.dart' as http;

import '../state/secure_store.dart';
import '../state/store.dart';

export '../push/push.dart' show Push;

const pushAvailable = true;

Store platformStore() => SecureStore();

http.Client streamingClient() => http.Client();

/// The app is not served by the hub, so the user names it.
Uri? pageHubUrl() => null;
