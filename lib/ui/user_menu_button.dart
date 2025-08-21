import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import '../services/matrix_chat_service.dart';
import '../services/matrix_auth.dart';
import '../services/cred_store.dart';
import 'package:qalqan_dsm/services/auth_data.dart';
import 'package:qalqan_dsm/services/call_store.dart';
import 'login_page.dart';
import 'change_password_page.dart';

class UserMenuButton extends StatelessWidget {
  const UserMenuButton({super.key});

  String _displayLogin() {
    final uid = MatrixService.userId ?? AuthService.userId ?? AuthDataCall.instance.login ?? '';
    if (uid.isEmpty) return '@unknown';
    if (uid.startsWith('@') && uid.contains(':')) {
      final lp = uid.substring(1, uid.indexOf(':'));
      return '@$lp';
    }
    return uid.startsWith('@') ? uid : '@$uid';
  }

  Future<void> _logout(BuildContext context) async {
    try { await AuthService.logout(); } catch (_) {}
    try { await CredStore.clear(); } catch (_) {}

    try { final my = await CallStore.loadMyUserId(); if (my != null) await CallStore.saveMyUserId(''); } catch (_) {}

    if (context.mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
            (route) => false,
      );
    }
  }

  void _showSheet(BuildContext context) {
    final login = _displayLogin();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: const Text('You are logged in as'),
                subtitle: Text(login, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              const Divider(height: 8),
              ListTile(
                leading: const Icon(Icons.lock_reset),
                title: const Text('Change password'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text('Log out',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _logout(context);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.account_circle),
      onPressed: () => _showSheet(context),
      tooltip: 'Profile',
    );
  }
}