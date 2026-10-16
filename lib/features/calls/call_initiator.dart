import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../providers/app_providers.dart';

final callInitiatorProvider = Provider(
  (ref) => CallInitiator(ref.watch(supabaseProvider)),
);

/// Keep one request identity across duplicate taps and ambiguous network errors.
/// A new account or successful response cannot reuse a previous owner's request.
class CallInitiator {
  CallInitiator(this.client);
  final SupabaseClient client;
  final _requests = <String, String>{};
  final _pending = <String, Future<String>>{};
  Future<String> start(String conversation, bool video) {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('Sign in first');
    final key = '$owner:$conversation:$video';
    return _pending.putIfAbsent(key, () => _start(key, conversation, video));
  }

  Future<String> _start(String key, String conversation, bool video) async {
    final request = _requests.putIfAbsent(key, () => const Uuid().v4());
    try {
      final id =
          await client.rpc(
                'begin_call',
                params: {
                  'cid': conversation,
                  'use_video': video,
                  'request': request,
                },
              )
              as String;
      _requests.remove(key);
      return id;
    } on PostgrestException {
      _requests.remove(key); // Server rejected it; a deliberate retry is new.
      rethrow;
    } finally {
      _pending.remove(key);
    }
  }
}
