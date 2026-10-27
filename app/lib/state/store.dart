/// Where the app keeps the hub URL, its device token and its settings.
/// [platformStore] in platform_store.dart picks the one for the platform.
abstract class Store {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

/// A synchronous string key-value store, such as the browser's localStorage.
abstract class StringStorage {
  String? getItem(String key);
  void setItem(String key, String value);
  void removeItem(String key);
}

/// The web's store: plain strings in [StringStorage] (localStorage), under
/// [prefix] so they do not collide with anything else on the origin. The
/// keystore-backed store needs WebCrypto, which a browser only offers in a
/// secure context, and the hub is served over plain HTTP for now.
///
/// When the storage refuses (disabled, full, private mode), values are kept
/// in memory for the session instead.
class LocalStore implements Store {
  LocalStore(this.storage, {this.prefix = 'roster.'});

  final StringStorage storage;
  final String prefix;
  final Map<String, String?> _fallback = {};

  @override
  Future<String?> read(String key) async {
    if (_fallback.containsKey(key)) return _fallback[key];
    try {
      return storage.getItem('$prefix$key');
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String key, String? value) async {
    try {
      if (value == null) {
        storage.removeItem('$prefix$key');
      } else {
        storage.setItem('$prefix$key', value);
      }
      _fallback.remove(key);
    } on Object {
      _fallback[key] = value;
    }
  }
}

/// For tests.
class MemoryStore implements Store {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

abstract final class Keys {
  static const hubUrl = 'hub_url';
  static const token = 'token';
  static const deviceId = 'device_id';
  static const notifications = 'notifications';
  static const pushEndpoint = 'push_endpoint';
  static const theme = 'theme';
  static const listView = 'list_view';
  static const listHidden = 'list_hidden';
}
