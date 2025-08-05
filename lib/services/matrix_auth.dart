import 'package:matrix/matrix.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

class AuthService {
  static Client? client;
  static String? userId;

  static Future<bool> login({
    required String user,
    required String password,
  }) async {
    try {
      final c = Client('AppClient');
      await c.init();
      await c.checkHomeserver(Uri.parse('https://webqalqan.com'));
      final res = await c.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: user),
        password: password,
      );
      client = c;
      userId = res.userId;
      client!.sync().catchError((_) {});
      return true;
    } catch (e, st) {
      debugPrint('AuthService.login error: $e\n$st');
      return false;
    }
  }
}