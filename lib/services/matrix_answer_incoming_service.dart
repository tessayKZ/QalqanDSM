import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qalqan_dsm/services/auth_data.dart';
import 'package:qalqan_dsm/services/matrix_auth.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:qalqan_dsm/services/call_store.dart';

class IncomingCallService {
  String? _roomId;
  StreamSubscription<Event>? _onEventSub;
  final void Function(String status) onStatus;
  final void Function(MediaStream stream) onAddRemoteStream;

  Client? _matrixClient;
  String? _loggedInUserId, _callId, _partyId;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  final List<RTCIceCandidate> _iceQueue = [];

  Client get matrixClient => _matrixClient!;
  MediaStream? get localStream => _localStream;

  IncomingCallService({
    required this.onStatus,
    required this.onAddRemoteStream,
  });

  Future<void> _safeFinishFromRemoteHangup() async {
    onStatus('Call ended');
    try { await _peerConnection?.close(); } catch (_) {}
    try { await _localStream?.dispose(); } catch (_) {}

    final uuid = await CallStore.uuidForCallId(_callId ?? '') ?? _callId;
    if (uuid != null && uuid.isNotEmpty) {
      try { await FlutterCallkitIncoming.endCall(uuid); } catch (_) {}
    }
    if (_callId != null) {
      try { await CallStore.unmapCallId(_callId!); } catch (_) {}
    }
    await _onEventSub?.cancel();
    _onEventSub = null;
  }

  Future<void> startCall({required String roomId}) async {
    try {
      _roomId = roomId;

      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        onStatus('Microphone permission denied');
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
        final m = (content as Map?)?.cast<String, dynamic>() ?? const {};
        final cid = m['call_id'] as String?;
        if (_callId != null && cid != null && cid != _callId) return;

        try {
          if (type == 'm.call.answer') {
            _handleAnswer(content);
          } else if (type == 'm.call.candidates') {
            _handleCandidates(content);
          } else if (type == 'm.call.select_answer') {
            final selected = m['selected_party_id'] as String?;
            if (selected != null && selected != _partyId) {
              onStatus('Answered on another device');
              await _safeFinishFromRemoteHangup();
            }
          } else if (type == 'm.call.hangup') {
            _safeFinishFromRemoteHangup();
          }
        } catch (e) {
          debugPrint('Error handling event: $e');
        }
      });

      final room = _matrixClient!.getRoomById(roomId);
      if (room == null) {
        onStatus('Room not found: $roomId');
        return;
      }

      onStatus('Accessing local media...');
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {'echoCancellation': true, 'noiseSuppression': true},
        'video': false,
      });

      _peerConnection = await createPeerConnection(
        {
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
        },
        {},
      );

       _peerConnection!.onConnectionState = (RTCPeerConnectionState s) {
           debugPrint('pc connectionState=$s');
         };

      _peerConnection!.onIceConnectionState = (state) async {
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          final uuid = await CallStore.uuidForCallId(_callId ?? '') ?? _callId;
          if (uuid != null && uuid.isNotEmpty) {
            try { await FlutterCallkitIncoming.setCallConnected(uuid); } catch (_) {}
          }
          onStatus('Connected');
        }
      };

      _localStream!.getTracks().forEach(
            (t) => _peerConnection?.addTrack(t, _localStream!),
      );

      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          onAddRemoteStream(event.streams[0]);
          onStatus('Connected');
        }
      };

      _callId =
      'call_${DateTime.now().millisecondsSinceEpoch}';
      _partyId =
      'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';

      onStatus('Creating offer...');
      final offer =
      await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
      await _peerConnection!.setLocalDescription(offer);

      _peerConnection!.onIceCandidate = (RTCIceCandidate cand) {
        if (cand.candidate != null) _sendIce(roomId, cand);
      };

      _peerConnection!.onIceGatheringState =
          (RTCIceGatheringState state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
          final body = {
            'call_id': _callId,
            'party_id': _partyId,
            'version': 1,
            'candidates': <dynamic>[],
          };
          final txn =
              'txn_${DateTime.now().millisecondsSinceEpoch}';
          matrixClient.sendMessage(
              roomId, 'm.call.candidates', txn, body);
        }
      };

      final invite = {
        'call_id': _callId,
        'lifetime': 60000,
        'offer': {'type': offer.type, 'sdp': offer.sdp},
        'version': 1,
        'party_id': _partyId,
      };
      final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
      await _matrixClient!
          .sendMessage(roomId, 'm.call.invite', txn, invite);

      AuthDataCall.instance.outgoingCallIds.add(_callId!);
      onStatus('Connecting…');
    } on MatrixException catch (e) {
      onStatus('Matrix error: $e');
    } catch (e) {
      onStatus('Unexpected error: $e');
    }
  }

  Future<void> _handleAnswer(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final answer = data['answer'] as Map<String, dynamic>?;
    final sdp = answer?['sdp'] as String?;
    final type = answer?['type'] as String?;
    if (sdp != null && type != null) {
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(sdp, type),
      );
      for (var c in _iceQueue) {
        await _peerConnection?.addCandidate(c);
      }
      _iceQueue.clear();
    }
  }

  Future<void> _handleCandidates(dynamic content) async {
    final data = content as Map<String, dynamic>?;
    if (data == null || data['call_id'] != _callId) return;
    final list = data['candidates'] as List<dynamic>?;
    for (var it in list?.cast<Map<String, dynamic>>() ?? []) {
      final cand = it['candidate'] as String?;
      final mid = it['sdpMid'] as String?;
      final idx = it['sdpMLineIndex'] as int?;
      if (cand != null && mid != null && idx != null) {
        final ice = RTCIceCandidate(cand, mid, idx);
        final remoteDesc =
        await _peerConnection?.getRemoteDescription();
        if (remoteDesc == null) {
          _iceQueue.add(ice);
        } else {
          await _peerConnection?.addCandidate(ice);
        }
      }
    }
  }

  Future<void> _sendIce(String roomId, RTCIceCandidate cand) async {
    if (_matrixClient == null || _callId == null || _partyId == null) return;
    final body = {
      'call_id': _callId,
      'party_id': _partyId,
      'version': 1,
      'candidates': [
        {
          'candidate': cand.candidate,
          'sdpMid': cand.sdpMid,
          'sdpMLineIndex': cand.sdpMLineIndex,
        }
      ],
    };
    final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
    await matrixClient.sendMessage(
        roomId, 'm.call.candidates', txn, body);
  }

  Future<void> hangup() async {
    if (_matrixClient != null && _callId != null && _roomId != null) {
      final body = {'call_id': _callId, 'version': 1};
      final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
      await _matrixClient!.sendMessage(_roomId!, 'm.call.hangup', txn, body);
    }
    final uuid = await CallStore.uuidForCallId(_callId ?? '') ?? _callId;
    if (uuid != null && uuid.isNotEmpty) {
      await FlutterCallkitIncoming.endCall(uuid);
    }
    if (_callId != null) {
      await CallStore.unmapCallId(_callId!);
    }
    onStatus('Call ended');
    _peerConnection?.close();
    _localStream?.dispose();
    await _onEventSub?.cancel();
    _onEventSub = null;
  }

  Future<void> dispose() async {
    _peerConnection?.close();
    await _localStream?.dispose();
    await _onEventSub?.cancel();
    _onEventSub = null;
  }
}

