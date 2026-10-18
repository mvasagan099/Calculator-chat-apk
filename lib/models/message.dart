class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.body,
    required this.kind,
    required this.createdAt,
    this.replyTo,
    this.senderName,
    this.deleted = false,
    this.edited = false,
    this.forwarded = false,
    this.attachment,
    this.reactions = const [],
    this.receipts = const [],
    this.pending = false,
    this.failed = false,
    this.expiresAt,
    this.viewOnce = false,
    this.viewOnceOpenedAt,
    this.starred = false,
  });
  final String id, conversationId, body, kind;
  final String? senderId, replyTo, senderName;
  final DateTime createdAt;
  final DateTime? expiresAt, viewOnceOpenedAt;
  final bool viewOnce, starred;
  bool get expired => expiresAt != null && !expiresAt!.isAfter(DateTime.now());
  final bool deleted, edited, forwarded, pending, failed;
  final Map<String, dynamic>? attachment;
  final List<Map<String, dynamic>> reactions, receipts;

  /// Matches the PostgreSQL keyset cursor, including equal timestamps.
  static int newestFirst(ChatMessage a, ChatMessage b) {
    final time = b.createdAt.compareTo(a.createdAt);
    return time == 0 ? b.id.compareTo(a.id) : time;
  }

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'],
    conversationId: j['conversation_id'],
    senderId: j['sender_id'],
    senderName: j['profiles']?['display_name'],
    body: j['body'] ?? '',
    kind: j['kind'],
    createdAt: DateTime.parse(j['created_at']),
    replyTo: j['reply_to'],
    deleted: j['deleted_at'] != null,
    edited: j['edited_at'] != null,
    forwarded: j['forwarded'] ?? false,
    attachment:
        j['attachment'] ??
        (j['message_attachments'] is List
            ? (j['message_attachments'] as List)
                  .cast<Map<String, dynamic>>()
                  .firstOrNull
            : j['message_attachments']),
    reactions: (j['message_reactions'] as List? ?? [])
        .cast<Map<String, dynamic>>(),
    receipts: (j['message_receipts'] as List? ?? [])
        .cast<Map<String, dynamic>>(),
    pending: j['pending'] ?? false,
    failed: j['failed'] ?? false,
    expiresAt: DateTime.tryParse(j['expires_at'] ?? ''),
    viewOnce: j['view_once'] ?? false,
    viewOnceOpenedAt: DateTime.tryParse(j['view_once_opened_at'] ?? ''),
    starred: j['starred'] == true,
  );

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? senderName,
    String? body,
    String? kind,
    DateTime? createdAt,
    String? replyTo,
    bool? deleted,
    bool? edited,
    bool? forwarded,
    Map<String, dynamic>? attachment,
    List<Map<String, dynamic>>? reactions,
    List<Map<String, dynamic>>? receipts,
    bool? pending,
    bool? failed,
    DateTime? expiresAt,
    bool? viewOnce,
    DateTime? viewOnceOpenedAt,
    bool? starred,
  }) => ChatMessage(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    senderId: senderId ?? this.senderId,
    senderName: senderName ?? this.senderName,
    body: body ?? this.body,
    kind: kind ?? this.kind,
    createdAt: createdAt ?? this.createdAt,
    replyTo: replyTo ?? this.replyTo,
    deleted: deleted ?? this.deleted,
    edited: edited ?? this.edited,
    forwarded: forwarded ?? this.forwarded,
    attachment: attachment ?? this.attachment,
    reactions: reactions ?? this.reactions,
    receipts: receipts ?? this.receipts,
    pending: pending ?? this.pending,
    failed: failed ?? this.failed,
    expiresAt: expiresAt ?? this.expiresAt,
    viewOnce: viewOnce ?? this.viewOnce,
    viewOnceOpenedAt: viewOnceOpenedAt ?? this.viewOnceOpenedAt,
    starred: starred ?? this.starred,
  );
}
