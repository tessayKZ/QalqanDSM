import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcHelper {
  static Future<Map<String, dynamic>> createOffer() async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    }, {});

    final localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    for (var track in localStream.getAudioTracks()) {
      await pc.addTrack(track, localStream);
    }

    final offer = await pc.createOffer({'offerToReceiveAudio': 1});
    await pc.setLocalDescription(offer);
    return {'type': offer.type, 'sdp': offer.sdp};
  }
}
