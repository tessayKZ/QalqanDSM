
import 'dart:async';
import 'package:flutter/material.dart';
import '../services/matrix_chat_service.dart';
import '../models/room.dart';
import 'chat_detail_page.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({Key? key}) : super(key: key);

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage>
    with RouteAware, WidgetsBindingObserver {
  List<Room> _rooms = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startAutoSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    MatrixService.stopSyncLoop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      MatrixService.syncOnce().then((_) => _updateRooms());
    }
  }

  void _startAutoSync() {
    MatrixService.syncOnce().then((_) {
      _updateRooms();
      MatrixService.startSyncLoop(intervalMs: 5000);
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        _updateRooms();
      });
    });
  }

  void _updateRooms() {
    final rooms = MatrixService.getJoinedRooms();
    setState(() {
      if (_rooms.isEmpty) {
        _rooms = rooms;
      } else if (rooms.isNotEmpty) {
        _rooms = rooms;
      }
      _loading = false;
    });
  }

  Future<void> _doRefresh() async {
    await MatrixService.syncOnce();
    _updateRooms();
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
      body: _rooms.isEmpty
          ? const Center(child: Text('Нет комнат'))
          : RefreshIndicator(
        onRefresh: _doRefresh,
        child: ListView.builder(
          itemCount: _rooms.length,
          itemBuilder: (ctx, index) {
            final room = _rooms[index];
            return ListTile(
              title: Text(room.name),
              subtitle: Text(
                room.lastMessage != null
                    ? '${room.lastMessage!['sender']}: '
                    '${room.lastMessage!['content']?['body'] ?? ''}'
                    : '',
              ),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatDetailPage(room: room),
                  ),
                );
                await _doRefresh();
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await _doRefresh();
        },
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
