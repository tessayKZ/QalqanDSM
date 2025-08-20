import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as mx;
import '../models/room.dart';
import '../models/message.dart';
import 'matrix_auth.dart';

class MatrixService {
  static const String _homeServerUrl = 'https://webqalqan.com';
  static String homeserverBase = 'https://webqalqan.com';
  static mx.Client get client => AuthService.client!;

  static String? _accessToken;
  static String? _fullUserId;
  static String? _nextBatch;
  static Map<String, dynamic>? _lastSyncResponse;
  static bool _syncing = false;

  static String _localPart(String userId) =>
      userId.split(':').first.replaceFirst('@', '');

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

  static Future<void> forceSync({int timeout = 5000}) async {
    if (_accessToken == null) return;

    final sinceParam = _nextBatch != null
        ? '&since=${Uri.encodeComponent(_nextBatch!)}'
        : '';

    final uri = Uri.parse(
        '$_homeServerUrl/_matrix/client/r0/sync'
            '?timeout=$timeout$sinceParam'
    );
    print('DEBUG: forceSync URI=$uri');

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
      print('forceSync failed ${response.statusCode}: ${response.body}');
    }
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

    final events = (roomSection['timeline']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ?? [];

    events.sort((a, b) =>
        (a['origin_server_ts'] as int)
            .compareTo(b['origin_server_ts'] as int)
    );

    final List<Message> result = [];

    for (var e in events) {
      final type = e['type'] as String? ?? '';
      final sender = e['sender'] as String? ?? '';
      final eventId = e['event_id'] as String? ?? '';
      final ts = DateTime.fromMillisecondsSinceEpoch(
        e['origin_server_ts'] as int? ?? 0,
        isUtc: true,
      ).toLocal();

          if (type.startsWith('m.room.message')) {
            final content = (e['content'] as Map<String, dynamic>? ?? const {});
            final msgtype = (content['msgtype'] as String?) ?? 'm.text';
            final body    = (content['body'] as String?) ?? '';

            if (msgtype == 'm.text') {
              result.add(Message(
                id: eventId,
                sender: sender,
                text: body,
                type: MessageType.text,
                timestamp: ts,
              ));
              continue;
            }

            if (msgtype == 'm.image') {
              final mxcUrl   = content['url'] as String?;
              final info     = (content['info'] as Map?)?.cast<String, dynamic>();
              final thumbMxc = info?['thumbnail_url'] as String?;
              final mime     = (info?['mimetype'] as String?) ?? 'image/*';
              final size     = (info?['size'] as num?)?.toInt();
              final mediaUrl = mxcToHttp(mxcUrl);
              final thumbUrl = mxcToHttp(thumbMxc, width: 512, height: 512, thumbnail: true);

              result.add(Message(
                id: eventId,
                sender: sender,
                text: body,
                type: MessageType.image,
                timestamp: ts,
                mediaUrl: mediaUrl,
                thumbUrl: thumbUrl ?? mediaUrl,
                fileName: body.isNotEmpty ? body : null,
                fileSize: size,
                mimeType: mime,
              ));
              continue;
            }

            if (msgtype == 'm.file') {
              final mxcUrl = content['url'] as String?;
              final info   = (content['info'] as Map?)?.cast<String, dynamic>();
              final mime   = (info?['mimetype'] as String?) ?? 'application/octet-stream';
              final size   = (info?['size'] as num?)?.toInt();
              final name   = body.isNotEmpty ? body : (content['filename'] as String?) ?? 'file';
              final mediaUrl = mxcToHttp(mxcUrl);

              result.add(Message(
                id: eventId,
                sender: sender,
                text: name,
                type: MessageType.file,
                timestamp: ts,
                mediaUrl: mediaUrl,
                fileName: name,
                fileSize: size,
                mimeType: mime,
              ));
              continue;
            }
          }

      if (type.startsWith('m.call.') && type != 'm.call.candidates') {
        String callText;
        if (type == 'm.call.invite')      callText = '📞 Звонок: приглашение';
        else if (type == 'm.call.answer') callText = '📞 Звонок: ответ';
        else if (type == 'm.call.hangup') callText = '📞 Звонок завершён';
        else                               callText = '📞 Событие звонка ($type)';

        result.add(Message(
          id:        eventId,
          sender:    sender,
          text:      callText,
          type:      MessageType.call,
          timestamp: ts,
        ));
      }
    }

    return result;
  }

