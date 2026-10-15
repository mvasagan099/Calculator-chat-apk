import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/features/notifications/notification_activity.dart';

void main() {
  const id = '12345678-1234-1234-1234-123456789abc';
  test('notification routing drops sender, text and image preview fields', () {
    for (final kind in ['message', 'call', 'missed_call']) {
      expect(
        NotificationActivity.parse({
          'kind': kind,
          'resource_id': id,
          'sender': 'Private sender',
          'body': 'Private text',
          'image': 'https://private.invalid/picture',
          'route': '/chat/untrusted',
        }),
        {'kind': kind, 'resource_id': id},
      );
    }
  });
  test('unrecognized notifications and malformed routing IDs are rejected', () {
    for (final input in <Map<String, dynamic>>[
      {},
      {'kind': 'unknown', 'resource_id': id},
      {'kind': 'message', 'resource_id': '/chat/private'},
      {'kind': 'call', 'resource_id': '------------------------------------'},
      {'kind': 'message', 'resource_id': 42},
    ]) {
      expect(NotificationActivity.parse(input), isNull);
    }
  });
}
