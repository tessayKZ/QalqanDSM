import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import '../services/matrix_auth.dart';
import '../services/matrix_incoming_call_service.dart';
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
  bool _loading = true;
  Timer? _timer;
  List<Room> _peopleRooms = [];
  List<Room> _groupRooms = [];

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

    _initialLoad();

    _timer = Timer.periodic(
      const Duration(seconds: 5),
          (_) => _silentRefresh(),
    );
  }

  Future<void> _initialLoad() async {
    setState(() => _loading = true);
    await MatrixService.syncOnce();

    final all = MatrixService.getJoinedRooms();
    final directIds = MatrixService.getDirectRoomIds();
    final directMap = MatrixService.getDirectRoomIdToUserIdMap();

    final List<Room> people = [];
    for (var room in all.where((r) => directIds.contains(r.id))) {
      final otherUserId = directMap[room.id]!;
      final displayName = await MatrixService.getUserDisplayName(otherUserId);
      room.name = displayName;
      people.add(room);
    }

    final List<Room> groups =
    all.where((r) => !directIds.contains(r.id)).toList();

    if (!mounted) return;
    setState(() {
      _peopleRooms = people;
      _groupRooms = groups;
      _loading = false;
    });
  }

  Future<void> _silentRefresh() async {
    await MatrixService.syncOnce();

    final all       = MatrixService.getJoinedRooms();
    final directIds = MatrixService.getDirectRoomIds();
    final directMap = MatrixService.getDirectRoomIdToUserIdMap();

    final List<Room> people = [];
    for (var room in all.where((r) => directIds.contains(r.id))) {
      final otherUserId = directMap[room.id]!;
      final displayName = await MatrixService.getUserDisplayName(otherUserId);
      room.name = displayName;
      people.add(room);
    }

    final List<Room> groups =
    all.where((r) => !directIds.contains(r.id)).toList();

    if (!mounted) return;
    setState(() {
      _peopleRooms = people;
      _groupRooms = groups;
    });
  }


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

  Widget _buildRoomTile(Room room) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 4,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.indigo.shade100,
          child: Text(
            room.name.isNotEmpty ? room.name[0] : '?',
            style: const TextStyle(fontSize: 20, color: Colors.white),
          ),
        ),
        title: Text(room.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: room.lastMessage != null
            ? Text(
          "${room.lastMessage!['sender'].split(':').first}: "
              "${room.lastMessage!['content']?['body'] ?? ''}",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        )
            : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChatDetailPage(room: room)),
          );
          _silentRefresh();
        },
      ),
    );
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
              ? const Center(
            child: CircularProgressIndicator(color: Colors.white),
          )
              : RefreshIndicator(
            color: Colors.white,
            onRefresh: _onRefresh,
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(
                  vertical: 16, horizontal: 12),
              children: [
                if (_peopleRooms.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'People',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  for (var room in _peopleRooms) _buildRoomTile(room),
                ],
                if (_groupRooms.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'Rooms',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  for (var room in _groupRooms) _buildRoomTile(room),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}