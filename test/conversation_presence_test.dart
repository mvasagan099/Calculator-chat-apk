import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/features/messaging/conversation_presence.dart';

class TestPresence implements PresenceTransport {
  late void Function(String) typing;
  late void Function(bool) presence, connection;
  int sends = 0, tracks = 0, closes = 0;
  bool fail = false;
  @override
  void start({
    required void Function(String) onTyping,
    required void Function(bool) onPresence,
    required void Function(bool) onConnection,
  }) {
    typing = onTyping;
    presence = onPresence;
    connection = onConnection;
  }

  @override
  Future<void> track() async {
    tracks++;
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> sendTyping() async {
    sends++;
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> close() async {
    closes++;
    if (fail) throw StateError('offline');
  }
}

void main() {
  testWidgets(
    'presence expires, ignores self, resets on disconnect and throttles typing',
    (tester) async {
      final transport = TestPresence();
      final presence = ConversationPresence.withTransport(transport, 'owner');
      presence.sendTyping();
      expect(transport.sends, 0);
      transport.connection(true);
      transport.typing('owner');
      expect(presence.typing, isFalse);
      transport.typing('peer');
      transport.presence(true);
      expect(presence.typing && presence.online, isTrue);
      presence.sendTyping();
      presence.sendTyping();
      expect(transport.sends, 1);
      await tester.pump(const Duration(seconds: 4));
      expect(presence.typing, isFalse);
      transport.typing('peer');
      transport.connection(false);
      expect(presence.typing || presence.online, isFalse);
      expect(transport.tracks, 1);
      presence.dispose();
    },
  );

  testWidgets(
    'late events and failed ephemeral operations cannot escape disposal',
    (tester) async {
      final transport = TestPresence()..fail = true;
      final presence = ConversationPresence.withTransport(transport, 'owner');
      int notifications = 0;
      presence.addListener(() => notifications++);
      transport.connection(true);
      presence.sendTyping();
      presence.dispose();
      final previous = notifications;
      transport.typing('peer');
      transport.presence(true);
      transport.connection(true);
      presence.sendTyping();
      await tester.pump(const Duration(seconds: 5));
      expect(notifications, previous);
      expect(transport.closes, 1);
      expect(transport.sends, 1);
    },
  );
}
