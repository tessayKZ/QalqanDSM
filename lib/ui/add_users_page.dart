import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/room.dart';
import '../services/matrix_chat_service.dart';

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

    final Room? newRoom = await MatrixService.createDirectChat(login);
    setState(() => _isLoading = false);

    if (newRoom == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to create chat')),
      );
      return;
    }

    final roomToUser = MatrixService.getDirectRoomIdToUserIdMap();

    final Map<String, List<String>> directContent = {};
    roomToUser.forEach((roomId, userId) {
      directContent.putIfAbsent(userId, () => []).add(roomId);
    });

    final host = Uri
        .parse(MatrixService.homeServer)
        .host;
    final userId = login.startsWith('@') ? login : '@$login:$host';
    directContent.update(
      userId,
          (list) => list..add(newRoom.id),
      ifAbsent: () => [newRoom.id],
    );

    final ok = await MatrixService.setDirectRooms(directContent);
    setState(() => _isLoading = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Warning: couldn’t update direct rooms')),
      );
      return;
    }

    await MatrixService.syncOnce();
    Navigator.of(context).pop(newRoom);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New chat'),
        centerTitle: true,
      ),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/background.png'),
            fit: BoxFit.cover,
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
