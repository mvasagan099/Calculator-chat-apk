class MessageEditRevision {
  const MessageEditRevision({
    required this.id,
    required this.messageId,
    required this.previousBody,
    required this.editedAt,
  });

  final String id;
  final String messageId;
  final String previousBody;
  final DateTime editedAt;

  factory MessageEditRevision.fromJson(Map<String, dynamic> j) => MessageEditRevision(
    id: j['id'] as String,
    messageId: j['message_id'] as String,
    previousBody: (j['previous_body'] as String?) ?? '',
    editedAt: DateTime.tryParse(j['edited_at'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'message_id': messageId,
    'previous_body': previousBody,
    'edited_at': editedAt.toIso8601String(),
  };
}
