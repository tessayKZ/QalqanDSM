import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/auth_data.dart';
import '../services/matrix_auth.dart';

class CallService {
    final void Function(String status) onStatus;
    final void Function(MediaStream stream) onAddRemoteStream;

  Client? _matrixClient;
  String? _loggedInUserId;
  String? _callId;
  String? _partyId;
  String? _roomId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final List<RTCIceCandidate> _iceQueue = [];

  MediaStream? get localStream => _localStream;

  CallService({
    required this.onStatus,
    required this.onAddRemoteStream,
  });

  Future<void> startCall({ required String roomId }) async {
    _roomId = roomId;
    onStatus('Requesting microphone…');
    if (!await Permission.microphone.request().isGranted) {
      onStatus('Microphone denied');
      return;
    }

    onStatus('Logging in call client…');
    final auth = AuthDataCall.instance;
    if (auth.login.isEmpty || auth.password.isEmpty) {
      onStatus('No credentials for call service');
      return;
    }
    final ok = await AuthService.login(user: auth.login, password: auth.password);
    if (!ok || AuthService.client == null || AuthService.userId == null) {
      onStatus('Call login failed');
      return;
    }
    _matrixClient = AuthService.client;
    _loggedInUserId = AuthService.userId;
    onStatus('Logged in as $_loggedInUserId');

    _matrixClient!
        .sync()
        .catchError((e) => debugPrint('Sync error: $e'));
    _matrixClient!.onEvent.stream.listen(_handleEvent, onError: (e) {
      debugPrint('Event stream error: $e');
    });

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
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });
    _peerConnection!.onAddStream = (stream) {
      onAddRemoteStream(stream);
    };

    _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    _partyId = 'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';
    AuthDataCall.instance.outgoingCallIds.add(_callId!);

    onStatus('Creating offer…');
    final offer = await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(offer);

    _peerConnection!.onIceCandidate = (cand) {
      if (cand.candidate != null) {
        _sendIce(roomId, cand);
      }
    };

    final invite = {
      'call_id': _callId,
      'party_id': _partyId,
      'version': '1',
      'lifetime': 60000,
      'offer': {'type': offer.type, 'sdp': offer.sdp},
    };
    final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
    await _matrixClient!.sendMessage(roomId, 'm.call.invite', txn, invite);
    onStatus('Connecting…');
  }

  void _handleEvent(EventUpdate update) {
    try {
      final raw = update.content as Map<String, dynamic>;
      final type = raw['type'] as String?;
      final content = raw['content'];

      if (type == 'm.call.answer') {
        _handleAnswer(content);
      } else if (type == 'm.call.candidates') {
        _handleCandidates(content);
      } else if (type == 'm.call.hangup') {
        onStatus('Call ended');
        _peerConnection?.close();
        _localStream?.dispose();
      }
    } catch (e) {
      debugPrint('Error handling event: $e');
    }
  }

  Future<void> _handleAnswer(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final answer = data['answer'] as Map<String, dynamic>?;
    if (answer == null) return;

    final sdp = answer['sdp'] as String?;
    final type = answer['type'] as String?;
    if (sdp == null || type == null) return;

    await _peerConnection?.setRemoteDescription(RTCSessionDescription(sdp, type));

    for (var ice in _iceQueue) {
      await _peerConnection?.addCandidate(ice);
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
      final mid = m['sdpMid'] as String?;
      final idx = m['sdpMLineIndex'] as int?;

      if (cand == null || mid == null || idx == null) continue;
      final ice = RTCIceCandidate(cand, mid, idx);
      final remote = await _peerConnection?.getRemoteDescription();
      if (remote == null) {
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

    Future<void> hangup() async {
      if (_matrixClient != null && _callId != null && _roomId != null) {
        final body = {'call_id': _callId, 'version': '1'};
        final txn  = 'txn_${DateTime.now().millisecondsSinceEpoch}';
        await _matrixClient!.sendMessage(
            _roomId!, 'm.call.hangup', txn, body
        );
      }
      onStatus('Call ended');
      _peerConnection?.close();
      _localStream?.dispose();
    }

  Future<void> dispose() async {
    await _matrixClient?.logout().catchError((_) {});
    _matrixClient?.dispose();
    _peerConnection?.close();
    _localStream?.dispose();
  }
}
