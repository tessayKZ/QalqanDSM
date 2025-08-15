import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'ui/login_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final params = CallKitParams(
    id: message.data['call_id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
    nameCaller: message.data['caller_name'] ?? 'Incoming call',
    appName: 'QalqanDSM',
    handle: message.data['handle'] ?? 'unknown',
    type: 0,
    duration: 30000,
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
}

Future<void> _requestRuntimePerms() async {
  if (Platform.isAndroid) {
    await FirebaseMessaging.instance.requestPermission();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await _requestRuntimePerms();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      home: const LoginPage(),
    );
  }
}