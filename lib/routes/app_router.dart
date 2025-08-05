import 'package:flutter/material.dart';
import '../ui/login_page.dart';
import '../ui/chat_list_page.dart';

class AppRouter {
  static const login    = '/login';
  static const chatList = '/chats';

  static Route<dynamic>? generate(RouteSettings settings) {
    switch (settings.name) {
      case login:
        return MaterialPageRoute(builder: (_) => const LoginPage());
      case chatList:
        return MaterialPageRoute(builder: (_) => ChatListPage());
      default:
        return MaterialPageRoute(builder: (_) => const LoginPage());
    }
  }
}