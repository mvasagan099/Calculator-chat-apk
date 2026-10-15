/// Retention is independent of encryption. Invalid expiration metadata fails
/// closed; old messages without a policy remain unchanged.
bool recordExpired(Map<String, dynamic> row, DateTime now) {
  final raw = row['expires_at'];
  if (raw == null) return false;
  final expiry = raw is String ? DateTime.tryParse(raw) : null;
  return expiry == null || !expiry.isAfter(now);
}

void pruneLocalData(Map<String, dynamic> data, DateTime now) {
  for (final key in data.keys.toList()) {
    if ((key.startsWith('messages.') || key == 'outbox') && data[key] is List) {
      data[key] = (data[key] as List)
          .where(
            (value) =>
                value is! Map<String, dynamic> || !recordExpired(value, now),
          )
          .map((value) {
            if (value is! Map<String, dynamic>) return value;
            final row = Map<String, dynamic>.from(value);
            if (key.startsWith('messages.') &&
                (row['view_once'] == true || row['deleted_at'] != null)) {
              row['body'] = '';
              row.remove('attachment');
              row['message_attachments'] = <Map<String, dynamic>>[];
            }
            return row;
          })
          .toList();
    }
    if (key == 'conversations' && data[key] is List) {
      data[key] = (data[key] as List).map((value) {
        if (value is! Map<String, dynamic>) return value;
        final row = Map<String, dynamic>.from(value);
        if (recordExpired({'expires_at': row['preview_expires_at']}, now)) {
          row['preview'] = null;
          row['unread'] = 0;
        }
        return row;
      }).toList();
    }
  }
}
