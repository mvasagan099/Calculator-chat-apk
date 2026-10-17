/// Notification routing contains opaque IDs only, never private preview data.
class NotificationActivity {
  static Map<String, dynamic>? parse(Map<String, dynamic> data) {
    final kind = data['kind'], id = data['resource_id'];
    if (!const ['message', 'call', 'missed_call', 'app_update'].contains(kind) ||
        id is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(id)) {
      return null;
    }
    final action = data['action'];
    final recipient = data['recipient_id'];
    if (recipient != null && (recipient is! String ||
        !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(recipient))) return null;
    return {
      'kind': kind,
      'resource_id': id,
      if (recipient != null) 'recipient_id': recipient,
      if (kind == 'call' && ['answer', 'reject'].contains(action))
        'action': action,
    };
  }

  static String tag(Map<String, dynamic> activity) => '${activity['kind']}:${activity['resource_id']}';
  static String body(Map<String, dynamic> activity) =>
      activity['kind'] == 'message' ? 'New update arrived' : 'New activity';
}
