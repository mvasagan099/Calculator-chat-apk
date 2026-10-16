/// Retention is independent of encryption. Invalid expiration metadata fails
/// closed; old messages without a policy remain unchanged.
bool recordExpired(Map<String, dynamic> row, DateTime now) {
  final raw = row['expires_at'];
  if (raw == null) return false;
  final expiry = raw is String ? DateTime.tryParse(raw) : null;
  return expiry == null || !expiry.isAfter(now);
}

bool pruneLocalData(Map<String, dynamic> data, DateTime now) {
  var changed = false;
  for (final key in data.keys.toList()) {
    if ((key.startsWith('messages.') || key == 'outbox') && data[key] is List) {
      var collectionChanged = false;
      final retained = <dynamic>[];
      for (final value in data[key] as List) {
        if (value is! Map<String, dynamic>) {
          retained.add(value);
          continue;
        }
        if (recordExpired(value, now)) {
          collectionChanged = true;
          continue;
        }
        if (key.startsWith('messages.') &&
            (value['view_once'] == true || value['deleted_at'] != null) &&
            (value['body'] != '' ||
                value.containsKey('attachment') ||
                value['message_attachments'] is! List ||
                (value['message_attachments'] as List).isNotEmpty)) {
          final row = Map<String, dynamic>.from(value);
          row['body'] = '';
          row.remove('attachment');
          row['message_attachments'] = <Map<String, dynamic>>[];
          retained.add(row);
          collectionChanged = true;
        } else {
          retained.add(value);
        }
      }
      if (collectionChanged) {
        data[key] = retained;
        changed = true;
      }
    }
    if (key == 'conversations' && data[key] is List) {
      var collectionChanged = false;
      final retained = (data[key] as List).map((value) {
        if (value is! Map<String, dynamic>) return value;
        if (recordExpired({'expires_at': value['preview_expires_at']}, now) &&
            (value['preview'] != null || value['unread'] != 0)) {
          final row = Map<String, dynamic>.from(value);
          row['preview'] = null;
          row['unread'] = 0;
          collectionChanged = true;
          return row;
        }
        return value;
      }).toList();
      if (collectionChanged) {
        data[key] = retained;
        changed = true;
      }
    }
  }
  return changed;
}
