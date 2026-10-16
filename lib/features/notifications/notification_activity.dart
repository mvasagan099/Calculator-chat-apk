/// Notification routing contains opaque IDs only, never private preview data.
class NotificationActivity {
  static Map<String, dynamic>? parse(Map<String, dynamic> data) {
    final kind = data['kind'], id = data['resource_id'];
    if (!const ['message', 'call', 'missed_call'].contains(kind) ||
        id is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(id)) {
      return null;
    }
    final action = data['action'];
    return {
      'kind': kind,
      'resource_id': id,
      if (kind == 'call' && ['answer', 'reject'].contains(action))
        'action': action,
    };
  }
}
