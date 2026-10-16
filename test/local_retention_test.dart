import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/security/local_retention.dart';

void main() {
  test(
    'unchanged retention preserves list/row identity and reports no mutation',
    () {
      final rows = [
        {'id': 'retained', 'body': 'text'},
      ];
      final data = <String, dynamic>{'messages.chat': rows, 'outbox': []};
      expect(pruneLocalData(data, DateTime.utc(2026)), isFalse);
      expect(identical(data['messages.chat'], rows), isTrue);
      expect(identical(data['messages.chat'][0], rows[0]), isTrue);
    },
  );
  test(
    'offline cached/outbox content expires and view-once bodies are never cached',
    () {
      final now = DateTime.utc(2026, 10, 15);
      final expired = {
        'id': 'expired',
        'body': 'secret',
        'expires_at': now.toIso8601String(),
      };
      final future = {
        'id': 'future',
        'expires_at': now.add(const Duration(days: 1)).toIso8601String(),
      };
      final data = <String, dynamic>{
        'messages.chat': [
          expired,
          future,
          {'id': 'legacy', 'body': 'historical'},
          {
            'id': 'view',
            'view_once': true,
            'body': 'accidental plaintext',
            'attachment': {'filename': 'private'},
          },
        ],
        'outbox': [expired, future],
        'conversations': [
          {
            'preview': 'secret',
            'unread': 2,
            'preview_expires_at': now.toIso8601String(),
          },
        ],
      };
      pruneLocalData(data, now);
      expect((data['messages.chat'] as List).map((m) => m['id']), [
        'future',
        'legacy',
        'view',
      ]);
      expect((data['outbox'] as List).single['id'], 'future');
      expect((data['messages.chat'] as List).last['body'], '');
      expect((data['messages.chat'] as List).last['attachment'], isNull);
      expect(data['conversations'][0]['preview'], isNull);
      pruneLocalData(data, now.add(const Duration(days: 2)));
      expect(data['outbox'], isEmpty);
    },
  );
  test('invalid expiration fails closed while legacy records survive', () {
    expect(recordExpired({'expires_at': 'invalid'}, DateTime.now()), isTrue);
    expect(recordExpired({}, DateTime.now()), isFalse);
  });
}
