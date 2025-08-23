import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/auth_data.dart';
import '../services/matrix_auth.dart';
import 'package:qalqan_dsm/services/call_store.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

class OutgoingCallService {
  final void Function(String status) onStatus;
  final void Function(MediaStream stream) onAddRemoteStream;

  bool _ended = false;
  Client? _matrixClient;
  String? _loggedInUserId;
  String? _callId;
  String? _partyId;
  String? _roomId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final List<RTCIceCandidate> _iceQueue = [];
  StreamSubscription<Event>? _onEventSub;

  MediaStream? get localStream => _localStream;

  OutgoingCallService({
    required this.onStatus,
    required this.onAddRemoteStream,
  });

  Future<void> startCall({required String roomId}) async {
    _roomId = roomId;

    onStatus('Requesting microphone…');
    if (!await Permission.microphone.request().isGranted) {
      onStatus('Microphone denied');
      return;
    }

    if (AuthService.client == null || AuthService.userId == null) {
      onStatus('Not signed in');
      return;
    }
    _matrixClient = AuthService.client;
    _loggedInUserId = AuthService.userId;

    _onEventSub?.cancel();
    _onEventSub = _matrixClient!.onTimelineEvent.stream.listen((e) async {
      if (_roomId != null && e.roomId != _roomId) return;

      final type = e.type;
      final content = e.content;

      try {
        if (type == 'm.call.answer') {
          await _handleAnswer(content);
        } else if (type == 'm.call.candidates') {
          await _handleCandidates(content);
        } else if (type == 'm.call.hangup') {
          final m = (content as Map?)?.cast<String, dynamic>();
          if (m?['call_id'] == _callId) {
            await _finish();
          }
        } else if (type == 'm.call.select_answer') {
          final m = (content as Map?)?.cast<String, dynamic>() ?? const {};
          final selected = m['selected_party_id'] as String?;
          if (selected != null && selected != _partyId) {
          }
        }
      } catch (e) {
        debugPrint('Error handling event: $e');
      }
    });

    onStatus('Accessing local media…');
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': false,
    });

    onStatus('Creating PeerConnection…');

    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:webqalqan.com:3478',
          'username': 'turnuser',
          'credential': 'turnpass',
        },
        {
          'urls': 'turns:webqalqan.com:5349?transport=tcp',
          'username': 'turnuser',
          'credential': 'turnpass',
        },
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(configuration, {});
    _peerConnection!.onConnectionState = (RTCPeerConnectionState s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onStatus('Disconnected');
      }
    };
    _peerConnection!.onIceConnectionState = (state) async {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        final uuid = await CallStore.uuidForCallId(_callId ?? '');
        if (uuid != null && uuid.isNotEmpty) {
          try { await FlutterCallkitIncoming.setCallConnected(uuid); } catch (_) {}
        }
        onStatus('Connected');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        onStatus('Disconnected');
      }
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        onAddRemoteStream(event.streams[0]);
      }
    };
    _localStream!.getAudioTracks().forEach(
          (track) => _peerConnection!.addTrack(track, _localStream!),
    );

    _callId =
    'call_${DateTime.now().millisecondsSinceEpoch}';
    _partyId =
    'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';
    AuthDataCall.instance.outgoingCallIds.add(_callId!);
    await CallStore.markOutgoing(_callId!);

    onStatus('Creating offer…');
    final offer =
    await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(offer);

    _peerConnection!.onIceCandidate = (cand) {
      if (cand.candidate != null) {
        _sendIce(cand);
      }
    };

    final invite = {
      'call_id': _callId,
      'party_id': _partyId,
      'version': 1,
      'lifetime': 60000,
      'offer': {'type': offer.type, 'sdp': offer.sdp},
    };
    await _sendCallEvent('m.call.invite', invite);
    onStatus('Connecting…');
  }

  Future<void> _finish({bool endCallkit = true}) async {
    if (_ended) return;
    _ended = true;
    try {
      for (final t in _localStream?.getTracks() ?? const []) { await t.stop(); }
    } catch (_) {}
    try { await _localStream?.dispose(); } catch (_) {}
    try { await _peerConnection?.close(); } catch (_) {}

    if (endCallkit) {
      final uuid = await CallStore.uuidForCallId(_callId ?? '') ?? _callId;
      if (uuid != null && uuid.isNotEmpty) {
        try { await FlutterCallkitIncoming.endCall(uuid); } catch (_) {}
      }
    }

    if (_callId != null) {
      try { await CallStore.unmapCallId(_callId!); } catch (_) {}
      try { await CallStore.removeOutgoing(_callId!); } catch (_) {}
    }

    await _onEventSub?.cancel();
    _onEventSub = null;

    onStatus('Call ended');
  }

  Future<void> _handleAnswer(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final answer = data['answer'] as Map<String, dynamic>?;
    if (answer == null) return;

    final sdp = answer['sdp'] as String?;
    final type = answer['type'] as String?;
    if (sdp == null || type == null) return;

    await _peerConnection?.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );

    for (var ice in _iceQueue) {
      await _peerConnection?.addCandidate(ice);
    }
    _iceQueue.clear();
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

  Future<void> _sendIce(RTCIceCandidate c) async {
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
    await _sendCallEvent('m.call.candidates', body);
  }

  Future<void> hangup() async {
    if (_matrixClient != null && _roomId != null && _callId != null) {
      final body = {
        'call_id': _callId,
        'party_id': _partyId,
        'version': 1,
        'reason': 'user_hangup',
      };
      try { await _sendCallEvent('m.call.hangup', body); } catch (_) {}
    }
    await _finish();
  }

  Future<void> _sendCallEvent(String type, Map<String, dynamic> body) async {
    if (_matrixClient == null || _roomId == null) return;
    final room = _matrixClient!.getRoomById(_roomId!);
    if (room == null) return;
    await room.sendEvent(body, type: type);
  }

  Future<void> dispose() async {
    await _onEventSub?.cancel();
    try { for (final t in _localStream?.getTracks() ?? const []) { await t.stop(); } } catch (_) {}
    try { await _localStream?.dispose(); } catch (_) {}
    try { await _peerConnection?.close(); } catch (_) {}
  }
}
