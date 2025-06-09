import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/matrix_service.dart';

class AudioCallPage extends StatefulWidget {
  final String roomId;
  const AudioCallPage({Key? key, required this.roomId}) : super(key: key);

  @override
  State<AudioCallPage> createState() => _AudioCallPageState();
}

class _AudioCallPageState extends State<AudioCallPage> {
  bool _inProgress = false;
  String _status = 'Инициализация…';
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _callId;
  String? _partyId;
  final List<RTCIceCandidate> _iceQueue = [];

  @override
  void initState() {
    super.initState();
    _startAudioCall();
  }

  @override
  void dispose() {
    _pc?.close();
    _localStream?.dispose();
    super.dispose();
  }

  Future<void> _startAudioCall() async {
    setState(() => _inProgress = true);
    // 1) разрешение
    if (!await Permission.microphone.request().isGranted) {
      setState(() {
        _status = 'Необходимо разрешение на микрофон';
        _inProgress = false;
      });
      return;
    }

    // 2) подготовить WebRTC
    _localStream = await navigator.mediaDevices.getUserMedia({'audio': true});
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    }, {});
    _localStream!.getTracks().forEach((t) => _pc!.addTrack(t, _localStream!));

    // 3) генерируем идентификаторы
    _callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    _partyId = 'party_${MatrixService.userId ?? 'unknown'}';

    // 4) создаём offer
    final offer = await _pc!.createOffer({'offerToReceiveAudio': 1});
    await _pc!.setLocalDescription(offer);
    _pc!.onIceCandidate = (cand) {
      if (cand.candidate != null) {
        _sendIceCandidate(cand);
      }
    };

    // 5) отправляем m.call.invite через ваш MatrixService HTTP-метод
    await MatrixService.sendCallInvite(
      roomId: widget.roomId,
      callId: _callId!,
      partyId: _partyId!,
      offer: offer.sdp!,
      sdpType: offer.type!,
    );

    setState(() => _status = 'Ожидание ответа…');
  }

  Future<void> _sendIceCandidate(RTCIceCandidate cand) async {
    await MatrixService.sendCallCandidates(
      roomId: widget.roomId,
      callId: _callId!,
      partyId: _partyId!,
      candidates: [cand.toMap()],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Аудиозвонок')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_inProgress) const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(_status),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Завершить звонок'),
            ),
          ],
        ),
      ),
    );
  }
}
