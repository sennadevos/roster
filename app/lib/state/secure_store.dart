import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'store.dart';

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
