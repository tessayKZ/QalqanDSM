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
import 'add_users_page.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({Key? key}) : super(key: key);

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  late final MatrixCallService _callSvc;
  List<Room> _rooms = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _callSvc = MatrixCallService(
      AuthService.client!,
      AuthService.userId!,
    );
    _requestPermissions();
    _callSvc.start();
    _listenCallEvents();

    // Initial load with spinner
    _initialLoad();

    // Silent refresh every 5 seconds
    _timer = Timer.periodic(
      const Duration(seconds: 5),
          (_) => _silentRefresh(),
    );
  }

  // Initial full load showing loading indicator
  Future<void> _initialLoad() async {
    setState(() => _loading = true);
    await MatrixService.syncOnce();
    _rooms = MatrixService.getJoinedRooms();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  // Silent refresh without showing indicator
  Future<void> _silentRefresh() async {
    await MatrixService.syncOnce();
    final updated = MatrixService.getJoinedRooms();
    if (!mounted) return;
    setState(() {
      _rooms = updated;
    });
  }

  // Manual pull-to-refresh
  Future<void> _onRefresh() async {
    await _silentRefresh();
  }

  void _listenCallEvents() {
    FlutterCallkitIncoming.onEvent.listen((CallEvent? e) {
      if (e == null) return;
      final ev = e.event;
      final callId = e.body?['id'];
      if (ev == Event.actionCallAccept) _callSvc.handleCallkitAccept(callId);
      if (ev == Event.actionCallDecline) FlutterCallkitIncoming.endCall(callId);
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.notification.request();
      await Permission.systemAlertWindow.request();
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add),
            tooltip: 'Add User',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddUsersPage()),
            ),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6A11CB), Color(0xFF2575FC)],
          ),
        ),
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : RefreshIndicator(
            color: Colors.white,
            onRefresh: _onRefresh,
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              itemCount: _rooms.length,
              itemBuilder: (context, index) {
                final room = _rooms[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 4,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.indigo.shade100,
                      child: Text(
                        room.name.isNotEmpty ? room.name[0] : '?',
                        style: const TextStyle(
                            fontSize: 20, color: Colors.white),
                      ),
                    ),
                    title: Text(
                      room.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: room.lastMessage != null
                        ? Text(
                      "${room.lastMessage!['sender'].split(':').first}: ${room.lastMessage!['content']?['body'] ?? ''}",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                        : null,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatDetailPage(room: room),
                        ),
                      );
                      _silentRefresh();
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}