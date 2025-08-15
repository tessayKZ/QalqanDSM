import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_audio_output/flutter_audio_output.dart';

class AudioHelper {

  static Future<Map<String, dynamic>> createOffer() async {
    final pc = await createPeerConnection(
      {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'sdpSemantics': 'unified-plan',
      },
      {},
    );

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

  static Future<void> setReceiver() async {
    await FlutterAudioOutput.changeToReceiver();
  }

  static Future<void> setSpeaker() async {
    await FlutterAudioOutput.changeToSpeaker();
  }
}