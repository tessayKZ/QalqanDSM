import 'package:flutter/material.dart';
import '../models/room.dart';
import '../services/matrix_chat_service.dart';
import 'chat_detail_page.dart';

class AddUsersPage extends StatefulWidget {
  const AddUsersPage({Key? key}) : super(key: key);

  @override
  State<AddUsersPage> createState() => _AddUsersPageState();
}

class _AddUsersPageState extends State<AddUsersPage> {
  final TextEditingController _loginController = TextEditingController();
  bool _isLoading = false;

  Future<void> _startChat() async {
    final login = _loginController.text.trim();
    if (login.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a login')),
      );
      return;
    }
    setState(() => _isLoading = true);
    final exists = await MatrixService.userExists(login);
    if (!exists) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User not found on server')),
      );
      return;
    }
    final room = await MatrixService.createDirectChat(login);
    setState(() => _isLoading = false);
    if (room != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatDetailPage(room: room)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to create chat')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New chat'),
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6A11CB), Color(0xFF2575FC)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            margin: const EdgeInsets.symmetric(horizontal: 24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.person_add, size: 64, color: Color(0xFF6A11CB)),
                  const SizedBox(height: 16),
                  Text(
                    'Start Chat',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _loginController,
                    decoration: InputDecoration(
                      labelText: 'User Login',
                      prefixIcon: const Icon(Icons.alternate_email),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _startChat,
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 4,
                      ),
                      child: _isLoading
                          ? const CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      )
                          : const Text(
                        'Start Chat',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ]
              ),
            ),
          ),
        ),
      ),
    );
  }
}
