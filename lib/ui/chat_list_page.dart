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
import 'package:matrix/matrix.dart' as mx;
import '../services/matrix_sync_service.dart';

class ChatListPage extends StatefulWidget {
  const ChatListPage({Key? key}) : super(key: key);

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> with WidgetsBindingObserver {
  StreamSubscription<mx.Event>? _subAll;
  Timer? _liveTimer;

  final Map<String, String> _nameCache = {};
  bool _rebuilding = false;
  bool _didInitialSync = false;

  late final MatrixCallService _callSvc;
  bool _loading = true;
  List<Room> _peopleRooms = [];
  List<Room> _groupRooms = [];


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _callSvc = MatrixCallService(
      AuthService.client!,
      AuthService.userId!,
    );
    _requestPermissions();
    _callSvc.start();
    _listenCallEvents();
    MatrixSyncService.instance.attachClient(AuthService.client!);
    MatrixSyncService.instance.start();
    _initialLoad();
    _startLiveSync();

    _subAll = MatrixSyncService.instance.events.listen((ev) {
      if (ev.type == 'm.room.member' ||
          ev.type == 'm.room.create' ||
          ev.type == 'm.room.name'   ||
          ev.type == 'm.room.message'||
          ev.type.startsWith('m.call.')) {
        _rebuildFromSync();
      }
    });
  }

  Future<void> _initialLoad() async {
    setState(() => _loading = true);
    await _rebuildFromSync(force: true);
  }

Future<void> _silentRefresh() async {
  await _rebuildFromSync();
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _startLiveSync();
  } else {
    _stopLiveSync();
  }
}

  void _startLiveSync() {
    _liveTimer ??= Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_rebuilding) {
        await _rebuildFromSync();
      }
    });
  }

  void _stopLiveSync() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }

  Future<void> _rebuildFromSync({bool force = false}) async {
    if (_rebuilding) return;
    _rebuilding = true;
    try {
      if (!_didInitialSync) {
        await MatrixService.syncOnce();
        _didInitialSync = true;
      } else {
        await MatrixService.forceSync(timeout: 1200);
      }

      final all       = MatrixService.getJoinedRooms();
      final directIds = MatrixService.getDirectRoomIds();
      final directMap = MatrixService.getDirectRoomIdToUserIdMap();

      final List<Room> people = [];
      for (final r in all.where((r) => directIds.contains(r.id))) {
        final other = directMap[r.id];
        if (other == null) continue;
        final cached = _nameCache[other];
        final displayName = cached ?? await MatrixService.getUserDisplayName(other);
        _nameCache[other] = displayName;
        r.name = displayName;
        people.add(r);
      }

      final List<Room> groups = all.where((r) => !directIds.contains(r.id)).toList();

      if (!force && people.isEmpty && groups.isEmpty) {
        return;
      }

      final changed = force
          || !_sameRooms(_peopleRooms, people)
          || !_sameRooms(_groupRooms, groups);

      if (changed && mounted) {
        setState(() {
          _peopleRooms = people;
          _groupRooms  = groups;
          _loading     = false;
        });
      }
    } finally {
      _rebuilding = false;
    }
  }

  bool _sameRooms(List<Room> a, List<Room> b) {
    if (a.length != b.length) return false;
    final aa = List<Room>.from(a)..sort((x,y)=>x.id.compareTo(y.id));
    final bb = List<Room>.from(b)..sort((x,y)=>x.id.compareTo(y.id));
    for (var i = 0; i < aa.length; i++) {
      if (aa[i].id != bb[i].id) return false;
      final am = aa[i].lastMessage?['event_id'];
      final bm = bb[i].lastMessage?['event_id'];
      if (am != bm) return false;
      if (aa[i].name != bb[i].name) return false;
    }
    return true;
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
      await Permission.systemAlertWindow.request();
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
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
        title: Text(room.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: () {
              final ev = room.lastMessage;
              if (ev == null) return null;
              final sender = (ev['sender'] as String?) ?? '';
              final body   = ((ev['content'] as Map?)?['body'] as String?) ?? '';
              final who    = sender.isNotEmpty ? sender.split(':').first : '';
              return Text(
                (who.isNotEmpty ? '$who: ' : '') + body,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            }(),

        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) async {
            if (value == 'settings') {
              // TODO: room settings
            } else if (value == 'leave') {
              final ok = await MatrixService.leaveRoom(room.id);
              if (ok) {
                await _rebuildFromSync(force: true);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('You left ${room.name}')),
                );
              } else {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Failed to leave room')),
                );
              }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'settings', child: Text('Settings')),
            PopupMenuItem(value: 'leave',    child: Text('Leave')),
          ],
        ),
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
  WidgetsBinding.instance.removeObserver(this);
  _subAll?.cancel();
  _stopLiveSync();
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
            onPressed: () async {
              final Room? newRoom = await Navigator.of(context).push<Room>(
                MaterialPageRoute(builder: (_) => const AddUsersPage()),
              );
              if (newRoom != null) {
                await MatrixService.syncOnce();
                await _rebuildFromSync(force: true);
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ChatDetailPage(room: newRoom)),
                );
              }
            },
          ),
        ],
      ),

      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/background.png'),
            fit: BoxFit.cover,
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