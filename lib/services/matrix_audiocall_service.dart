import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:matrix/matrix.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qalqan_dsm/services/auth_data.dart';

@immutable
class AppConfig {
  final String homeserver;
  final String username;
  final String password;
  final String roomId;

  const AppConfig({
    required this.homeserver,
    required this.username,
    required this.password,
    required this.roomId,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
    homeserver: json['homeserver'] as String,
    username:   json['username']   as String,
    password:   json['password']   as String,
    roomId:     json['room_id']    as String,
  );
}

Future<AppConfig> loadConfig() async {
  final raw = await rootBundle.loadString('assets/config.json');
  final data = json.decode(raw) as Map<String, dynamic>;
  return AppConfig.fromJson(data);
}

class CallService {
  final void Function(String status) onStatus;
  final void Function(MediaStream stream) onAddRemoteStream;

  Client? _matrixClient;
  String? _loggedInUserId, _callId, _partyId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final List<RTCIceCandidate> _iceQueue = [];
  Client get matrixClient => _matrixClient!;

  MediaStream? get localStream => _localStream;

  CallService({
    required this.onStatus,
    required this.onAddRemoteStream,
  });

  Future<void> startCall({ required String roomId }) async {
    onStatus('Loading config...');
    late AppConfig config;
    try {
      config = await loadConfig();
    } catch (e) {
      onStatus('Failed to load config: $e');
      return;
    }

    onStatus('Initializing Matrix client...');
    if (_matrixClient != null) {
      await _matrixClient!.logout().catchError((_) {});
      _matrixClient!.dispose();
      _matrixClient = null;
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      onStatus('Microphone permission denied');
      return;
    }

    final client = Client('CallServiceClient');
    _matrixClient = client;

    try {
      await client.init();
      await client.checkHomeserver(Uri.parse(config.homeserver));
      final login = await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: AuthDataCall.instance.login),
        password: AuthDataCall.instance.password,
      );
      _loggedInUserId = login.userId;
      if (_loggedInUserId == null || _loggedInUserId!.isEmpty) {
        onStatus('Login succeeded but no userId');
        return;
      }
      onStatus('Logged in as $_loggedInUserId');

      final room = client.getRoomById(roomId);
      if (room == null) {
        onStatus('Room not found: $roomId');
        return;
      }

      client.sync().catchError((e) => debugPrint('Sync error: $e'));
      client.onEvent.stream.listen(_handleEvent);

      onStatus('Accessing local media...');
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true},
        'video': false,
      });

      final cfg = {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {
            'urls': 'turn:your.turn.server:3478',
            'username': 'turnuser',
            'credential': 'turnpass',
          }
        ]
      };
      _peerConnection = await createPeerConnection(cfg, {});
      _localStream!.getTracks().forEach((track) {
        _peerConnection?.addTrack(track, _localStream!);
      });

      _peerConnection!.onAddStream = (MediaStream stream) {
        onAddRemoteStream(stream);
      };

      _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
      _partyId = 'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';

      onStatus('Creating offer...');
      final offer = await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
      await _peerConnection!.setLocalDescription(offer);


      _peerConnection!.onIceCandidate = (RTCIceCandidate cand) {
        if (cand.candidate != null) _sendIce(roomId, cand);
      };

      final invite = {
        'call_id': _callId,
        'lifetime': 60000,
        'offer': {'type': 'offer', 'sdp': offer.sdp},
        'version': '1',
        'party_id': _partyId,
      };
      final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
      await client.sendMessage(roomId, 'm.call.invite', txn, invite);
      onStatus('Connecting…');
    } on MatrixException catch (e) {
      onStatus('Matrix error: $e');
    } catch (e) {
      onStatus('Unexpected error: $e');
    }
  }

  void _handleEvent(EventUpdate update) {
    final raw  = update.content as Map<String, dynamic>;
    final type = raw['type'] as String?;
    if (type == 'm.call.answer') {
      _handleAnswer(raw['content']);
    } else if (type == 'm.call.candidates') {
      _handleCandidates(raw['content']);
    } else if (type == 'm.call.hangup') {
      onStatus('Call ended');
      _peerConnection?.close();
      _localStream?.dispose();
    }
  }

  Future<void> _handleAnswer(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final answer = data['answer'] as Map<String, dynamic>?;
    if (answer == null) return;
    final sdp  = answer['sdp']  as String?;
    final type = answer['type'] as String?;
    if (sdp == null || type == null) return;
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(sdp, type));
    for (var c in _iceQueue) {
      await _peerConnection?.addCandidate(c);
    }
    _iceQueue.clear();
    onStatus('Connected');
  }

  Future<void> _handleCandidates(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final list = data['candidates'] as List<dynamic>?;
    if (list == null) return;
    for (var it in list) {
      final m = it as Map<String, dynamic>;
      final cand = m['candidate'] as String?;
      final mid  = m['sdpMid']   as String?;
      final idx  = m['sdpMLineIndex'] as int?;
      if (cand == null || mid == null || idx == null) continue;
      final ice = RTCIceCandidate(cand, mid, idx);
      final remoteDesc = await _peerConnection?.getRemoteDescription();
      if (remoteDesc == null) {
        _iceQueue.add(ice);
      } else {
        await _peerConnection?.addCandidate(ice);
      }
    }
  }

  Future<void> _sendIce(String roomId, RTCIceCandidate c) async {
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
    await _matrixClient!.sendMessage(roomId, 'm.call.candidates', txn, body);
  }

  Future<void> dispose() async {
    await _matrixClient?.logout().catchError((_) {});
    _matrixClient?.dispose();
    _peerConnection?.close();
    _localStream?.dispose();
  }
}

extension CallServiceAnswer on CallService {
  /// Принимает входящий звонок:
  /// 1) устанавливает remoteDescription из offer,
  /// 2) генерирует SDP-ответ и отправляет его в Matrix
  Future<void> answerCall({
    required String roomId,
    required String callId,
    required Map<String, dynamic> offer,
  }) async {
    // 1) Устанавливаем удалённое описание из приглашения
    final sdp  = offer['sdp']  as String;
    final type = offer['type'] as String;
    await _peerConnection?.setRemoteDescription(RTCSessionDescription(sdp, type));

    // 2) Создаём ответ
    final answer = await _peerConnection!.createAnswer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(answer);

    // ICE-кандидаты будут собираться в onIceCandidate и отправляться отдельно

    // 3) Отправляем m.call.answer
    final body = {
      'call_id': callId,
      'answer': {
        'type': answer.type,
        'sdp': answer.sdp,
      },
      'version': '1',
      'party_id': _partyId,
    };
    final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
    await _matrixClient!.sendMessage(roomId, 'm.call.answer', txn, body);

    onStatus('Call accepted');
  }
}
