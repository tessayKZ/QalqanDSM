// lib/ui/audio_call_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/matrix_call_service.dart';

class AudioCallPage extends StatefulWidget {
  final String roomId;
  const AudioCallPage({Key? key, required this.roomId}) : super(key: key);

  @override
  State<AudioCallPage> createState() => _AudioCallPageState();
}

class _AudioCallPageState extends State<AudioCallPage> {
  late final CallService _callService;

  bool _muted = false;
  bool _speakerOn = false;
  String _status = 'Connecting...';

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;
  Duration _callDuration = Duration.zero;

  late final RTCVideoRenderer _remoteRenderer;

  @override
  void initState() {
    super.initState();
    _remoteRenderer = RTCVideoRenderer()..initialize();

    _callService = CallService(
      onStatus: _updateStatus,
      onAddRemoteStream: (stream) {
        _remoteRenderer.srcObject = stream;
      },
    );

    _callService.startCall(roomId: widget.roomId);
  }

  void _updateStatus(String status) {
    if (status == 'Connection established' && !_stopwatch.isRunning) {
      _stopwatch.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() {
          _callDuration = _stopwatch.elapsed;
        });
      });
    }
    setState(() {
      _status = status;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopwatch
      ..stop()
      ..reset();
    _remoteRenderer.dispose();
    _callService.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Hidden VideoView to enable audio playback
          Opacity(
            opacity: 0,
            child: RTCVideoView(
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
          Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black45,
                              blurRadius: 10,
                              offset: Offset(0, 5),
                            ),
                          ],
                        ),
                        child: const CircleAvatar(
                          radius: 70,
                          backgroundImage: AssetImage('assets/avatar.jpg'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'user2',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _stopwatch.isRunning
                            ? _formatDuration(_callDuration)
                            : _status,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    vertical: 20, horizontal: 40),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _ActionButton(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      label: _muted ? 'Unmute' : 'Mute',
                      color: _muted ? Colors.redAccent : Colors.grey,
                      onTap: () {
                        setState(() => _muted = !_muted);
                        _callService.localStream
                            ?.getAudioTracks()
                            .forEach((t) => t.enabled = !_muted);
                      },
                    ),
                    _ActionButton(
                      icon: Icons.call_end,
                      label: 'Cancel',
                      color: Colors.redAccent,
                      onTap: () {
                        _callService.dispose();
                        Navigator.of(context).pop();
                      },
                    ),
                    _ActionButton(
                      icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                      label: _speakerOn ? 'Speaker' : 'Microphone',
                      color: Colors.grey,
                      onTap: () async {
                        setState(() => _speakerOn = !_speakerOn);
                        await Helper.setSpeakerphoneOn(_speakerOn);
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    Key? key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(30),
          child: Container(
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(16),
            child: Icon(icon, color: color, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.black87, fontSize: 14),
        ),
      ],
    );
  }
}