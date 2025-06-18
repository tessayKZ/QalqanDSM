import 'dart:async';
import 'package:matrix/matrix.dart' show Client, EventUpdate;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';

/// Сервис для приёма входящих звонков через Matrix и нативный CallKit UI,
/// а также WebRTC-ответов на звонки внутри приложения.
class MatrixAnswerService {
  final Client matrixClient;
  final String roomId;
  final void Function(String status) onStatus;
  final void Function(MediaStream stream) onAddRemoteStream;

  final Map<String, dynamic> _pendingOffers = {};
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  String? _callId;
  final List<RTCIceCandidate> _iceQueue = [];

  MatrixAnswerService({
    required this.matrixClient,
    required this.roomId,
    required this.onStatus,
    required this.onAddRemoteStream,
  });

  /// Инициализация: запрос разрешений и подписка на события CallKit и Matrix
  void init() {
    FlutterCallkitIncoming.requestNotificationPermission({});
    FlutterCallkitIncoming.requestFullIntentPermission();
    FlutterCallkitIncoming.onEvent?.listen(_onCallKitEvent);
    matrixClient.onEvent.stream.listen(_handleMatrixEvent);
  }

  void _onCallKitEvent(CallEvent? event) {
    if (event == null || event.body == null) return;
    final callId = event.body!['id'] as String?;
    if (callId == null) return;
    switch (event.event) {
      case Event.actionCallAccept:
        final offer = _pendingOffers.remove(callId) as Map<String, dynamic>?;
        if (offer != null) _answerCall(callId, offer);
        break;
      case Event.actionCallDecline:
        _hangup(callId);
        FlutterCallkitIncoming.endCall(callId);
        break;
      case Event.actionCallEnded:
        _cleanup();
        break;
      default:
        break;
    }
  }

  void _handleMatrixEvent(EventUpdate update) {
    final type = update.type;
    final content = update.content as Map<String, dynamic>;
    if (type == 'm.call.invite') {
      final callId = content['call_id'] as String;
      final caller = content['party_id'] as String;
      _pendingOffers[callId] = content['offer'];
      _showIncoming(callId, caller);
    } else if (type == 'm.call.hangup') {
      final callId = content['call_id'] as String;
      FlutterCallkitIncoming.endCall(callId);
      _cleanup();
    }
  }

  void _showIncoming(String callId, String caller) {
    final params = CallKitParams(
      id: callId,
      nameCaller: caller,
      appName: 'QalqanDSM',
      handle: caller,
      type: 0,
      textAccept: 'Принять',
      textDecline: 'Отклонить',
      duration: 30000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        subtitle: 'Пропущенный вызов',
      ),
      callingNotification: const NotificationParams(
        showNotification: true,
        subtitle: 'Вызов...',
      ),
      android: const AndroidParams(
        isCustomNotification: true,
        isShowFullLockedScreen: true,
      ),
      ios: const IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: false,
      ),
      extra: {'roomId': roomId},
    );
    FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  Future<void> _answerCall(String callId, Map<String, dynamic> offer) async {
    onStatus('Answering call');
    _callId = callId;
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      onStatus('Microphone permission denied');
      return;
    }
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };
    _peerConnection = await createPeerConnection(config, {});
    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });
    _peerConnection!.onIceCandidate = (candidate) => _sendIce(candidate);
    _peerConnection!.onTrack = (event) {
      if (event.track.kind == 'audio' && event.streams.isNotEmpty) {
        onAddRemoteStream(event.streams[0]);
      }
    };
    final remoteDesc = RTCSessionDescription(
      offer['sdp'] as String,
      offer['type'] as String,
    );
    await _peerConnection!.setRemoteDescription(remoteDesc);
    final answer = await _peerConnection!.createAnswer({'offerToReceiveAudio': 1});
    await _peerConnection!.setLocalDescription(answer);
    await matrixClient.sendMessage(
      roomId,
      'm.call.answer',
      'txn_${DateTime.now().millisecondsSinceEpoch}',
      {
        'call_id': callId,
        'answer': {'type': answer.type, 'sdp': answer.sdp}
      },
    );
    onStatus('Call accepted');
    for (var c in _iceQueue) {
      await _peerConnection!.addCandidate(c);
    }
    _iceQueue.clear();
  }

  Future<void> _hangup(String callId) async {
    await matrixClient.sendMessage(
      roomId,
      'm.call.hangup',
      'txn_${DateTime.now().millisecondsSinceEpoch}',
      {'call_id': callId},
    );
    FlutterCallkitIncoming.endCall(callId);
    _cleanup();
  }

  void _cleanup() {
    _peerConnection?.close();
    _localStream?.dispose();
    _peerConnection = null;
    _localStream = null;
    _callId = null;
    _iceQueue.clear();
  }

  void _sendIce(RTCIceCandidate candidate) async {
    if (_peerConnection == null || _callId == null) {
      _iceQueue.add(candidate);
      return;
    }
    await matrixClient.sendMessage(
      roomId,
      'm.call.candidates',
      'txn_${DateTime.now().millisecondsSinceEpoch}',
      {
        'call_id': _callId,
        'candidates': [
          {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }
        ],
      },
    );
  }
}
