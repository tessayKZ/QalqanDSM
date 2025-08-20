import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'ui/login_page.dart';
import 'package:qalqan_dsm/services/call_store.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();

    final data = message.data;
    final eventType = data['type'] ?? data['event_type'];

    if (eventType == 'm.call.invite') {
      final callId = data['call_id'] ?? data['callId'];
      final roomId = data['room_id'] ?? data['roomId'];
      final sender = data['sender'] ?? 'unknown';
      final name = _extractLocalpart(sender);

        final myId = await CallStore.loadMyUserId();
        if (callId is String && callId.isNotEmpty) {
          if (myId != null && sender == myId) {
            await CallStore.markShown(callId);
            return;
          }
          if (await CallStore.isOutgoing(callId)) {
            await CallStore.markShown(callId);
            return;
          }
          if (await CallStore.alreadyShown(callId)) {
            return;
          }
        }

      if (callId != null && callId.isNotEmpty) {
        await FlutterCallkitIncoming.showCallkitIncoming(
          CallKitParams(
            id: callId,
            nameCaller: name,
            appName: 'QalqanDSM',
            type: 0,
            textAccept: 'Accept',
            textDecline: 'Decline',
            extra: {'call_id': callId, 'room_id': roomId, 'sender': sender},
          ),
        );
      }
    } else if (eventType == 'm.call.hangup') {
      final callId = data['call_id'] ?? data['callId'];
      if (callId != null && callId.isNotEmpty) {
        await FlutterCallkitIncoming.endCall(callId);
      }
    }
  } catch (e, st) {
    debugPrint('BG push handler error: $e\n$st');
  }
}

String _extractLocalpart(String mxid) {
  if (mxid.startsWith('@') && mxid.contains(':')) {
    return mxid.substring(1, mxid.indexOf(':'));
  }
  return mxid;
}

Future<void> _postBootInit() async {
  await Firebase.initializeApp();

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  final fcm = FirebaseMessaging.instance;
  await fcm.requestPermission();

  FirebaseMessaging.onMessage.listen((msg) {
    debugPrint('FCM foreground: ${msg.data}');
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const MyApp());

  unawaited(_postBootInit());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const LoginPage(),
    );
  }
}
// 1. Добавить синхронизацию chat_list_page.dart после создания чата с новым пользователем и
// так же после удаления пользователя в chat_list_pag.dart
// 2. Сделать авторизацию пользователя один раз как в whats app/telegram, чтобы не приходилось
// постоянно входить по учётными данными пользователя matrix-synapse сервер