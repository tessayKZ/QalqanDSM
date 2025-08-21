import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as mx;

class AuthService {
  static mx.Client? client;
  static String? userId;
  static String? accessToken;
  static String? deviceId;

  static final Uri _homeserver = Uri.parse('https://webqalqan.com');

  static Future<bool> login({
    required String user,
    required String password,
  }) async {
    try {
      final c = mx.Client('QalqanDSM');
      await c.init();
      await c.checkHomeserver(_homeserver);

      final res = await c.login(
        mx.LoginType.mLoginPassword,
        identifier: mx.AuthenticationUserIdentifier(user: user),
        password: password,
      );

      client = c;
      userId = res.userId;
      accessToken = res.accessToken;
      deviceId = res.deviceId;

      return true;
    } catch (e, st) {
      debugPrint('AuthService.login error: $e\n$st');
      return false;
    }
  }

  static Future<void> logout() async {
    try { await client?.logout(); } catch (_) {}
    client = null;
    userId = null;
    accessToken = null;
    deviceId = null;
  }

  static Future<bool> changePassword({
    required String oldPassword,
    required String newPassword,
    bool logoutOtherDevices = false,
  }) async {
    final c = client;
    final token = accessToken;
    final mxid = c?.userID ?? userId;
    if (c == null || token == null || mxid == null) return false;

    final base = _homeserver.toString().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$base/_matrix/client/v3/account/password');

    try {
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'auth': {
            'type': 'm.login.password',
            'identifier': {'type': 'm.id.user', 'user': mxid},
            'password': oldPassword,
          },
          'new_password': newPassword,
          'logout_devices': logoutOtherDevices,
        }),
      );

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return true;
      } else {
        debugPrint('changePassword failed: ${resp.statusCode} ${resp.body}');
        return false;
      }
    } catch (e) {
      debugPrint('changePassword error: $e');
      return false;
    }
  }
}