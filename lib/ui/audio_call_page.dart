import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/matrix_answer_service.dart';
import '../services/webrtc_helper.dart';

class AudioCallPage extends StatefulWidget {
  final String roomId;
  final bool isIncoming;
  final String? callId;
  final Map<String, dynamic>? offer;

  const AudioCallPage({
    Key? key,
    required this.roomId,
    this.isIncoming = false,
    this.callId,
    this.offer,
  }) : super(key: key);

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

  bool _callEnded = false;
  Duration _finalDuration = Duration.zero;

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

    if (widget.isIncoming) {
      _callService.answerCall(
        roomId: widget.roomId,
        callId: widget.callId!,
        offer: widget.offer!,
      );
    } else {
      _callService.startCall(roomId: widget.roomId);
    }
  }

  void _updateStatus(String status) {
    if ((status == 'Connection established' || status == 'Connected') &&
        !_stopwatch.isRunning) {
      setState(() {
        _status = 'Connected';
        _callEnded = false;
      });
      _stopwatch.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() {
          _callDuration = _stopwatch.elapsed;
        });
      });
      return;
    }

    if (status == 'Call ended' || status == 'Disconnected') {
      if (_stopwatch.isRunning) {
        _stopwatch.stop();
        _finalDuration = _stopwatch.elapsed;
        _timer?.cancel();
        _callEnded = true;
      }
      setState(() {
        _status = 'Call ended';
      });
      return;
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
                      const CircleAvatar(
                        radius: 70,
                        backgroundImage: AssetImage('assets/avatar.jpg'),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _status,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 8),

                      if (_stopwatch.isRunning && !_callEnded) ...[
                        const Text(
                          'Connected',
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDuration(_callDuration),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                          ),
                        ),
                      ] else if (_callEnded) ...[
                        const Text(
                          'Call ended',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDuration(_finalDuration),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                          ),
                        ),
                      ],

                      const SizedBox(height: 16),
                      const Text(
                        'user',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding:
                const EdgeInsets.symmetric(vertical: 20, horizontal: 40),
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
                      label: 'End',
                      color: Colors.redAccent,
                      onTap: () {
                        _callService.dispose();
                        Navigator.of(context).pop();
                      },
                    ),
                    _ActionButton(
                      icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                      label: _speakerOn ? 'Speaker' : 'Mic',
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