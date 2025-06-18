import 'package:matrix/matrix.dart';

class AuthDataCall {
  AuthDataCall._();

  static final AuthDataCall instance = AuthDataCall._();

  String login = '';
  String password = '';
}
