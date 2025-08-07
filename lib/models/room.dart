class Room {
  final String id;
  String name;
  final Map<String, dynamic>? lastMessage;

  Room({
    required this.id,
    required this.name,
    this.lastMessage,
  });
}
