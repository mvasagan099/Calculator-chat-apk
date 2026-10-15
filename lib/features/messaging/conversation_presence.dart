import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Ephemeral presence never substitutes for a durable delivery receipt.
abstract interface class PresenceTransport {
  void start({
    required void Function(String userId) onTyping,
    required void Function(bool online) onPresence,
    required void Function(bool connected) onConnection,
  });
  Future<void> track();
  Future<void> sendTyping();
  Future<void> close();
}

class SupabasePresenceTransport implements PresenceTransport {
  SupabasePresenceTransport(this.client, String cid, this.owner)
    : channel = client.channel(
        'conversation:$cid',
        opts: RealtimeChannelConfig(private: true, key: owner),
      );
  final SupabaseClient client;
  final String owner;
  final RealtimeChannel channel;
  bool _closed = false;
  bool get active => !_closed && client.auth.currentUser?.id == owner;

  @override
  void start({
    required void Function(String userId) onTyping,
    required void Function(bool online) onPresence,
    required void Function(bool connected) onConnection,
  }) {
    channel
        .onBroadcast(
          event: 'typing',
          callback: (payload) {
            final sender = payload['user_id'];
            if (active && sender is String) onTyping(sender);
          },
        )
        .onPresenceSync((_) {
          if (active) {
            onPresence(
              channel.presenceState().any((state) => state.key != owner),
            );
          }
        })
        .subscribe((status, _) {
          if (active) {
            onConnection(status == RealtimeSubscribeStatus.subscribed);
          }
        });
  }

  @override
  Future<void> track() async {
    // The same privacy control governs public last-seen and online visibility.
    final settings = await client
        .from('user_settings')
        .select('last_seen_visible')
        .eq('user_id', owner)
        .single();
    if (active && settings['last_seen_visible'] == true) {
      await channel.track({
        'online_at': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  @override
  Future<void> sendTyping() async {
    if (active) {
      await channel.sendBroadcastMessage(
        event: 'typing',
        payload: {'user_id': owner},
      );
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await client.removeChannel(channel);
  }
}

class ConversationPresence extends ChangeNotifier {
  ConversationPresence(SupabaseClient client, String cid)
    : this.withTransport(
        SupabasePresenceTransport(client, cid, client.auth.currentUser!.id),
        client.auth.currentUser!.id,
      );

  ConversationPresence.withTransport(this.transport, this.owner) {
    transport.start(
      onTyping: (sender) {
        if (_disposed || sender == owner || !_connected) return;
        typing = true;
        notifyListeners();
        _expiry?.cancel();
        _expiry = Timer(const Duration(seconds: 4), () {
          if (_disposed) return;
          typing = false;
          notifyListeners();
        });
      },
      onPresence: (value) {
        if (_disposed || !_connected) return;
        online = value;
        notifyListeners();
      },
      onConnection: (connected) {
        if (_disposed) return;
        _connected = connected;
        if (connected) {
          unawaited(transport.track().catchError((Object _) {}));
        } else {
          _expiry?.cancel();
          online = typing = false;
        }
        notifyListeners();
      },
    );
  }
  final PresenceTransport transport;
  final String owner;
  Timer? _expiry;
  DateTime? _lastTyping;
  bool _disposed = false, _connected = false;
  bool typing = false, online = false;

  void sendTyping() {
    if (_disposed || !_connected) return;
    final now = DateTime.now();
    if (_lastTyping != null &&
        now.difference(_lastTyping!) < const Duration(seconds: 2)) {
      return;
    }
    _lastTyping = now;
    unawaited(transport.sendTyping().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _expiry?.cancel();
    unawaited(transport.close().catchError((Object _) {}));
    super.dispose();
  }
}
