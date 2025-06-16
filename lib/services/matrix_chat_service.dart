/// File: lib/services/matrix_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/room.dart';
import '../models/message.dart';

/// Сервис для логина, sync, получения списка комнат и сообщений, а также отправки.
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

  /// Логинимся на Matrix-сервере (m.login.password).
  /// При успешном логине сохраняет _accessToken и _fullUserId,
  /// а затем вызывает syncOnce(), чтобы получить раздел rooms.join.
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

      // Первый sync после логина
      await syncOnce();
      return true;
    } else {
      print('Login failed ${response.statusCode}: ${response.body}');
      return false;
    }
  }

  /// Публичный метод для однократного sync (GET /sync?timeout=30000).
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

    // формируем GET-параметры
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
      // сохраняем новый токен для next_batch
      _nextBatch = decoded['next_batch'] as String?;
      print('>>> New next_batch=$_nextBatch');
    } else {
      print('SYNC failed ${response.statusCode}: ${response.body}');
    }
  }

  /// Запускает «вечный» цикл sync каждые [intervalMs] миллисекунд.
  static Future<void> startSyncLoop({int intervalMs = 5000}) async {
    if (_syncing) return;
    _syncing = true;
    while (_syncing) {
      await _doSync();
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
  }

  /// Останавливает «вечный» syncLoop.
  static void stopSyncLoop() {
    _syncing = false;
  }

  /// Возвращает список комнат, в которых пользователь «joined» (resp['rooms']['join']).
  static List<Room> getJoinedRooms() {
    final resp = _lastSyncResponse;
    if (resp == null) return [];

    final roomsSection = resp['rooms']?['join'] as Map<String, dynamic>?;
    if (roomsSection == null) return [];

    final List<Room> result = [];
    roomsSection.forEach((roomId, roomDataRaw) {
      final roomData = roomDataRaw as Map<String, dynamic>;

      // 1) Получаем имя комнаты из state.events, если есть m.room.name
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

      // 2) Находим последнее сообщение (m.room.message) для отображения «последнего сообщения» в списке комнат
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

  /// Возвращает из последнего /sync список событий (сообщений и звонков) указанной комнаты.
  ///
  /// — Игнорирует все m.call.candidates
  /// — Если есть invite + hangup без answer → добавляет ровно одно «📞 Пропущенный звонок»
  /// — Иначе отображает остальные звонковые события в порядке timeline
  static List<Message> getRoomMessages(String roomId) {
    final resp = _lastSyncResponse;
    if (resp == null) return [];

    final roomSection = resp['rooms']?['join']?[roomId] as Map<String, dynamic>?;
    if (roomSection == null) return [];

    final timelineEvents = roomSection['timeline']?['events'] as List<dynamic>?;
    if (timelineEvents == null) return [];

    final List<Message> result = [];

    // 1) Проверяем, есть ли «invite + hangup без answer» → отметим, что это пропущенный звонок.
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
      // Найдём первый invite, чтобы взять sender
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
      // Пропущенные звонки не комбинируем с другими звонковыми событиями
    }

    // 2) Добавляем все текстовые сообщения (m.room.message)
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

    // 3) Если это НЕ пропущенный звонок (missedCall == false), добавляем остальные звонковые события
    if (!missedCall) {
      for (var e in timelineEvents) {
        final event = e as Map<String, dynamic>;
        final eventType = event['type'] as String? ?? '';

        if (eventType.startsWith('m.call.')) {
          // Игнорируем кандидатов ICE
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

  /// Отправляет текстовое сообщение (m.room.message) и сразу делает _doSync(), чтобы получить его из сервера.
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
      // Сразу делаем синхронизацию, чтобы сообщение появилось в кеше
      await _doSync();
    }
  }
  static Future<void> sendCallInvite({
    required String roomId,
    required String callId,
    required String partyId,
    required String offer,
    required String sdpType,
  }) async {
    if (_accessToken == null) return;
    final txn = DateTime.now().millisecondsSinceEpoch.toString();
    await http.put(
      Uri.parse('$_homeServerUrl/_matrix/client/r0/rooms/$roomId/send/m.call.invite/$txn'),
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'call_id': callId,
        'lifetime': 60000,
        'version': '1',
        'party_id': partyId,
        'offer': {'type': sdpType, 'sdp': offer},
      }),
    );
  }

  /// Отправка m.call.candidates
  static Future<void> sendCallCandidates({
    required String roomId,
    required String callId,
    required String partyId,
    required List<Map<String, dynamic>> candidates,
  }) async {
    if (_accessToken == null) return;
    final txn = DateTime.now().millisecondsSinceEpoch.toString();
    await http.put(
      Uri.parse('$_homeServerUrl/_matrix/client/r0/rooms/$roomId/send/m.call.candidates/$txn'),
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'call_id': callId,
        'version': '1',
        'party_id': partyId,
        'candidates': candidates,
      }),
    );
  }

  /// Грузит всю историю (старые сообщения + звонки) для комнаты [roomId],
  /// возвращает список сообщений от старых к новым.
  static Future<List<Message>> fetchRoomHistory(String roomId) async {
    if (_accessToken == null) return [];

    // Initial sync — сбрасываем prev_batch и делаем обычный sync
    await syncOnce();

    // Вынимаем из последнего ответа timeline из указанной комнаты
    final roomSection = _lastSyncResponse?['rooms']?['join']?[roomId]
    as Map<String, dynamic>?;
    if (roomSection == null) return [];

    // Берём события из последнего initial‐sync (последние N)
    final initialTimeline = (roomSection['timeline']?['events'] as List?)
        ?.cast<Map<String, dynamic>>() ??
        [];

    // Смотрим на prev_batch, откуда пойдём назад
    String? prevBatch = roomSection['timeline']?['prev_batch'] as String?;

    // Собираем более старые события через /messages?dir=b
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

    // Конвертер raw→Message
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
    // Сначала самые старые
    for (var raw in olderRaw.reversed) {
      final m = convert(raw);
      if (m != null) all.add(m);
    }
    // Потом последние N
    for (var raw in initialTimeline) {
      final m = convert(raw);
      if (m != null) all.add(m);
    }
    return all;
  }
}