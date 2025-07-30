import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/room.dart';
import '../models/message.dart';

class MatrixService {
  static const String _homeServerUrl = 'https://webqalqan.com';
  static String? _accessToken;
  static String? _fullUserId;
  static String? _nextBatch;
  static Map<String, dynamic>? _lastSyncResponse;
  static bool _syncing = false;

  static String? get accessToken => _accessToken;

  static String get homeServer => _homeServerUrl;

  static String? get userId => _fullUserId;

  static Future<bool> login({
    required String user,
    required String password,
  }) async {
    final uri = Uri.parse('$_homeServerUrl/_matrix/client/r0/login');
    final payload = jsonEncode({
      'type': 'm.login.password',
      'user': user,
      'password': password,
    });

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _accessToken = data['access_token'] as String?;
      _fullUserId = data['user_id'] as String?;
      print('DEBUG: Login successful. user_id=$_fullUserId, token=$_accessToken');

      await syncOnce();
      return true;
    } else {
      print('Login failed ${response.statusCode}: ${response.body}');
      return false;
    }
  }

  static Future<void> syncOnce() async {
    _lastSyncResponse = null;
    _nextBatch = null;
    await _doSync();
  }

  static Future<void> forceSync() async {
    await _doSync();
  }

  static Future<void> _doSync() async {
    if (_accessToken == null) return;

    final params = _nextBatch == null
        ? '?timeout=30000'
        : '?since=${Uri.encodeComponent(_nextBatch!)}&timeout=30000';

    final uri = Uri.parse('$_homeServerUrl/_matrix/client/r0/sync$params');
    print('DEBUG: Syncing as $_fullUserId; URI=$uri');

    final response = await http.get(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
    );

    if (response.statusCode == 200) {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      _lastSyncResponse = decoded;
      _nextBatch = decoded['next_batch'] as String?;
      print('>>> New next_batch=$_nextBatch');
    } else {
      print('SYNC failed ${response.statusCode}: ${response.body}');
    }
  }

  static Future<void> startSyncLoop({int intervalMs = 5000}) async {
    if (_syncing) return;
    _syncing = true;
    while (_syncing) {
      await _doSync();
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
  }

  static void stopSyncLoop() {
    _syncing = false;
  }

  static List<Room> getJoinedRooms() {
    final resp = _lastSyncResponse;
    if (resp == null) return [];

    final roomsSection = resp['rooms']?['join'] as Map<String, dynamic>?;
    if (roomsSection == null) return [];

    final List<Room> result = [];
    roomsSection.forEach((roomId, roomDataRaw) {
      final roomData = roomDataRaw as Map<String, dynamic>;

      String name = roomId;
      final stateEvents = roomData['state']?['events'] as List<dynamic>?;
      if (stateEvents != null) {
        final nameEvent = stateEvents.firstWhere(
              (e) => (e as Map<String, dynamic>)['type'] == 'm.room.name',
          orElse: () => null,
        ) as Map<String, dynamic>?;
        if (nameEvent != null) {
          name = nameEvent['content']?['name'] as String? ?? roomId;
        }
      }

      Map<String, dynamic>? lastMsg;
      final timelineEvents = roomData['timeline']?['events'] as List<dynamic>?;
      if (timelineEvents != null && timelineEvents.isNotEmpty) {
        lastMsg = (timelineEvents.lastWhere(
              (e) => ((e as Map<String, dynamic>)['type'] as String).startsWith('m.room.message'),
          orElse: () => null,
        ) as Map<String, dynamic>?);
      }

      result.add(Room(
        id: roomId,
        name: name,
        lastMessage: lastMsg,
      ));
    });

    return result;
  }

  static List<Message> getRoomMessages(String roomId) {
    final resp = _lastSyncResponse;
    if (resp == null) return [];

    final roomSection = resp['rooms']?['join']?[roomId] as Map<String, dynamic>?;
    if (roomSection == null) return [];

    final timelineEvents = roomSection['timeline']?['events'] as List<dynamic>?;
    if (timelineEvents == null) return [];

    final List<Message> result = [];

    bool sawInvite = false;
    bool sawAnswer = false;
    bool sawHangup = false;

    for (var e in timelineEvents) {
      final event = e as Map<String, dynamic>;
      final type = event['type'] as String? ?? '';
      if (type == 'm.call.invite') sawInvite = true;
      if (type == 'm.call.answer') sawAnswer = true;
      if (type == 'm.call.hangup') sawHangup = true;
    }

    final bool missedCall = sawInvite && sawHangup && !sawAnswer;
    if (missedCall) {
      Map<String, dynamic>? inviteEvent;
      for (var e in timelineEvents) {
        final ev = e as Map<String, dynamic>;
        if ((ev['type'] as String? ?? '') == 'm.call.invite') {
          inviteEvent = ev;
          break;
        }
      }
      if (inviteEvent != null) {
        final sender = inviteEvent['sender'] as String? ?? '';
        result.add(Message(
          sender: sender,
          text: '📞 Пропущенный звонок',
          type: MessageType.call,
        ));
      }
    }

    for (var e in timelineEvents) {
      final event = e as Map<String, dynamic>;
      final eventType = event['type'] as String? ?? '';
      if (eventType.startsWith('m.room.message')) {
        final sender = event['sender'] as String? ?? '';
        final content = event['content'] as Map<String, dynamic>?;
        final body = content?['body'] as String? ?? '';
        result.add(Message(
          sender: sender,
          text: body,
          type: MessageType.text,
        ));
      }
    }

    if (!missedCall) {
      for (var e in timelineEvents) {
        final event = e as Map<String, dynamic>;
        final eventType = event['type'] as String? ?? '';

        if (eventType.startsWith('m.call.')) {
          if (eventType == 'm.call.candidates') continue;

          final sender = event['sender'] as String? ?? '';
          String callText;

          if (eventType == 'm.call.invite') {
            callText = '📞 Звонок: приглашение';
          } else if (eventType == 'm.call.answer') {
            callText = '📞 Звонок: ответ';
          } else if (eventType == 'm.call.hangup') {
            callText = '📞 Звонок завершён';
          } else {
            callText = '📞 Событие звонка ($eventType)';
          }

          result.add(Message(
            sender: sender,
            text: callText,
            type: MessageType.call,
          ));
        }
      }
    }

    return result;
  }

  static Future<void> sendMessage(String roomId, String text) async {
    if (_accessToken == null) return;
    final txnId = DateTime.now().millisecondsSinceEpoch.toString();
    final uri = Uri.parse(
      '$_homeServerUrl/_matrix/client/r0/rooms/$roomId/send/m.room.message/$txnId',
    );
    final payload = jsonEncode({
      'msgtype': 'm.text',
      'body': text,
    });

    final response = await http.put(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: payload,
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      print('sendMessage failed ${response.statusCode}: ${response.body}');
    } else {
      await _doSync();
    }
  }

  static Future<List<Message>> fetchRoomHistory(String roomId) async {
    if (_accessToken == null) return [];

    await syncOnce();

    final roomSection = _lastSyncResponse?['rooms']?['join']?[roomId]
    as Map<String, dynamic>?;
    if (roomSection == null) return [];

    final initialTimeline = (roomSection['timeline']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ??
        [];

    String? prevBatch = roomSection['timeline']?['prev_batch'] as String?;

    final olderRaw = <Map<String, dynamic>>[];
    if (prevBatch != null && prevBatch.isNotEmpty) {
      var from = prevBatch;
      const pageSize = 50;
      while (true) {
        final uri = Uri.parse(
          '$_homeServerUrl/_matrix/client/r0/rooms/$roomId/messages'
              '?from=${Uri.encodeComponent(from)}&dir=b&limit=$pageSize',
        );
        final resp = await http.get(uri, headers: {
          if (_accessToken != null) 'Authorization': 'Bearer $_accessToken'
        });
        if (resp.statusCode != 200) break;
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final chunk = (data['chunk'] as List?)?.cast<Map<String, dynamic>>();
        final end = data['end'] as String?;
        if (chunk == null || chunk.isEmpty) break;
        olderRaw.addAll(chunk);
        if (end == null || end.isEmpty) break;
        from = end;
      }
    }

    Message? convert(Map<String, dynamic> e) {
      final type = e['type'] as String? ?? '';
      if (type.startsWith('m.room.message')) {
        return Message(
          sender: e['sender'] as String? ?? '',
          text: (e['content'] as Map)['body'] as String? ?? '',
          type: MessageType.text,
        );
      }
      if (type.startsWith('m.call.') && type != 'm.call.candidates') {
        String txt;
        if (type == 'm.call.invite') txt = '📞 Звонок приглашение';
        else if (type == 'm.call.answer') txt = '📞 Звонок ответ';
        else if (type == 'm.call.hangup') txt = '📞 Звонок завершён';
        else txt = '📞 Событие звонка';
        return Message(
          sender: e['sender'] as String? ?? '',
          text: txt,
          type: MessageType.call,
        );
      }
      return null;
    }

    final all = <Message>[];
    for (var raw in olderRaw.reversed) {
      final m = convert(raw);
      if (m != null) all.add(m);
    }

    for (var raw in initialTimeline) {
      final m = convert(raw);
      if (m != null) all.add(m);
    }
    return all;
  }

  /// Создаёт приватную комнату один-на-один с заданным юзером через HTTP API
  static Future<Room?> createDirectChat(String userId) async {
    if (_accessToken == null) return null;

    // Формируем полный Matrix ID
    final target = userId.startsWith('@')
        ? userId
        : '@$userId:${Uri.parse(_homeServerUrl).host}';

    // Собираем URL с токеном
    final uri = Uri.parse(
        '$_homeServerUrl/_matrix/client/r0/createRoom?access_token=$_accessToken'
    );

    // Тело запроса
    final payload = jsonEncode({
      'invite': [target],
      'is_direct': true,
    });

    // Выполняем POST
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final roomId = data['room_id'] as String;
      final displayName = target.split(':').first.replaceFirst('@', '');
      return Room(id: roomId, name: displayName);
    } else {
      print('Direct chat creation failed ${response.statusCode}: ${response.body}');
      return null;
    }
  }
}