import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CallStore {
  static const _kMyUserId = 'callstore_my_user_id';
  static const _kOutgoing = 'callstore_outgoing_ids';
  static const _kShown = 'callstore_shown_ids';

  static const _storage = FlutterSecureStorage();

  static Future<void> saveMyUserId(String userId) async {
    await _storage.write(key: _kMyUserId, value: userId);
  }

  static Future<String?> loadMyUserId() async {
    return await _storage.read(key: _kMyUserId);
  }

  static Future<void> markOutgoing(String callId) async {
    final s = await _readSet(_kOutgoing);
    s.add(callId);
    await _writeSet(_kOutgoing, s);
  }

  static Future<bool> isOutgoing(String callId) async {
    final s = await _readSet(_kOutgoing);
    return s.contains(callId);
  }

  static Future<void> removeOutgoing(String callId) async {
    final s = await _readSet(_kOutgoing);
    s.remove(callId);
    await _writeSet(_kOutgoing, s);
  }

  static Future<bool> alreadyShown(String callId) async {
    final s = await _readSet(_kShown);
    return s.contains(callId);
  }

  static Future<void> markShown(String callId) async {
    final s = await _readSet(_kShown);
    s.add(callId);
    await _writeSet(_kShown, s);
  }

  static Future<void> clear(String callId) async {
    await removeOutgoing(callId);
    final s = await _readSet(_kShown);
    s.remove(callId);
    await _writeSet(_kShown, s);
  }

  static Future<Set<String>> _readSet(String key) async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final list = List<String>.from(jsonDecode(raw));
      return list.toSet();
    } catch (_) {
      return raw.split(',').where((e) => e.isNotEmpty).toSet();
    }
  }

  static Future<void> _writeSet(String key, Set<String> set) async {
    await _storage.write(key: key, value: jsonEncode(set.toList()));
  }
}