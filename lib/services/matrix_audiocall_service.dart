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
    onStatus('Loading config…');
    final config = await loadConfig().catchError((e) {
      onStatus('Failed to load config: $e');
      return Future<AppConfig?>.value(null);
    });
    if (config == null) return;

    onStatus('Initializing Matrix client…');
    _disposeMatrixClientIfNeeded();

    // 1) Получаем доступ к микрофону
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      return onStatus('Microphone permission denied');
    }

    // 2) Логинимся в Matrix
    _matrixClient = Client('CallServiceClient')..backgroundSync = true;
    await _matrixClient!.init();
    await _matrixClient!.checkHomeserver(Uri.parse(config.homeserver));
    final login = await _matrixClient!.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: AuthDataCall.instance.login),
      password: AuthDataCall.instance.password,
    );
    _loggedInUserId = login.userId;
    onStatus('Logged in as $_loggedInUserId');

    // 3) Активируем синхронизацию и слушаем события
    _matrixClient!
      ..sync()
      ..onEvent.stream.listen(_handleEvent, onError: (e) => debugPrint('Sync error: $e'));

    onStatus('Accessing local media…');
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': false,
    });

    final cfg = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:webqalqan.com:3478',
          'username': 'turnuser',
          'credential': 'turnpass',
        }
      ]
    };
    _peerConnection = await createPeerConnection(cfg, {
      'sdpSemantics': 'unified-plan',
    });

    for (var track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    _peerConnection!
      ..onTrack = (RTCTrackEvent e) {
        if (e.streams.isNotEmpty) onAddRemoteStream(e.streams[0]);
      }
      ..onIceCandidate = (candidate) {
        if (candidate.candidate != null) _sendIce(roomId, candidate);
      }
      ..onIceGatheringState = (state) {
        debugPrint('ICE gathering state: $state');
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          _sendIce(roomId, null);
        }
      }
      ..onIceConnectionState = (state) {
        debugPrint('ICE connection state: $state');
        if (state ==
            RTCIceConnectionState.RTCIceConnectionStateConnected) {
          onStatus('Connected');
        }
      };

    _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    _partyId = 'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';

    onStatus('Creating offer…');
    final offer = await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(offer);

    final invite = {
      'call_id': _callId,
      'lifetime': 60000,
      'offer': {'type': offer.type, 'sdp': offer.sdp},
      'version': 1,
      'party_id': _partyId,
    };
    final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
    await _matrixClient!.sendMessage(roomId, 'm.call.invite', txn, invite);

    onStatus('Connecting…');
  }


  void _handleEvent(EventUpdate update) {
    switch (update.type) {
      case 'm.call.answer':
        _handleAnswer(update.content as Map<String, dynamic>);
        break;
      case 'm.call.candidates':
        _handleCandidates(update.content as Map<String, dynamic>);
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
      'version': 1,
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