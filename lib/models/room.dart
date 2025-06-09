class Room {
  final String id;
  final String name;
  final Map<String, dynamic>? lastMessage;

  Room({
    required this.id,
    required this.name,
    this.lastMessage,
  });
}
