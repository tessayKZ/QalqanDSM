import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/auth_service.dart';

class CallService {
  final void Function(String status) onStatus;
  final void Function(MediaStream stream) onAddRemoteStream;

  Client? _matrixClient;
  String? _loggedInUserId;
  String? _currentRoomId;
  String? _callId;
  String? _partyId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  StreamSubscription<EventUpdate>? _eventSub;
  bool _clientInitialized = false;

  CallService({
    required this.onStatus,
    required this.onAddRemoteStream,
  });

  /// Инициализируем клиент один раз: запускаем sync и подписываемся на события
  Future<void> _initClient() async {
    if (_clientInitialized) return;

    final client = AuthService.client;
    final userId = AuthService.userId;
    if (client == null || userId == null) {
      throw StateError(
          'Matrix client или userId не инициализированы. Выполните логин через AuthService.'
      );
    }
    _matrixClient = client;
    _loggedInUserId = userId;

    onStatus('Initializing call service…');

    // Запускаем синхронизацию
    _matrixClient!.sync().catchError((e) => debugPrint('Sync error: $e'));
    // Подписываемся на все события, будем фильтровать по roomId
    _eventSub = _matrixClient!.onEvent.stream.listen(
      _handleEvent,
      onError: (e) => debugPrint('Event stream error: $e'),
    );

    _clientInitialized = true;
  }

  /// Запускаем исходящий звонок
  Future<void> startCall({required String roomId}) async {
    onStatus('Requesting microphone…');
    if (!await Permission.microphone.request().isGranted) {
      onStatus('Microphone denied');
      return;
    }

    await _initClient();
    _currentRoomId = roomId;

    onStatus('Accessing room…');
    final room = _matrixClient!.getRoomById(roomId);
    if (room == null) {
      onStatus('Room not found: $roomId');
      return;
    }

    onStatus('Accessing local media…');
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': false,
    });

    onStatus('Creating PeerConnection…');
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:webqalqan.com:3478',
          'username': 'turnuser',
          'credential': 'turnpass',
        },
      ],
    };
    _peerConnection = await createPeerConnection(config, {});

    // Добавляем локальные треки
    for (var track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // Подписываемся на удалённый поток (старый API)
    _peerConnection!.onAddStream = (MediaStream remote) {
      onAddRemoteStream(remote);
    };

    // Генерация уникальных ID
    final cleanUser = _loggedInUserId!
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    _partyId = 'dart_${cleanUser}_${DateTime.now().millisecondsSinceEpoch}';

    onStatus('Creating offer…');
    final offer = await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(offer);

    // ICE-кандидаты «на лету»
    _peerConnection!.onIceCandidate = (RTCIceCandidate cand) {
      if (cand.candidate != null) {
        _sendIce(roomId, cand);
      }
    };

    // Отправка приглашения
    final invite = {
      'call_id': _callId,
      'party_id': _partyId,
      'version': '1',
      'lifetime': 60000,
      'offer': {'type': offer.type, 'sdp': offer.sdp},
    };
    final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
    await _matrixClient!
        .sendMessage(roomId, 'm.call.invite', txn, invite);

    onStatus('Connecting…');
  }

  /// Обработчик всех incoming-событий
  void _handleEvent(EventUpdate update) {
    // фильтруем по комнате
    if (update.roomId != _currentRoomId) return;
    final raw = update.content as Map<String, dynamic>;
    final type = raw['type'] as String?;
    final content = raw['content'];

    switch (type) {
      case 'm.call.answer':
        _handleAnswer(content);
        break;
      case 'm.call.candidates':
        _handleCandidates(content);
        break;
      case 'm.call.hangup':
        onStatus('Call ended');
        _peerConnection?.close();
        _localStream?.dispose();
        break;
      default:
        break;
    }
  }

  /// Устанавливаем remote SDP из ответа
  Future<void> _handleAnswer(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final answer = data['answer'] as Map<String, dynamic>?;
    if (answer == null) return;
    final sdp = answer['sdp'] as String?;
    final type = answer['type'] as String?;
    if (sdp == null || type == null) return;
    await _peerConnection
        ?.setRemoteDescription(RTCSessionDescription(sdp, type));
    onStatus('Connected');
  }

  /// Добавляем remote ICE-кандидаты
  Future<void> _handleCandidates(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final list = data['candidates'] as List<dynamic>?;
    if (list == null) return;
    for (var it in list) {
      final m = it as Map<String, dynamic>;
      final cand = m['candidate'] as String?;
      final mid = m['sdpMid'] as String?;
      final idx = m['sdpMLineIndex'] as int?;
      if (cand != null && mid != null && idx != null) {
        await _peerConnection?.addCandidate(
          RTCIceCandidate(cand, mid, idx),
        );
      }
    }
  }

  /// Отправка ICE-кандидата в комнату
  Future<void> _sendIce(
      String roomId,
      RTCIceCandidate c,
      ) async {
    if (_matrixClient == null || _callId == null || _partyId == null) return;
    final body = {
      'call_id': _callId,
      'party_id': _partyId,
      'version': '1',
      'candidates': [
        {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        }
      ],
    };
    final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
    await _matrixClient!
        .sendMessage(roomId, 'm.call.candidates', txn, body);
  }

  /// Завершение звонка: отменяем слушателя и очищаем ресурсы
  Future<void> dispose() async {
    await _eventSub?.cancel();
    _clientInitialized = false;

    _peerConnection?.close();
    _localStream?.dispose();
  }
}
