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
  static final Map<String, dynamic> _joinedRoomsSnapshot = <String, dynamic>{};
  static Map<String, dynamic>? _mDirectCache;
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
    _joinedRoomsSnapshot.clear();
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
      _applySyncData(decoded);
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
      _applySyncData(decoded);
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

  static void _applySyncData(Map<String, dynamic> decoded) {
    _lastSyncResponse = decoded;
    _nextBatch = decoded['next_batch'] as String?;

    final rooms = decoded['rooms'] as Map<String, dynamic>?;
    if (rooms != null) {
      final join = rooms['join'] as Map<String, dynamic>?;
      if (join != null) {
        join.forEach((roomId, roomData) {
          _joinedRoomsSnapshot[roomId] = roomData;
        });
      }
      final leave = rooms['leave'] as Map<String, dynamic>?;
      if (leave != null) {
        for (final roomId in leave.keys) {
          _joinedRoomsSnapshot.remove(roomId);
        }
      }
    }

    final events = (decoded['account_data']?['events'] as List?)
        ?.cast<Map<String, dynamic>>();
    if (events != null) {
      final direct = events.firstWhere(
            (e) => e['type'] == 'm.direct',
        orElse: () => {},
      );
      if (direct.isNotEmpty) {
        _mDirectCache = direct['content'] as Map<String, dynamic>?;
      }
    }
  }

  static List<Room> getJoinedRooms() {
    if (_joinedRoomsSnapshot.isEmpty) return [];

    final roomsSection = _joinedRoomsSnapshot;
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
        lastMsg = (timelineEvents.reversed.firstWhere(
              (e) {
            final t = ((e as Map<String, dynamic>)['type'] as String?) ?? '';
            return t == 'm.room.message' || t == 'm.room.encrypted' || t.startsWith('m.call.');
              },
          orElse: () => null,
        ) as Map<String, dynamic>?);
      }

      result.add(Room(id: roomId, name: name, lastMessage: lastMsg));
    });

    return result;
  }

  static List<Message> getRoomMessages(String roomId) {
    final resp = _lastSyncResponse;
    if (resp == null) return [];

    final roomSection = resp['rooms']?['join']?[roomId] as Map<String, dynamic>?;
    if (roomSection == null) return [];

    final events = (roomSection['timeline']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ??
        [];

    events.sort((a, b) =>
        ((a['origin_server_ts'] as int?) ?? 0).compareTo((b['origin_server_ts'] as int?) ?? 0));

    final List<Message> result = [];

    final myId = _fullUserId ?? '';
    final Map<String, Map<String, dynamic>> callInvites = {};
    final Map<String, Map<String, dynamic>> callAnswers = {};
    final Map<String, Map<String, dynamic>> callHangups = {};

    String _fmtDur(int ms) {
      if (ms <= 0) return '00:00';
      final d = Duration(milliseconds: ms);
      final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$mm:$ss';
    }

    for (var e in events) {
      final type = e['type'] as String? ?? '';
      final sender = e['sender'] as String? ?? '';
      final eventId = e['event_id'] as String? ?? '';
      final ts = DateTime.fromMillisecondsSinceEpoch(
        (e['origin_server_ts'] as int?) ?? 0,
        isUtc: true,
      ).toLocal();

      if (type.startsWith('m.room.message')) {
        final content = (e['content'] as Map<String, dynamic>? ?? const {});
        final msgtype = (content['msgtype'] as String?) ?? 'm.text';
        final body = (content['body'] as String?) ?? '';

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
          final mxcUrl = content['url'] as String?;
          final info = (content['info'] as Map?)?.cast<String, dynamic>();
          final thumbMxc = info?['thumbnail_url'] as String?;
          final mime = (info?['mimetype'] as String?) ?? 'image/*';
          final size = (info?['size'] as num?)?.toInt();
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
          final info = (content['info'] as Map?)?.cast<String, dynamic>();
          final mime = (info?['mimetype'] as String?) ?? 'application/octet-stream';
          final size = (info?['size'] as num?)?.toInt();
          final name = body.isNotEmpty ? body : (content['filename'] as String?) ?? 'file';
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

      if (type == 'm.room.encrypted') {
        result.add(Message(
          id: eventId,
          sender: sender,
          text: '🔒 Encrypted message',
          type: MessageType.text,
          timestamp: ts,
        ));
        continue;
      }

      if (type.startsWith('m.call.') && type != 'm.call.candidates') {
        final content = (e['content'] as Map?)?.cast<String, dynamic>() ?? const {};
        final callId = content['call_id'] as String?;
        if (callId != null && callId.isNotEmpty) {
          if (type == 'm.call.invite') {
            callInvites[callId] = e;
          } else if (type == 'm.call.answer') {
            callAnswers[callId] = e;
          } else if (type == 'm.call.hangup') {
            callHangups[callId] = e;
          }
        }
        continue;
      }
    }

    for (final entry in callInvites.entries) {
      final callId = entry.key;
      final inv = entry.value;
      final ans = callAnswers[callId];
      final han = callHangups[callId];

      final inviter = inv['sender'] as String? ?? '';
      final incoming = inviter != myId;

      final inviteTs = (inv['origin_server_ts'] as int?) ?? 0;
      final answerTs = (ans?['origin_server_ts'] as int?);
      final hangupTs = (han?['origin_server_ts'] as int?);

      late final DateTime stamp;
      if (hangupTs != null) {
        stamp = DateTime.fromMillisecondsSinceEpoch(hangupTs, isUtc: true).toLocal();
      } else if (answerTs != null) {
        stamp = DateTime.fromMillisecondsSinceEpoch(answerTs, isUtc: true).toLocal();
      } else {
        stamp = DateTime.fromMillisecondsSinceEpoch(inviteTs, isUtc: true).toLocal();
      }

      String text;
      if (answerTs != null) {
        final end = hangupTs ?? answerTs;
        final durMs = (end - answerTs).clamp(0, 1 << 30);
        final dur = _fmtDur((durMs is int) ? durMs : (durMs as num).toInt());
        text = incoming
            ? '📥 Incoming call, $dur'
            : '📤 Outgoing call, $dur';
      } else {
        text = incoming
            ? '📵 Missed incoming call'
            : '🚫 Outgoing (no answer)';
      }

      result.add(Message(
        id: 'call_$callId',
        sender: inviter,
        text: text,
        type: MessageType.call,
        timestamp: stamp,
      ));
    }

    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
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

    final rawAll = <Map<String, dynamic>>[
      ...olderRaw,
      ...initialTimeline,
    ];
    rawAll.sort((a, b) =>
        ((a['origin_server_ts'] as int?) ?? 0).compareTo((b['origin_server_ts'] as int?) ?? 0));

    final myId = _fullUserId ?? '';
    final List<Message> out = [];

    final Map<String, Map<String, dynamic>> callInvites = {};
    final Map<String, Map<String, dynamic>> callAnswers = {};
    final Map<String, Map<String, dynamic>> callHangups = {};

    String _fmtDur(int ms) {
      if (ms <= 0) return '00:00';
      final d = Duration(milliseconds: ms);
      final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$mm:$ss';
    }

    for (final e in rawAll) {
      final type = e['type'] as String? ?? '';
      final sender = e['sender'] as String? ?? '';
      final eventId = e['event_id'] as String? ?? '';
      final ts = DateTime.fromMillisecondsSinceEpoch(
        (e['origin_server_ts'] as int?) ?? 0,
        isUtc: true,
      ).toLocal();

      if (type.startsWith('m.call.') && type != 'm.call.candidates') {
        final content = (e['content'] as Map?)?.cast<String, dynamic>() ?? const {};
        final callId = content['call_id'] as String?;
        if (callId != null && callId.isNotEmpty) {
          if (type == 'm.call.invite') {
            callInvites[callId] = e;
          } else if (type == 'm.call.answer') {
            callAnswers[callId] = e;
          } else if (type == 'm.call.hangup') {
            callHangups[callId] = e;
          }
        }
        continue;
      }

      if (type.startsWith('m.room.message')) {
        final content = (e['content'] as Map<String, dynamic>? ?? const {});
        final msgtype = (content['msgtype'] as String?) ?? 'm.text';
        final body = (content['body'] as String?) ?? '';

        if (msgtype == 'm.text') {
          out.add(Message(
            id: eventId,
            sender: sender,
            text: body,
            type: MessageType.text,
            timestamp: ts,
          ));
          continue;
        }

        if (msgtype == 'm.image') {
          final mxcUrl = content['url'] as String?;
          final info = (content['info'] as Map?)?.cast<String, dynamic>();
          final thumbMxc = info?['thumbnail_url'] as String?;
          final mime = (info?['mimetype'] as String?) ?? 'image/*';
          final size = (info?['size'] as num?)?.toInt();
          final mediaUrl = mxcToHttp(mxcUrl);
          final thumbUrl = mxcToHttp(thumbMxc, width: 512, height: 512, thumbnail: true);

          out.add(Message(
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
          final info = (content['info'] as Map?)?.cast<String, dynamic>();
          final mime = (info?['mimetype'] as String?) ?? 'application/octet-stream';
          final size = (info?['size'] as num?)?.toInt();
          final name = body.isNotEmpty ? body : (content['filename'] as String?) ?? 'file';
          final mediaUrl = mxcToHttp(mxcUrl);

          out.add(Message(
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

      if (type == 'm.room.encrypted') {
        out.add(Message(
          id: eventId,
          sender: sender,
          text: '🔒 Encrypted message',
          type: MessageType.text,
          timestamp: ts,
        ));
        continue;
      }
    }

    for (final entry in callInvites.entries) {
      final callId = entry.key;
      final inv = entry.value;
      final ans = callAnswers[callId];
      final han = callHangups[callId];

      final inviter = inv['sender'] as String? ?? '';
      final incoming = inviter != myId;

      final inviteTs = (inv['origin_server_ts'] as int?) ?? 0;
      final answerTs = (ans?['origin_server_ts'] as int?);
      final hangupTs = (han?['origin_server_ts'] as int?);

      late final DateTime stamp;
      if (hangupTs != null) {
        stamp = DateTime.fromMillisecondsSinceEpoch(hangupTs, isUtc: true).toLocal();
      } else if (answerTs != null) {
        stamp = DateTime.fromMillisecondsSinceEpoch(answerTs, isUtc: true).toLocal();
      } else {
        stamp = DateTime.fromMillisecondsSinceEpoch(inviteTs, isUtc: true).toLocal();
      }

      String text;
      if (answerTs != null) {
        final end = hangupTs ?? answerTs;
        final durMs = (end - answerTs).clamp(0, 1 << 30);
        final dur = _fmtDur((durMs is int) ? durMs : (durMs as num).toInt());
        text = incoming
            ? '📥 Incoming call, $dur'
            : '📤 Outgoing call, $dur';
      } else {
        text = incoming
            ? '📵 Missed incoming call'
            : '🚫 Outgoing (no answer)';
      }

      out.add(Message(
        id: 'call_$callId',
        sender: inviter,
        text: text,
        type: MessageType.call,
        timestamp: stamp,
      ));
    }

    out.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return out;
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
    Map<String, dynamic>? content;

    final events = (_lastSyncResponse?['account_data']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ?? [];
    final directEvent = events.firstWhere(
          (e) => e['type'] == 'm.direct',
      orElse: () => {},
    );
    if (directEvent.isNotEmpty) {
      content = directEvent['content'] as Map<String, dynamic>?;
      _mDirectCache = content;
    } else {
      content = _mDirectCache;
    }
    if (content == null) return {};

    final map = <String, String>{};
    content.forEach((userId, rooms) {
      for (final r in (rooms as List)) {
        map[r as String] = userId as String;
      }
    });
    return map;
  }

  static List<String> getDirectRoomIds() {
    Map<String, dynamic>? content;

    final events = (_lastSyncResponse?['account_data']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ?? [];
    final directEvent = events.firstWhere(
          (e) => e['type'] == 'm.direct',
      orElse: () => {},
    );
    if (directEvent.isNotEmpty) {
      content = directEvent['content'] as Map<String, dynamic>?;
      _mDirectCache = content;
    } else {
      content = _mDirectCache;
    }
    if (content == null) return [];

    final ids = <String>[];
    for (final entry in content.values) {
      if (entry is List) ids.addAll(entry.cast<String>());
    }
    return ids;
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
      '$_homeServerUrl/_matrix/client/r0/user/$_fullUserId/account_data/m.direct',
    );

    final resp = await http.put(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_accessToken',
      },
      body: jsonEncode(directMap),
    );

    final ok = resp.statusCode == 200;
    if (ok) {
      _mDirectCache = directMap;
    }
    return ok;
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