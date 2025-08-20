import 'dart:async';
import 'dart:ui';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart' as mx;
import '../models/message.dart';
import '../models/room.dart';
import '../services/matrix_auth.dart';
import '../services/matrix_chat_service.dart';
import '../services/matrix_sync_service.dart';
import '../ui/incoming_audio_call_page.dart';
import '../ui/outgoing_audio_call_page.dart';

class ChatDetailPage extends StatefulWidget {
  final Room room;
  const ChatDetailPage({Key? key, required this.room}) : super(key: key);

  @override
  State<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends State<ChatDetailPage> with WidgetsBindingObserver {
  bool _isUploading = false;
  bool _isLoading = true;

  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final Map<String, String> _pendingByTxn = <String, String>{};
  final List<Message> _messages = <Message>[];
  StreamSubscription<mx.Event>? _subRoom;
  final Set<String> _pendingTempIds = <String>{};
  Timer? _liveTimer;

  void _startLiveTimer() {
    _liveTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) async {
      await MatrixService.forceSync(timeout: 0);
      _mergeRecentFromSync();
    });
  }

  void _stopLiveTimer() {
    _liveTimer?.cancel();
    _liveTimer = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _loadFullHistory();
    _subRoom = MatrixSyncService.instance

        .roomEvents(widget.room.id)
        .where((e) => e.type == 'm.room.message' || e.type == 'm.room.encrypted')
        .listen(_onRoomEvent, onError: (e, st) {
      debugPrint('roomEvents error: $e\n$st');
      _showSnack('Ошибка получения событий: $e');
    });

    _messageController.addListener(() => setState(() {}));
    _startLiveTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subRoom?.cancel();
    _stopLiveTimer();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startLiveTimer();
    } else {
      _stopLiveTimer();
    }
  }

  Future<void> _loadFullHistory() async {
    try {
      final allHistory = await MatrixService.fetchRoomHistory(widget.room.id);
          final pending = _messages
              .where((m) => _pendingTempIds.contains(m.id))
              .toList();
          setState(() {
            _messages
              ..clear()
              ..addAll(allHistory);
            for (final p in pending) {
              if (!_messages.any((m) => m.id == p.id)) {
                _messages.add(p);
              }
            }
            _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
            _isLoading = false;
          });
      _mergeRecentFromSync();
      _scrollToBottom();
    } catch (e, st) {
      debugPrint('load history error: $e\n$st');
      setState(() => _isLoading = false);
      _showSnack('Не удалось загрузить историю чата');
    }
  }

  String? _extractTxnId(mx.Event e) {
    try {
      final u = (e.unsigned as Map?)?.cast<String, dynamic>();
      final t = u?['transaction_id'] as String?;
      if (t != null && t.isNotEmpty) return t;
    } catch (_) {}
    try {
      final dynamic dyn = e;
      final t = (dyn.transactionId ?? dyn.txnId ?? dyn.unsignedTransactionId) as String?;
      if (t != null && t.isNotEmpty) return t;
    } catch (_) {}
    return null;
  }

   void _onRoomEvent(mx.Event e) {
       final incoming = _eventToUiMessage(e);
       if (incoming == null) return;
    final txid = _extractTxnId(e);

    setState(() {
      if (txid != null && _pendingByTxn.containsKey(txid)) {
        final tempId = _pendingByTxn.remove(txid)!;
        _pendingTempIds.remove(tempId);

        final idx = _messages.indexWhere((m) => m.id == tempId);
        if (idx != -1) {
          _messages[idx] = incoming;
          return;
        }
        if (!_messages.any((m) => m.id == incoming.id)) {
          _messages.add(incoming);
        }
        return;
      }

      if (incoming.sender == MatrixService.userId) {
        final dupIdx = _messages.indexWhere((m) =>
        m.id.startsWith('t_') &&
            m.sender == incoming.sender &&
            m.type == MessageType.text &&
            m.text == incoming.text &&
            (incoming.timestamp.difference(m.timestamp).inSeconds).abs() <= 10
        );
        if (dupIdx != -1) {
          _pendingTempIds.remove(_messages[dupIdx].id);
          _messages[dupIdx] = incoming;
          return;
        }
      }

      if (!_messages.any((m) => m.id == incoming.id)) {
        _messages.add(incoming);
      }
    });

    _scrollToBottom();
  }

    void _mergeRecentFromSync() {
        final recent = MatrixService.getRoomMessages(widget.room.id);
        if (recent.isEmpty) return;

        setState(() {
          for (final incoming in recent) {
            if (_messages.any((m) => m.id == incoming.id)) continue;

            if (incoming.sender == MatrixService.userId) {
              final dupIdx = _messages.indexWhere((m) =>
                  m.id.startsWith('t_') &&
                  m.sender == incoming.sender &&
                  m.type == incoming.type &&
                  m.text == incoming.text &&
                  (incoming.timestamp.difference(m.timestamp).inSeconds).abs() <= 15);
              if (dupIdx != -1) {
                _pendingTempIds.remove(_messages[dupIdx].id);
                _messages[dupIdx] = incoming;
                continue;
              }
            }

            _messages.add(incoming);
          }
          _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        });
        _scrollToBottom();
      }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();

    final tempId = 't_${DateTime.now().microsecondsSinceEpoch}';
    final txnId  = 'c_${DateTime.now().microsecondsSinceEpoch}';

    _pendingTempIds.add(tempId);
    _pendingByTxn[txnId] = tempId;

    setState(() {
      _messages.add(Message(
        id: tempId,
        sender: MatrixService.userId ?? '',
        text: text,
        type: MessageType.text,
        timestamp: DateTime.now(),
      ));
    });
    _scrollToBottom();

    final eventId = await MatrixService.sendMessage(widget.room.id, text, txnId: txnId);
    if (!mounted) return;

    if (eventId == null) {
      setState(() {
        _pendingTempIds.remove(tempId);
        _pendingByTxn.remove(txnId);
        _messages.removeWhere((m) => m.id == tempId);
      });
      _showSnack('Не удалось отправить сообщение');
      return;
    }

    setState(() {
      _pendingTempIds.remove(tempId);
      _pendingByTxn.remove(txnId);

      final already = _messages.indexWhere((m) => m.id == eventId);
      if (already != -1) {
        _messages.removeWhere((m) => m.id == tempId);
      } else {
        final idx = _messages.indexWhere((m) => m.id == tempId);
        if (idx != -1) {
          _messages[idx] = _messages[idx].copyWith(id: eventId);
              } else {
                _messages.add(Message(
                  id: eventId,
                  sender: MatrixService.userId ?? '',
                  text: text,
                  type: MessageType.text,
                  timestamp: DateTime.now(),
                ));
        }
      }
    });
  }

  Future<void> _attachFile() async {
    try {
      final typeGroup = XTypeGroup(label: 'any', extensions: ['*']);
      final XFile? file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;

      setState(() => _isUploading = true);

      final name = file.name;
      final bytes = await file.readAsBytes();
      final mime = _guessMimeByName(name);

      if (mime.startsWith('image/')) {
        await MatrixService.sendImage(widget.room.id, name, bytes, mime);
      } else {
        await MatrixService.sendFile(widget.room.id, name, bytes, mime);
      }
    } catch (e) {
      _showSnack('Не удалось отправить файл');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  String _guessMimeByName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.rar')) return 'application/vnd.rar';
    if (lower.endsWith('.7z')) return 'application/x-7z-compressed';
    if (lower.endsWith('.txt')) return 'text/plain';
    return 'application/octet-stream';
  }

  Message? _eventToUiMessage(mx.Event e) {
    final content = (e.content ?? const {}) as Map<String, dynamic>;
    final msgtype = content['msgtype'] as String?;
    final body    = (content['body'] as String?) ?? '';
    final type    = e.type;

        if (type == 'm.room.encrypted' && msgtype == null) {

          return null;
        }

        final eventId = e.eventId;
        if (eventId == null || eventId.isEmpty) {
          return null;
        }

    final int ts = (e.originServerTs is int)
        ? e.originServerTs as int
        : int.tryParse('${e.originServerTs}') ?? DateTime.now().millisecondsSinceEpoch;

    if (msgtype == 'm.image') {
      final mxcUrl = content['url'] as String?;
      final info = (content['info'] as Map?)?.cast<String, dynamic>();
      final thumbMxc = info?['thumbnail_url'] as String?;
      final mime = (info?['mimetype'] as String?) ?? 'image/*';
      final size = (info?['size'] as num?)?.toInt();

      final mediaUrl = MatrixService.mxcToHttp(mxcUrl);
      final thumbUrl = MatrixService.mxcToHttp(
          thumbMxc, width: 512, height: 512, thumbnail: true);

      return Message(
        id: eventId,
        sender: e.senderId ?? '',
        text: body,

        type: MessageType.image,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
        mediaUrl: mediaUrl,
        thumbUrl: thumbUrl ?? mediaUrl,
        fileName: body.isNotEmpty ? body : null,
        fileSize: size,
        mimeType: mime,
      );
    }

    if (msgtype == 'm.file') {
      final mxcUrl = content['url'] as String?;
      final info = (content['info'] as Map?)?.cast<String, dynamic>();
      final mime = (info?['mimetype'] as String?) ?? 'application/octet-stream';
      final size = (info?['size'] as num?)?.toInt();
      final name = body.isNotEmpty ? body : (content['filename'] as String?) ??
          'file';

      final mediaUrl = MatrixService.mxcToHttp(mxcUrl);

      return Message(
        id: eventId,
        sender: e.senderId ?? '',
        text: name,

        type: MessageType.file,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
        mediaUrl: mediaUrl,
        fileName: name,
        fileSize: size,
        mimeType: mime,
      );
    }


    final isCall = type.startsWith('m.call');
    return Message(
      id: eventId,
      sender: e.senderId ?? '',
      text: body,
      type: isCall ? MessageType.call : MessageType.text,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
    );
  }


  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _showSnack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }


  List<Widget> _buildMessageList() {
    final items = <Widget>[];
    DateTime? lastDate;

    for (var i = 0; i < _messages.length; i++) {
      final msg = _messages[i];
      final msgDate = DateTime(
          msg.timestamp.year, msg.timestamp.month, msg.timestamp.day);


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

  Widget _buildMessageBubble(Message msg, bool isMe, {required int index}) {
    final align = isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final timeText = DateFormat('HH:mm, dd.MM.yyyy').format(msg.timestamp);

    final header = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          msg.sender
              .split(':')
              .first
              .replaceFirst('@', ''),
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(width: 6),
        Text(timeText,
            style: const TextStyle(fontSize: 10, color: Colors.black45)),
        if (isMe && _pendingTempIds.contains(msg.id)) ...[
          const SizedBox(width: 6),
          const SizedBox(
            width: 10, height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ],
      ],
    );


    if (msg.type == MessageType.image) {
      return _buildImageBubble(msg, isMe, header);
    }
    if (msg.type == MessageType.file) {
      return _buildFileBubble(msg, isMe, header);
    }


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
                    msg.sender
                        .split(':')
                        .first
                        .substring(0, 1)
                        .toUpperCase(),
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
                        color: bgColor, borderRadius: radius),
                    padding: const EdgeInsets.symmetric(
                        vertical: 8.0, horizontal: 12.0),
                    child: Text(msg.text, style: const TextStyle(
                        fontSize: 16, color: Colors.black87)),
                  ),
                ],
              ),
            ),
            if (isMe) const SizedBox(width: 32),
          ],
        ),
      );
    }


    if (msg.type == MessageType.call) {
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
                  Text(msg.text, style: const TextStyle(
                      fontSize: 16, color: Colors.black87)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
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
                    Text(widget.room.name,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
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
                      builder: (_) =>
                          OutgoingAudioCallPage(
                            roomId: widget.room.id,
                            initialName: widget.room.name,
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
                  showDialog(
                    context: context,
                    builder: (ctx) =>
                        Dialog(
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
                                  const Text('Coming soon',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 16)),
                                  const SizedBox(height: 12),
                                  TextButton(
                                      onPressed: () => Navigator.of(ctx).pop(),
                                      child: const Text('OK')),
                                ],
                              ),
                            ),
                          ),
                        ),
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
        final canSend = !_isLoading && _messageController.text.trim().isNotEmpty;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.room.name),
        centerTitle: true,
        actions: [
          IconButton(icon: const Icon(Icons.call),
              tooltip: 'Call',
              onPressed: _showCallOptions),
        ],
      ),
      body: Stack(
        children: [

          Positioned.fill(
            child: Image.asset('assets/background.png', fit: BoxFit.cover),
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
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 6),
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
                          ? const SizedBox(width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(
                        icon: const Icon(Icons.attach_file),
                        onPressed: () async {
                          setState(() => _isUploading = true);
                          await _attachFile();
                          if (mounted) setState(() => _isUploading = false);
                        },
                      ),
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => canSend ? _sendMessage() : null,
                          decoration: const InputDecoration(
                            hintText: 'Type a message...',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: canSend ? _sendMessage : null,
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

  Widget _buildImageBubble(Message msg, bool isMe, Widget header) {
    final url = msg.thumbUrl ?? msg.mediaUrl;
    if (url == null) {
      return _bubbleWrapper(
        isMe: isMe,
        header: header,
        child: Text(msg.text.isNotEmpty ? msg.text : '[image]'),
      );
    }

    final radius = BorderRadius.circular(12);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe)
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: CircleAvatar(
                  radius: 12, child: Icon(Icons.person, size: 12)),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => _openImageViewer(msg.mediaUrl ?? url),
                  child: ClipRRect(
                    borderRadius: radius,
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Image.network(
                        url,
                        fit: BoxFit.cover,
                        loadingBuilder: (c, w, p) =>
                        p == null ? w : const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        errorBuilder: (c, e, st) =>
                            Container(
                              color: Colors.black12,
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image),
                            ),
                      ),
                    ),
                  ),
                ),
                if (msg.text.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                        vertical: 6, horizontal: 10),
                    child: Text(msg.text),
                  ),
                ],
              ],
            ),
          ),
          if (isMe) const SizedBox(width: 32),
        ],
      ),
    );
  }

  Widget _buildFileBubble(Message msg, bool isMe, Widget header) {
    final name = msg.fileName ?? (msg.text.isEmpty ? '[file]' : msg.text);
    final size = msg.fileSize != null ? _readableSize(msg.fileSize!) : null;
    final mime = msg.mimeType ?? 'application/octet-stream';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 12.0),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment
            .start,
        children: [
          header,
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400),
            ),
            padding: const EdgeInsets.all(10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_fileIconByMime(mime), color: Colors.blueGrey),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (size != null)
                        Text(size, style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: (msg.mediaUrl != null)
                      ? () =>
                      launchUrl(Uri.parse(msg.mediaUrl!), mode: LaunchMode.externalApplication)
                      : null,
                  icon: const Icon(Icons.download),
                  label: const Text('Открыть'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubbleWrapper({
    required bool isMe,
    required Widget header,
    required Widget child,
  }) {
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
            const Padding(
              padding: EdgeInsets.only(right: 8.0),
              child: CircleAvatar(
                  radius: 12, child: Icon(Icons.person, size: 12)),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 4),
                Container(
                  decoration: BoxDecoration(
                      color: bgColor, borderRadius: radius),
                  padding: const EdgeInsets.symmetric(
                      vertical: 8.0, horizontal: 12.0),
                  child: child,
                ),
              ],
            ),
          ),
          if (isMe) const SizedBox(width: 32),
        ],
      ),
    );
  }

  void _openImageViewer(String url) {
    showDialog(
      context: context,
      builder: (_) =>
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              color: Colors.black.withOpacity(0.9),
              alignment: Alignment.center,
              child: InteractiveViewer(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image, color: Colors.white, size: 48),
                ),
              ),
            ),
          ),
    );
  }

  IconData _fileIconByMime(String mime) {
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.startsWith('video/')) return Icons.videocam;
    if (mime.startsWith('audio/')) return Icons.audiotrack;
    if (mime == 'application/pdf') return Icons.picture_as_pdf;
    if (mime.contains('zip') || mime.contains('compressed'))
      return Icons.archive;
    return Icons.insert_drive_file;
  }

  String _readableSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(
        size < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
  }
}