  static Future<String?> sendMessage(String roomId, String text, {String? txnId}) async {
    final txn = txnId ?? DateTime.now().millisecondsSinceEpoch.toString();

    final uri = Uri.parse(
      '$_homeServerUrl/_matrix/client/r0/rooms/$roomId/send/m.room.message/$txn',
    );
    final payload = jsonEncode({'msgtype': 'm.text', 'body': text});

    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json','Authorization': 'Bearer $_accessToken'},
      body: payload,
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['event_id'] as String?;
    }
    print('sendMessage failed ${response.statusCode}: ${response.body}');
    return null;
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
      final eventId = e['event_id'] as String? ?? '';
      final ts = DateTime.fromMillisecondsSinceEpoch(
        e['origin_server_ts'] as int? ?? 0,
        isUtc: true,
      ).toLocal();

      if (type.startsWith('m.room.message')) {
        return Message(
          id:        eventId,
          sender:    e['sender'] as String? ?? '',
          text:      (e['content'] as Map)['body'] as String? ?? '',
          type:      MessageType.text,
          timestamp: ts,
        );
      }
      if (type.startsWith('m.call.') && type != 'm.call.candidates') {
        String txt;
        if (type == 'm.call.invite')    txt = '📞 Звонок приглашение';
        else if (type == 'm.call.answer') txt = '📞 Звонок ответ';
        else if (type == 'm.call.hangup') txt = '📞 Звонок завершён';
        else                              txt = '📞 Событие звонка';

        return Message(
          id:        eventId,
          sender:    e['sender'] as String? ?? '',
          text:      txt,
          type:      MessageType.call,
          timestamp: ts,
        );
      }
      return null;
    }
        final byId = <String, Map<String, dynamic>>{};
        for (final raw in olderRaw.reversed) {
          final id = raw['event_id'] as String?;
          if (id != null && id.isNotEmpty) byId[id] = raw;
        }
        for (final raw in initialTimeline) {
          final id = raw['event_id'] as String?;
          if (id != null && id.isNotEmpty) byId[id] = raw;
        }

        final all = <Message>[];
        for (final raw in byId.values) {
          final m = convert(raw);
          if (m != null) all.add(m);
        }
        all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return all;
  }

  static Future<bool> userExists(String userId) async {
    if (_accessToken == null) return false;
    final target = userId.startsWith('@')
        ? userId
        : '@$userId:${Uri.parse(_homeServerUrl).host}';
    final uri = Uri.parse(
      '$_homeServerUrl/_matrix/client/r0/profile/$target'
          '?access_token=$_accessToken',
    );
    final resp = await http.get(uri);
    return resp.statusCode == 200;
  }

  static Future<Room?> createDirectChat(String userId) async {
    if (_accessToken == null) return null;
    if (!await userExists(userId)) return null;

    final target = userId.startsWith('@')
        ? userId
        : '@$userId:${Uri.parse(_homeServerUrl).host}';
    final uri = Uri.parse(
        '$_homeServerUrl/_matrix/client/r0/createRoom?access_token=$_accessToken'
    );

        final payload = jsonEncode({
          'invite':    [target],
          'is_direct': true,
          'visibility':'private',
          'preset':    'trusted_private_chat',
        });

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

  static Map<String, String> getDirectRoomIdToUserIdMap() {
    final events = (_lastSyncResponse?['account_data']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ?? [];
    final directEvent = events
        .firstWhere((e) => e['type'] == 'm.direct', orElse: () => {});
    if (directEvent.isEmpty) return {};
    final content = directEvent['content'] as Map<String, dynamic>;
    final map = <String, String>{};
    content.forEach((user, rooms) {
      for (var r in (rooms as List)) {
        map[r] = user;
      }
    });
    return map;
  }

  static List<String> getDirectRoomIds() {
    final events = (_lastSyncResponse?['account_data']?['events']
    as List?)
        ?.cast<Map<String, dynamic>>() ?? [];
    final directEvent = events.firstWhere(
          (e) => e['type'] == 'm.direct',
      orElse: () => {},
    );
    if (directEvent.isEmpty) return [];
    final content = directEvent['content'] as Map<String, dynamic>;
    final List<String> rooms = [];
    for (var entry in content.values) {
      if (entry is List) rooms.addAll(entry.cast<String>());
    }
    return rooms;
  }

  static Future<String> getUserDisplayName(String userId) async {
    if (_accessToken == null) return _localPart(userId);
    final uri = Uri.parse('$_homeServerUrl/_matrix/client/v3/profile/$userId');
    final resp = await http.get(uri, headers: {
      'Authorization': 'Bearer $_accessToken',
      'Content-Type':  'application/json',
    });
    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return data['displayname'] as String? ?? _localPart(userId);
    }
    return _localPart(userId);
  }

  static Future<bool> leaveRoom(String roomId) async {
    if (_accessToken == null) return false;
    final uri = Uri.parse('$_homeServerUrl/_matrix/client/r0/rooms/$roomId/leave');
    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({}),
    );
    return resp.statusCode == 200 || resp.statusCode == 201;
  }

  static Future<bool> setDirectRooms(Map<String, List<String>> directMap) async {
    if (_accessToken == null || _fullUserId == null) return false;
    final uri = Uri.parse(
        '$_homeServerUrl/_matrix/client/r0/user/$_fullUserId/account_data/m.direct'
    );
    final resp = await http.put(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: jsonEncode(directMap),
    );
    print('DEBUG setDirectRooms → ${resp.statusCode}: ${resp.body}');
    return resp.statusCode == 200;
  }

  static String? mxcToHttp(String? mxc, {int? width, int? height, bool thumbnail = false}) {
    if (mxc == null || !mxc.startsWith('mxc://')) return null;
    final noScheme = mxc.substring('mxc://'.length);
    final parts = noScheme.split('/');
    if (parts.length < 2) return null;
    final server = parts[0];
    final mediaId = parts.sublist(1).join('/');

    if (thumbnail && width != null && height != null) {
      return '$homeserverBase/_matrix/media/v3/thumbnail/$server/$mediaId'
          '?width=$width&height=$height&method=scale';
    }
    return '$homeserverBase/_matrix/media/v3/download/$server/$mediaId';
  }

  static Future<String?> sendFile(String roomId, String name, List<int> bytes, String mime) async {
    final room = client.getRoomById(roomId);
    if (room == null) return null;

    final uri = await client.uploadContent(
      Uint8List.fromList(bytes),
      contentType: mime,
      filename: name,
    );

    final content = {
      'msgtype': 'm.file',
      'body': name,
      'filename': name,
      'url': uri,
      'info': {'mimetype': mime, 'size': bytes.length},
    };

    final resp = await room.sendEvent(content, type: 'm.room.message');
    return resp;
  }

  static Future<String?> sendImage(String roomId, String name, List<int> bytes, String mime) async {
    final room = client.getRoomById(roomId);
    if (room == null) return null;

    final uri = await client.uploadContent(
      Uint8List.fromList(bytes),
      contentType: mime,
      filename: name,
    );

    final content = {
      'msgtype': 'm.image',
      'body': name,
      'url': uri,
      'info': {'mimetype': mime, 'size': bytes.length},
    };

    final resp = await room.sendEvent(content, type: 'm.room.message');
    return resp;
  }
}