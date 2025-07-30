import 'dart:async';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/matrix_chat_service.dart';
import '../services/matrix_call_service.dart';
import '../services/matrix_auth.dart';
import '../ui/audio_call_page.dart';

class ChatDetailPage extends StatefulWidget {
  final Room room;
  const ChatDetailPage({Key? key, required this.room}) : super(key: key);

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Message> _messages = [];
  bool _isLoading = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _loadFullHistory();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFullHistory() async {
    final allHistory = await MatrixService.fetchRoomHistory(widget.room.id);
    setState(() {
      _messages = allHistory;
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      await MatrixService.forceSync();
      final newEvents = MatrixService.getRoomMessages(widget.room.id);
      final unique = newEvents.where((e) => !_messages.any(
            (m) => m.sender == e.sender && m.text == e.text && m.type == e.type,
      )).toList();
      if (unique.isNotEmpty) {
        setState(() {
          _messages.addAll(unique);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add(Message(
        sender: MatrixService.userId ?? '',
        text: text,
        type: MessageType.text,
      ));
      _messageController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    await MatrixService.sendMessage(widget.room.id, text);
    await MatrixService.forceSync();

    final newEvents = MatrixService.getRoomMessages(widget.room.id);
    final unique = newEvents.where((e) => !_messages.any(
          (m) => m.sender == e.sender && m.text == e.text && m.type == e.type,
    )).toList();
    if (unique.isNotEmpty) {
      setState(() {
        _messages.addAll(unique);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _showCallOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 36,
                      child: Text(
                        widget.room.name.isNotEmpty ? widget.room.name[0] : '',
                        style: const TextStyle(fontSize: 32),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.room.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.call),
                title: const Text('Audio call'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AudioCallPage(
                        roomId:    widget.room.id,
                        isIncoming: false,
                      ),
                    ),
                  );
                },
              ),

              ListTile(
                leading: const Icon(Icons.videocam),
                title: const Text('Video call'),
                onTap: () {
                  Navigator.pop(context);
                  // function start Video call
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel),
                title: const Text('Cancel'),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room.name),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            tooltip: 'Call',
            onPressed: _showCallOptions,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: ListView.builder(
                key: ValueKey(widget.room.id),
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isMe = msg.sender == (MatrixService.userId ?? '');
                  return _buildMessageBubble(msg, isMe);
                },
              ),
            ),
          Container(
            color: Colors.grey.shade200,
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.blue),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message msg, bool isMe) {
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    if (msg.type == MessageType.text) {
      final bgColor = isMe ? Colors.blue.shade100 : Colors.grey.shade300;
      final radius = isMe
          ? const BorderRadius.only(
        topLeft: Radius.circular(12),
        topRight: Radius.circular(12),
        bottomLeft: Radius.circular(12),
      )
          : const BorderRadius.only(
        topLeft: Radius.circular(12),
        topRight: Radius.circular(12),
        bottomRight: Radius.circular(12),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: Column(
          crossAxisAlignment: align,
          children: [
            Text(
              msg.sender.split(':').first.replaceFirst('@', ''),
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 2),
            Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: radius,
              ),
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
              child: Text(
                msg.text,
                style: const TextStyle(fontSize: 16, color: Colors.black87),
              ),
            ),
          ],
        ),
      );
    } else if (msg.type == MessageType.call) {
      final bgColor = Colors.orange.shade100;
      final radius = const BorderRadius.all(Radius.circular(12));
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: Column(
          crossAxisAlignment: align,
          children: [
            Text(
              msg.sender.split(':').first.replaceFirst('@', ''),
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 2),
            Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: radius,
                border: Border.all(color: Colors.orange),
              ),
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.call, color: Colors.orange),
                  const SizedBox(width: 6),
                  Text(
                    msg.text,
                    style: const TextStyle(fontSize: 16, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }
}