extension IncomingCallServiceAnswer on IncomingCallService {
  Future<void> answerCall({
    required String roomId,
    required String callId,
    required Map<String, dynamic> offer,
  }) async {
    _callId = callId;
    _roomId = roomId;

    onStatus('Preparing client...');
    if (AuthService.client == null || AuthService.userId == null) {
      onStatus('Not signed in');
      return;
    }
    _matrixClient = AuthService.client;
    _loggedInUserId = AuthService.userId;

    _partyId =
    'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';

    _onEventSub?.cancel();
    _onEventSub = _matrixClient!.onTimelineEvent.stream.listen((e) async {
      if (_roomId != null && e.roomId != _roomId) return;
      final type = e.type;
      final content = e.content;
      final m = (content as Map?)?.cast<String, dynamic>() ?? const {};
      final cid = m['call_id'] as String?;
      if (_callId != null && cid != null && cid != _callId) return;

      try {
        if (type == 'm.call.answer') {
          _handleAnswer(content);
        } else if (type == 'm.call.candidates') {
          _handleCandidates(content);
        } else if (type == 'm.call.select_answer') {
          final selected = m['selected_party_id'] as String?;
          if (selected != null && selected != _partyId) {
            onStatus('Answered on another device');
            await _safeFinishFromRemoteHangup();
          }
        } else if (type == 'm.call.hangup') {
          _safeFinishFromRemoteHangup();
        }
      } catch (e) {
        debugPrint('Error handling event: $e');
      }
    });

    onStatus('Accessing local media...');
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      onStatus('Microphone denied');
      return;
    }

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true},
      'video': false,
    });

    _peerConnection = await createPeerConnection(
      {
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
      },
      {},
    );

     _peerConnection!.onConnectionState = (RTCPeerConnectionState s) {
         debugPrint('pc connectionState=$s');
       };

    _peerConnection!.onIceConnectionState = (state) async {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        final uuid = await CallStore.uuidForCallId(_callId ?? '') ?? _callId;
        if (uuid != null && uuid.isNotEmpty) {
          try { await FlutterCallkitIncoming.setCallConnected(uuid); } catch (_) {}
        }
        onStatus('Connected');
      }
    };

    _localStream!.getTracks().forEach(
          (t) => _peerConnection!.addTrack(t, _localStream!),
    );

    final localClient = _matrixClient!;
    final localRoomId = roomId;
    final localPartyId = _partyId!;

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        onAddRemoteStream(event.streams[0]);
        onStatus('Connected');
      }
    };

    _peerConnection!.onIceCandidate = (RTCIceCandidate? c) async {
      if (c == null) return;
      final iceBody = {
        'call_id': callId,
        'party_id': localPartyId,
        'version': 1,
        'candidates': [
          {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          }
        ],
      };
      await localClient.sendMessage(
        localRoomId,
        'm.call.candidates',
        'txn_${DateTime.now().millisecondsSinceEpoch}',
        iceBody,
      );
    };

    _peerConnection!.onIceGatheringState =
        (RTCIceGatheringState state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        final body = {
          'call_id': callId,
          'party_id': _partyId,
          'version': 1,
          'candidates': <dynamic>[],
        };
        final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
        _matrixClient!.sendMessage(
            roomId, 'm.call.candidates', txn, body);
      }
    };

    onStatus('Setting remote SDP...');
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(
        offer['sdp'] as String,
        offer['type'] as String,
      ),
    );

    onStatus('Creating answer...');
    final answer =
    await _peerConnection!.createAnswer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(answer);

    final localDesc = await _peerConnection!.getLocalDescription();
    if (localDesc != null) {
      final ansBody = {
        'call_id': callId,
        'version': 1,
        'party_id': _partyId,
        'answer': {
          'type': localDesc.type,
          'sdp': localDesc.sdp,
        },
      };
      await _matrixClient!.sendMessage(
        roomId,
        'm.call.answer',
        'txn_${DateTime.now().millisecondsSinceEpoch}',
        ansBody,
      );
      onStatus('Connecting…');
    }
  }
}
