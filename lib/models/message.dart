// models/message.dart
enum MessageType { text, call }

class Message {
  final String id;
  final String sender;
  final String text;
  final MessageType type;
  final DateTime timestamp;

  Message({
    required this.id,
    required this.sender,
    required this.text,
    required this.type,
    required this.timestamp,
  });
}