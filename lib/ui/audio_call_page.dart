import 'package:flutter/material.dart';
import '../services/matrix_call_service.dart';  // ← точный путь к файлу

class AudioCallPage extends StatefulWidget {
  final String roomId;
  const AudioCallPage({Key? key, required this.roomId}) : super(key: key);

  @override
  State<AudioCallPage> createState() => _AudioCallPageState();
}

class _AudioCallPageState extends State<AudioCallPage> {
  late final CallService _callService;
  bool _inProgress = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _callService = CallService(onStatus: (s) {
      setState(() {
        _status = s;
        _inProgress = s.contains('…') || s.contains('Creating') || s.contains('Invite sent');
      });
    });

    // Запускаем звонок сразу
    _callService.startCall(roomId: widget.roomId);
  }

  @override
  void dispose() {
    _callService.dispose();
    super.dispose();
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
            const SizedBox(height: 16),
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                _callService.dispose();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.call_end),
              label: const Text('Завершить звонок'),
            ),
          ],
        ),
      ),
    );
  }
}
