import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/local_cache.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'repository_isolation_test.dart' show signIn;

class _FailedCache implements LocalCache {
  @override
  Map<String, dynamic> data = {};
  bool cleared = false, forgotten = false;
  @override
  Future<void> initialize() async => throw StateError('Encrypted key missing');
  @override
  Future<void> save() async => throw StateError('Should not use failed cache');
  @override
  Future<void> forget() async { forgotten = true; }
  @override
  Future<void> clear() async { cleared = true; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unavailable encrypted cache permits online reads and confirmed text only, without clearing files', () async {
    final failed = _FailedCache();
    final sent = <Map<String, dynamic>>[];
    final viewOnceSent = <Map<String, dynamic>>[];
    var online = true;
    final client = SupabaseClient('https://fixture.invalid', 'public-fixture-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        http.Response json(Object data, [int status = 200]) => http.Response(
          jsonEncode(data), status, headers: {'content-type': 'application/json'}, request: request);
        if (request.url.path.endsWith('/rpc/conversation_list')) {
          return json([{'id': 'chat', 'title': 'Private', 'archived': false}]);
        }
        if (request.url.path.endsWith('/rpc/send_message') ||
            request.url.path.endsWith('/rpc/send_view_once_message')) {
          if (!online) throw http.ClientException('offline');
          final data = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
          if (request.url.path.endsWith('/rpc/send_view_once_message')) {
            viewOnceSent.add(data);
          } else {
            sent.add(data);
          }
          return json('delivered');
        }
        throw StateError('Unexpected HTTP request');
      }));
    final repo = MessengerRepository(client, connectivity: const Stream.empty(),
      cacheFactory: (_) => failed);
    try {
      await signIn(client, 'owner-a');
      final rows = await repo.conversations().first.timeout(const Duration(seconds: 4));
      expect(rows.single['id'], 'chat');
      expect(repo.onlineOnly, isTrue);
      expect(failed.forgotten, isTrue);
      expect(failed.cleared, isFalse);
      online = false;
      await expectLater(repo.send('chat', 'please retry'), throwsStateError);
      expect(sent, isEmpty);
      online = true;
      final id = await repo.send('chat', 'please retry');
      expect(sent.single['mid'], id);
      expect(sent.single['content'], 'please retry');
      await repo.flush();
      expect(sent, hasLength(1));
      final image = {'object_path': 'chat/owner-a/image.jpg', 'mime_type': 'image/jpeg', 'size_bytes': 100};
      final imageId = await repo.send('chat', '', kind: 'image', attachment: image);
      expect(sent.last['mid'], imageId);
      expect(sent.last['attachment'], image);
      expect(sent.last['message_kind'], 'image');
      final video = {'object_path': 'chat/owner-a/video.mp4', 'mime_type': 'video/mp4', 'size_bytes': 300};
      final videoId = await repo.send('chat', '', kind: 'video', attachment: video, viewOnce: true);
      expect(viewOnceSent.single['mid'], videoId);
      expect(viewOnceSent.single['attachment'], video);
      expect(viewOnceSent.single['media_kind'], 'video');
      online = false;
      await expectLater(repo.send('chat', '', kind: 'image', attachment: {'object_path': 'x'}),
        throwsStateError);
      expect(sent, hasLength(2));
      await expectLater(repo.send('chat', '', kind: 'file', attachment: {'object_path': 'x'}),
        throwsStateError);
      expect(failed.cleared, isFalse);
      await expectLater(repo.clearLocal(), throwsStateError);
      expect(failed.cleared, isFalse);
    } finally {
      await repo.dispose();
      await client.dispose();
    }
  });
}
