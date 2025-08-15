import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../services/matrix_chat_service.dart';
import '../services/matrix_incoming_call_service.dart';
import '../services/matrix_auth.dart';
import '../ui/incoming_audio_call_page.dart';
import '../ui/outgoing_audio_call_page.dart';
import 'package:file_selector/file_selector.dart';
import 'dart:ui';

class ChatDetailPage extends StatefulWidget {
  final Room room;
  const ChatDetailPage({Key? key, required this.room}) : super(key: key);

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> {
  bool _isUploading = false;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Message> _messages = [];
  bool _isLoading = true;

  void _scrollToBottom() {
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

  void _appendNewMessages() {
    final newEvents = MatrixService.getRoomMessages(widget.room.id);
    final unique = newEvents.where((e) => !_messages.any((m) => m.id == e.id)).toList();
    if (unique.isNotEmpty && mounted) {
      setState(() => _messages.addAll(unique));
      _scrollToBottom();
    }
  }

  void _startSyncLoop() async {
    while (mounted) {
      await MatrixService.forceSync(timeout: 5000);
      _appendNewMessages();
      }
  }

  List<Widget> _buildMessageList() {
    List<Widget> items = [];
    DateTime? lastDate;
    for (var i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      final msgDate = DateTime(msg.timestamp.year, msg.timestamp.month, msg.timestamp.day);
      if (lastDate == null || msgDate.isAfter(lastDate)) {
        items.add(_buildDateSeparator(msgDate));
        lastDate = msgDate;
      }
      final isMe = msg.sender == MatrixService.userId;
      items.add(_buildMessageBubble(msg, isMe, index: i));
    }
    return items;
  }

  Widget _buildDateSeparator(DateTime date) {
    final text = DateFormat('d MMMM yyyy').format(date);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(text, style: const TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }

  Future<void> _attachFile() async {
  final typeGroup = XTypeGroup(label: 'all', extensions: ['*']);
  final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
  if (file == null) return;

  final bytes = await file.readAsBytes();
  final name = file.name;
  }

  @override
  void initState() {
    super.initState();
    _loadFullHistory();
    _startSyncLoop();
    _messageController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
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
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();

    final tempId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _messages.add(Message(
        id:        tempId,
        sender:    MatrixService.userId!,
        text:      text,
        type:      MessageType.text,
        timestamp: DateTime.now(),
      ));
    });
    _scrollToBottom();

    final serverEventId = await MatrixService.sendMessage(widget.room.id, text);
    if (serverEventId == null) return;

      final idx = _messages.indexWhere((m) => m.id == tempId);
      if (idx != -1) {
        _messages[idx] = Message(
          id:        serverEventId,
          sender:    MatrixService.userId!,
          text:      text,
          type:      MessageType.text,
          timestamp: _messages[idx].timestamp,
        );
      }
      setState(() {});
      await MatrixService.forceSync();
      _appendNewMessages();
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
                      builder: (_) => OutgoingAudioCallPage(roomId: widget.room.id, initialName: widget.room.name),
                    ),
                  );
                },
              ),

              ListTile(
                leading: const Icon(Icons.videocam),
                title: const Text('Video call'),
                onTap: () {
                  Navigator.pop(context);
                  showDialog(
                    context: context,
                    builder: (ctx) {
                      return Dialog(
                        backgroundColor: Colors.transparent,
                        child: Center(
                          child: Container(
                            width: 200,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Coming soon',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 16),
                                ),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: const Text('OK'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
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
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,

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
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/background.png',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: Container(color: Colors.black.withOpacity(0)),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: _buildMessageList(),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.white70, Colors.white54],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                  child: Row(
                    children: [
                      _isUploading
                          ? const SizedBox(
                        width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                          : IconButton(
                        icon: const Icon(Icons.attach_file),
                        onPressed: () async {
                          setState(() => _isUploading = true);
                          await _attachFile();
                          setState(() => _isUploading = false);
                        },
                      ),
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
                        icon: const Icon(Icons.send),
                        onPressed: _messageController.text.trim().isEmpty ? null : _sendMessage,
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message msg, bool isMe, { required int index }) {
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final timeText = DateFormat('HH:mm, dd.MM.yyyy').format(msg.timestamp);

    Widget header = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          msg.sender.split(':').first.replaceFirst('@', ''),
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(width: 6),
        Text(
          timeText,
          style: const TextStyle(fontSize: 10, color: Colors.black45),
        ),
      ],
    );

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
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: CircleAvatar(
                  radius: 12,
                  child: Text(
                    msg.sender.split(':').first.substring(0,1).toUpperCase(),
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: align,
                children: [
                  header,
                  const SizedBox(height: 4),
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
            ),
            if (isMe)
              const SizedBox(width: 32),
          ],
        ),
      );
    } else if (msg.type == MessageType.call) {
      final bgColor = Colors.orange.shade100;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: Column(
          crossAxisAlignment: align,
          children: [
            header,
            const SizedBox(height: 4),
            Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange),
              ),
              padding: const EdgeInsets.symmetric(
                  vertical: 8.0, horizontal: 12.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.call, color: Colors.orange),
                  const SizedBox(width: 6),
                  Text(
                    msg.text,
                    style: const TextStyle(
                        fontSize: 16, color: Colors.black87),
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