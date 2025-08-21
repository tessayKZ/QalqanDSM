import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import '../services/cred_store.dart';
import '../services/matrix_auth.dart';
import '../services/matrix_chat_service.dart';
import '../services/matrix_sync_service.dart';
import '../services/matrix_incoming_call_service.dart';
import 'package:qalqan_dsm/services/auth_data.dart';
import 'package:qalqan_dsm/services/call_store.dart';
import 'chat_list_page.dart';
import 'login_page.dart';

class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final creds = await CredStore.load();
      if (creds == null) {
        _go(const LoginPage());
        return;
      }

      final sdkOk  = await AuthService.login(user: creds.user, password: creds.password);
      final chatOk = await MatrixService.login(user: creds.user, password: creds.password);

      if (sdkOk && chatOk) {
        AuthDataCall.instance.login = creds.user;
        AuthDataCall.instance.password = creds.password;

        final mx.Client client = MatrixService.client;
        final myUserId = MatrixService.userId ?? AuthService.userId ?? creds.user;
        await CallStore.saveMyUserId(myUserId);

        MatrixSyncService.instance.attachClient(client);
        MatrixSyncService.instance.start();

        final callSvc = MatrixCallService(client, MatrixService.userId ?? '');
        callSvc.start();

        _go(const ChatListPage());
      } else {
        await CredStore.clear();
        _go(const LoginPage());
      }
    } catch (_) {
      await CredStore.clear();
      _go(const LoginPage());
    }
  }

  void _go(Widget page) {
    if (_navigated) return;
    _navigated = true;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(height: 8),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}