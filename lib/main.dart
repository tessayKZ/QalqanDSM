import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'ui/login_page.dart';
import 'ui/splash_gate.dart';
import 'package:qalqan_dsm/services/call_store.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'services/matrix_incoming_call_service.dart';
import 'package:uuid/uuid.dart';

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
      final name   = _extractLocalpart(sender);

      if (callId is String && callId.isNotEmpty) {
        final uuid = const Uuid().v4();
        await CallStore.mapCallIdToUuid(callId, uuid);

        final active = await FlutterCallkitIncoming.activeCalls();
        if (active.any((c) => c['id'] == uuid)) return;

        await FlutterCallkitIncoming.showCallkitIncoming(
          CallKitParams(
            id: uuid,
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

        final uuid = await CallStore.uuidForCallId(callId) ?? callId;
        await FlutterCallkitIncoming.endCall(uuid);
        await CallStore.unmapCallId(callId);
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
  final fcm = FirebaseMessaging.instance;
  await fcm.requestPermission();
  FirebaseMessaging.onMessage.listen((msg) {
    debugPrint('FCM foreground: ${msg.data}');
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  runApp(const MyApp());
  unawaited(_postBootInit());

  FlutterCallkitIncoming.onEvent.listen((e) async {
    if (e == null) return;

    final ev = e.event;
    final uuid = e.body?['id'] as String?;
    final extra = (e.body?['extra'] as Map?)?.cast<String, dynamic>();
    final callId = extra?['call_id'] as String?;

    switch (ev) {
      case Event.actionCallAccept:
        if (callId != null && uuid != null) {
          final mapped = await CallStore.uuidForCallId(callId);
          if (mapped == null) {
            await CallStore.mapCallIdToUuid(callId, uuid);
          }
          try {
            MatrixCallService.I.handleCallkitAccept(callId);
          } catch (_) {}
        }
        break;

      case Event.actionCallDecline:
      case Event.actionCallEnded:
      case Event.actionCallTimeout:
        if (uuid != null) {
          await FlutterCallkitIncoming.endCall(uuid);
        }
        if (callId != null) {
          await CallStore.unmapCallId(callId);
        }
        break;

      default:
        break;
    }
});
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      home: const SplashGate(),
    );
  }
}