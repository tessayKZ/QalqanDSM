import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
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

  String _calleeName = '';
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
    if ((status == 'Connected' || status == 'Connection established')
        && !_stopwatch.isRunning) {
      _stopwatch.start();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        setState(() {
          _callDuration = _stopwatch.elapsed;
        });
      });
    }
    else if (status == 'Call ended') {
      _timer?.cancel();
      _stopwatch.stop();

      final finalTime = _formatDuration(_stopwatch.elapsed);

      setState(() {
        _status = 'Call duration: $finalTime';
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
                      Text(
                        widget.initialName,
                        style: const TextStyle(
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