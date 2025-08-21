import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CredStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'qalqan.credentials.v1';

  static Future<void> save({
    required String user,
    required String password,
  }) async {
    await _storage.write(
      key: _key,
      value: jsonEncode({'user': user, 'password': password}),
    );
  }

  static Future<({String user, String password})?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final user = (m['user'] as String?) ?? '';
      final pass = (m['password'] as String?) ?? '';
      if (user.isEmpty || pass.isEmpty) return null;
      return (user: user, password: pass);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() => _storage.delete(key: _key);
}