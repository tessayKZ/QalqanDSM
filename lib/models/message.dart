// models/message.dart
enum MessageType { text, call, image, file }

class Message {
  final String id;
  final String sender;
  final String text;
  final MessageType type;
  final DateTime timestamp;

  final String? mediaUrl;
  final String? thumbUrl;
  final String? fileName;
  final int?    fileSize;
  final String? mimeType;

  const Message({
    required this.id,
    required this.sender,
    required this.text,
    required this.type,
    required this.timestamp,
    this.mediaUrl,
    this.thumbUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
  });

  Message copyWith({
    String? id,
    String? sender,
    String? text,
    MessageType? type,
    DateTime? timestamp,
    String? mediaUrl,
    String? thumbUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
  }) {
    return Message(
      id: id ?? this.id,
      sender: sender ?? this.sender,
      text: text ?? this.text,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      mediaUrl: mediaUrl ?? this.mediaUrl,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
    );
  }
}