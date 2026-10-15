import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:calculator_messenger/core/config/app_config.dart';

const emailA = String.fromEnvironment('TEST_A_EMAIL'),
    passwordA = String.fromEnvironment('TEST_A_PASSWORD');
const emailB = String.fromEnvironment('TEST_B_EMAIL'),
    passwordB = String.fromEnvironment('TEST_B_PASSWORD');
void main() {
  test(
    'hosted two-account auth, realtime, idempotency and receipts',
    () async {
      final a = SupabaseClient(AppConfig.supabaseUrl, AppConfig.supabaseKey),
          b = SupabaseClient(AppConfig.supabaseUrl, AppConfig.supabaseKey);
      RealtimeChannel? channel;
      try {
        await a.auth.signInWithPassword(email: emailA, password: passwordA);
        await b.auth.signInWithPassword(email: emailB, password: passwordB);
        final peer = b.auth.currentUser!.id;
        final cid = await a.rpc('create_direct', params: {'peer': peer});
        final subscribed = Completer<void>(),
            received = Completer<Map<String, dynamic>>();
        final mid = const Uuid().v4();
        channel = b
            .channel('integration-$mid')
            .onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: 'public',
              table: 'messages',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'conversation_id',
                value: cid,
              ),
              callback: (event) {
                if (event.newRecord['id'] == mid && !received.isCompleted) {
                  received.complete(event.newRecord);
                }
              },
            )
            .subscribe((status, error) {
              if (status == RealtimeSubscribeStatus.subscribed &&
                  !subscribed.isCompleted) {
                subscribed.complete();
              }
            });
        await subscribed.future.timeout(const Duration(seconds: 20));
        final params = {
          'cid': cid,
          'mid': mid,
          'content':
              'Integration test ${DateTime.now().toUtc().toIso8601String()}',
        };
        await a.rpc('send_message', params: params);
        await a.rpc('send_message', params: params);
        final message = await received.future.timeout(
          const Duration(seconds: 20),
        );
        expect(message['sender_id'], a.auth.currentUser!.id);
        final rows = await b.from('messages').select('id').eq('id', mid);
        expect(rows, hasLength(1));
        await b.rpc('ack_messages', params: {'cid': cid, 'mark_read': true});
        final receipt = await a
            .from('message_receipts')
            .select()
            .eq('message_id', mid)
            .eq('user_id', peer)
            .single();
        expect(receipt['read_at'], isNotNull);
        await a.rpc('delete_message', params: {'mid': mid});
      } finally {
        if (channel != null) await b.removeChannel(channel);
        await a.dispose();
        await b.dispose();
      }
    },
    skip:
        !AppConfig.configured ||
            [emailA, passwordA, emailB, passwordB].any((s) => s.isEmpty)
        ? 'Needs deployed Supabase and two verified test accounts via ignored --dart-define-from-file configuration'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
