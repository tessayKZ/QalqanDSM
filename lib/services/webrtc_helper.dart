// lib/services/webrtc_helper.dart

import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcHelper {
  static Future<Map<String, dynamic>> createOffer() async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      // Unified Plan — по умолчанию
      'sdpSemantics': 'unified-plan',
    }, {});

    // захватываем только аудио
    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    // вместо addStream — для каждого трека вызов addTrack
    for (var track in localStream.getAudioTracks()) {
      await pc.addTrack(track, localStream);
    }

    final offer = await pc.createOffer({'offerToReceiveAudio': 1});
    await pc.setLocalDescription(offer);
    return {'type': offer.type, 'sdp': offer.sdp};
  }
}
