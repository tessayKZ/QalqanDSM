import 'package:matrix/matrix.dart';

/// Сервис аутентификации и хранения единственного клиента
class AuthService {
  static Client? client;
  static String? userId;

  /// Логин и инициализация клиента
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
    } catch (_) {
      return false;
    }
  }
}