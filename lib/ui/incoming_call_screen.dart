// lib/features/call/presentation/incoming_call_screen.dart
import 'package:flutter/material.dart';
import 'package:your_app/features/call/domain/call_client.dart';

class IncomingCallScreen extends StatefulWidget {
  final String callerName;
  final String callId;

  const IncomingCallScreen({
    Key? key,
    required this.callerName,
    required this.callId,
  }) : super(key: key);

  @override
  _IncomingCallScreenState createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    // тут можно запустить плеер рингтона
    // AudioCache().loop('ringtone.mp3');
  }

  @override
  void dispose() {
    // AudioCache().stop();
    super.dispose();
  }

  void _answer() {
    setState(() => _answered = true);
    CallClient.instance.answer(widget.callId);
    Navigator.of(context).pop(); // закрываем экран
  }

  void _decline() {
    CallClient.instance.hangup(widget.callId);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Входящий звонок', style: TextStyle(color: Colors.white70, fontSize: 20)),
            SizedBox(height: 20),
            Text(widget.callerName, style: TextStyle(color: Colors.white, fontSize: 32)),
            SizedBox(height: 60),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(primary: Colors.red, shape: CircleBorder(), padding: EdgeInsets.all(20)),
                  icon: Icon(Icons.call_end),
                  label: SizedBox.shrink(),
                  onPressed: _decline,
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(primary: Colors.green, shape: CircleBorder(), padding: EdgeInsets.all(20)),
                  icon: Icon(Icons.call),
                  label: SizedBox.shrink(),
                  onPressed: _answer,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
