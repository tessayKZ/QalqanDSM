import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/audio_helper.dart';
import '../services/matrix_outgoing_call_service.dart';

class OutgoingAudioCallPage extends StatefulWidget {
  final String roomId;
  final String initialName;
  const OutgoingAudioCallPage({Key? key, required this.roomId, required this.initialName,}) : super(key: key);

  @override
  State<OutgoingAudioCallPage> createState() => _OutgoingAudioCallPageState();
}

class _OutgoingAudioCallPageState extends State<OutgoingAudioCallPage> {
  late final CallService _callService;

  bool _muted = false;
  bool _speakerOn = false;
  String _status = 'Connecting...';
  bool _callEnded = false;
  Duration _finalDuration = Duration.zero;

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _timer;

  late final RTCVideoRenderer _remoteRenderer;

  @override
  void initState() {
    super.initState();
    _initializeCall();
  }

  Future<void> _initializeCall() async {
    _remoteRenderer = RTCVideoRenderer()..initialize();
    _callService = CallService(
      onStatus: _updateStatus,
      onAddRemoteStream: (stream) => _remoteRenderer.srcObject = stream,
    );

    await AudioHelper.setReceiver();

    _callService.startCall(roomId: widget.roomId).then((_) {
      setState(() => _muted = false);
      for (var track in _callService.localStream?.getAudioTracks() ?? []) {
        track.enabled = true;
      }
    });
  }

  void _updateStatus(String status) {
    if ((status == 'Connected' || status == 'Connection established') && !_stopwatch.isRunning) {
      _stopwatch.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
      return;
    }

    if (status == 'Call ended' || status == 'Disconnected') {
      if (_stopwatch.isRunning) {
        _stopwatch.stop();
        _finalDuration = _stopwatch.elapsed;
        _timer?.cancel();
      }
      setState(() {
        _callEnded = true;
      });
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        Navigator.of(context).pop();
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
                      if (_callEnded) ...[
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
                      ]
                      else if (_stopwatch.isRunning) ...[
                        Text(
                          _formatDuration(_stopwatch.elapsed),
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 18,
                          ),
                        ),
                      ]
                      else ...[
                          Text(
                            _status,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 18,
                            ),
                          ),
                        ],

                      const SizedBox(height: 16),
                      Text(
                        widget.initialName,
                        style: const TextStyle(
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
                        for (var track in _callService.localStream?.getAudioTracks() ?? []) {
                          track.enabled = !_muted;
                        }
                      },
                    ),
                    _ActionButton(
                      icon: Icons.call_end,
                      label: 'End',
                      color: Colors.redAccent,
                      onTap: () {
                        _callService.hangup();
                      },
                    ),
                    _ActionButton(
                      icon: _speakerOn ? Icons.volume_up : Icons.hearing,
                      label: _speakerOn ? 'Speaker' : 'Microphone',
                      color: Colors.grey,
                      onTap: () async {
                        setState(() => _speakerOn = !_speakerOn);
                        if (_speakerOn) {
                          await AudioHelper.setSpeaker();
                        } else {
                          await AudioHelper.setReceiver();
                        }
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