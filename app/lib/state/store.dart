import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the app keeps the hub URL, its device token and its settings.
abstract class Store {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

/// The phone's keystore-backed storage.
class SecureStore implements Store {
  SecureStore() : _s = const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _s.delete(key: key) : _s.write(key: key, value: value);
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
}
