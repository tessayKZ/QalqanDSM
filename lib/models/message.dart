enum MessageType { text, call }

class Message {
  final String sender;
  final String text;
  final MessageType type;

  Message({
    required this.sender,
    required this.text,
    this.type = MessageType.text,
  });
}
