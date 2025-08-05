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
    username: json['username'] as String,
    password: json['password'] as String,
    roomId: json['room_id'] as String,
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
      onStatus('Logged in as $_loggedInUserId');

      final room = client.getRoomById(roomId);
      if (room == null) {
        onStatus('Room not found: $roomId');
        return;
      }

      startSyncLoop();

      onStatus('Accessing local media...');
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
        'sdpSemantics': 'unified-plan'
      });
      _localStream!.getTracks().forEach((t) => _peerConnection?.addTrack(t, _localStream!));

            _peerConnection!.onTrack = (RTCTrackEvent event) {
                if (event.streams.isNotEmpty) {
                  onAddRemoteStream(event.streams[0]);
                }
              };

      _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
      _partyId = 'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';

      onStatus('Creating offer...');
      final offer = await _peerConnection!.createOffer({'offerToReceiveAudio': 1});
      await _peerConnection!.setLocalDescription(offer);

      _peerConnection!.onIceCandidate = (RTCIceCandidate cand) {
        if (cand.candidate != null) _sendIce(roomId, cand);
      };

      _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {

          final body = {
            'call_id': _callId,
            'party_id': _partyId,
            'version': 1,
            'candidates': <dynamic>[],
          };
          final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
          matrixClient.sendMessage(roomId, 'm.call.candidates', txn, body);
        }
      };

      final invite = {
        'call_id': _callId,
        'lifetime': 60000,
          'offer': {
              'type': offer.type,
              'sdp': offer.sdp
          },
      'version': 1,
    'party_id': _partyId,
      };
      final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
      await client.sendMessage(roomId, 'm.call.invite', txn, invite);
      AuthDataCall.instance.outgoingCallIds.add(_callId!);
      onStatus('Connecting…');
    } on MatrixException catch (e) {
      onStatus('Matrix error: $e');
    } catch (e) {
      onStatus('Unexpected error: $e');
    }
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
    final sdp = answer?['sdp'] as String?;
    final type = answer?['type'] as String?;
    if (sdp != null && type != null) {
      await _peerConnection?.setRemoteDescription(RTCSessionDescription(sdp, type));
      for (var c in _iceQueue) await _peerConnection?.addCandidate(c);
      _iceQueue.clear();
      onStatus('Connected');
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
        final remoteDesc = await _peerConnection?.getRemoteDescription();
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
    await matrixClient.sendMessage(roomId, 'm.call.candidates', txn, body);
  }

  bool _disposed = false;
  String? _sinceToken;

    void startSyncLoop() {
        _matrixClient!.onEvent.stream
               .listen(_handleEvent, onError: (err) => onStatus('Sync error: $err'));
        _runSyncLoop();
      }

  Future<void> _runSyncLoop() async {
    while (!_disposed) {
      try {
        final resp = await _matrixClient!.sync(
          since: _sinceToken,
          timeout: 30000,
        );
        _sinceToken = resp.nextBatch;
      } catch (e) {
        debugPrint('Sync loop error: $e');
        await Future.delayed(Duration(seconds: 1));
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    if (_matrixClient != null) {
      await _matrixClient!.logout().catchError((_) {});
      _matrixClient!.dispose();
      _matrixClient = null;
    }
  }
}

extension CallServiceAnswer on CallService {
  Future<void> answerCall({
    required String roomId,
    required String callId,
    required Map<String, dynamic> offer,
  }) async {
    _callId = callId;
    onStatus('Loading config...');
    final config = await loadConfig();

    onStatus('Logging in...');
        _matrixClient?.dispose();
        _matrixClient = Client('AnswerServiceClient');
        await _matrixClient!.init();
        await _matrixClient!.checkHomeserver(Uri.parse(config.homeserver));
        final login = await _matrixClient!.login(
          LoginType.mLoginPassword,
          identifier: AuthenticationUserIdentifier(user: AuthDataCall.instance.login),
          password: AuthDataCall.instance.password,
        );
        _loggedInUserId = login.userId;
    final answerClient = _matrixClient!;
    startSyncLoop();
    _partyId = 'dart_${_loggedInUserId!.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}';
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

    final iceConfig = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': 'turn:webqalqan.com:3478',
          'username': 'turnuser',
          'credential': 'turnpass',
        }
      ]
    };
    _peerConnection = await createPeerConnection(iceConfig, {
      'sdpSemantics': 'unified-plan',
    });
    _localStream!.getTracks().forEach((t) => _peerConnection!.addTrack(t, _localStream!));

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

    _peerConnection!.onIceGatheringState = (RTCIceGatheringState state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        final body = {
          'call_id': callId,
          'party_id': _partyId,
          'version': 1,
          'candidates': <dynamic>[],
        };
        final txn = 'txn_${DateTime.now().millisecondsSinceEpoch}';
        matrixClient.sendMessage(roomId, 'm.call.candidates', txn, body);
      }
    };

    onStatus('Setting remote SDP...');
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'] as String, offer['type'] as String),
    );

    onStatus('Creating answer...');
    final answer = await _peerConnection!.createAnswer({'offerToReceiveAudio': 1});
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
      await matrixClient.sendMessage(
        roomId,
        'm.call.answer',
        'txn_${DateTime.now().millisecondsSinceEpoch}',
        ansBody,
      );
      onStatus('Call accepted');
    }
  }
}