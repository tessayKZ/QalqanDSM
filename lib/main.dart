import 'package:flutter/material.dart';
import 'routes/app_router.dart';
import 'ui/login_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QalqanDSM',
      navigatorKey: navigatorKey,
      onGenerateRoute: AppRouter.generate,
      initialRoute: AppRouter.login,
      theme: ThemeData(primarySwatch: Colors.blue),
    );
  }
}
/*                                    DSM tasks:
    1. Улучшить ui chat_detail_page и добавить вложение файлов
    2. Сделать проверку на наличие пользователя в add_users_page
    3. Убрать чтобы не запрашивались разрешения на уведомления, сразу были добавлены без разрешения
 */