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