import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ConversationPresence extends ChangeNotifier {
  ConversationPresence(this.client, this.cid) {
    channel = client.channel(
      'conversation:$cid',
      opts: RealtimeChannelConfig(
        private: true,
        key: client.auth.currentUser!.id,
      ),
    );
    channel
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            if (payload['user_id'] != client.auth.currentUser!.id) {
              typing = true;
              notifyListeners();
              _expiry?.cancel();
              _expiry = Timer(const Duration(seconds: 4), () {
                typing = false;
                notifyListeners();
              });
            }
          },
        )
        .onPresenceSync((_) {
          online = channel.presenceState().any(
            (state) => state.key != client.auth.currentUser!.id,
          );
          notifyListeners();
        })
        .subscribe((status, error) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            channel.track({
              'online_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
        });
  }
  final SupabaseClient client;
  final String cid;
  late final RealtimeChannel channel;
  Timer? _expiry;
  DateTime? _lastTyping;
  bool typing = false, online = false;
  void sendTyping() {
    if (_lastTyping != null &&
        DateTime.now().difference(_lastTyping!) < const Duration(seconds: 2)) {
      return;
    }
    _lastTyping = DateTime.now();
    unawaited(
      channel.sendBroadcastMessage(
        event: 'typing',
        payload: {'user_id': client.auth.currentUser!.id},
      ),
    );
  }

  @override
  void dispose() {
    _expiry?.cancel();
    client.removeChannel(channel);
    super.dispose();
  }
}
