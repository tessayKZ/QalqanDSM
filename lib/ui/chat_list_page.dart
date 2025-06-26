// lib/ui/chat_list_page.dart

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import '../services/matrix_auth.dart';
import '../services/matrix_call_service.dart';
import '../services/matrix_chat_service.dart';
import '../models/room.dart';
import 'chat_detail_page.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({Key? key}) : super(key: key);

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  late final MatrixCallService _callSvc;
  List<Room> _rooms   = [];
  bool       _loading = true;
  Timer?     _timer;

  @override
  void initState() {
    super.initState();
    _callSvc = MatrixCallService(AuthService.client!);

    _requestPermissions();

    _callSvc.start();

    FlutterCallkitIncoming.onEvent.listen((CallEvent? e) {
      if (e == null) return;
      final ev     = e.event;
      final callId = e.body?['id'];

      print('📞 got CallKit event: $ev, id=$callId');

      switch (ev) {
        case Event.actionCallIncoming:
          break;
        case Event.actionCallAccept:
          print('📞 accept pressed for $callId');
          _callSvc.handleCallkitAccept(callId);
          break;
        case Event.actionCallDecline:
          print('📞 decline pressed for $callId');
          FlutterCallkitIncoming.endCall(callId);
          break;
        default:
          break;
      }
    });

    _startAutoSync();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
      if (!await Permission.systemAlertWindow.isGranted) {
        await Permission.systemAlertWindow.request();
      }
    }
  }

  void _startAutoSync() {
    MatrixService.syncOnce().then((_) {
      _updateRooms();
      MatrixService.startSyncLoop(intervalMs: 5000);
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _updateRooms());
    });
  }

  void _updateRooms() {
    setState(() {
      _rooms   = MatrixService.getJoinedRooms();
      _loading = false;
    });
  }

  Future<void> _doRefresh() async {
    await MatrixService.syncOnce();
    _updateRooms();
  }

  @override
  void dispose() {
    _timer?.cancel();
    MatrixService.stopSyncLoop();
    _callSvc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Chats')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: RefreshIndicator(
        onRefresh: _doRefresh,
        child: _rooms.isEmpty
            ? const Center(child: Text('No chats'))
            : ListView.builder(
          itemCount: _rooms.length,
          itemBuilder: (ctx, i) {
            final room = _rooms[i];
            return ListTile(
              title: Text(room.name),
              subtitle: Text(room.lastMessage != null
                  ? "${room.lastMessage!['sender']}: ${room.lastMessage!['content']?['body'] ?? ''}"
                  : ''),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatDetailPage(room: room)),
                );
                _doRefresh();
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _doRefresh,
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
