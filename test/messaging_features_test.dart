import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/core/security/local_cache.dart';
import 'package:calculator_messenger/core/security/lock_controller.dart';
import 'package:calculator_messenger/core/services/device_settings.dart';
import 'package:calculator_messenger/features/messaging/poll_widget.dart';
import 'package:calculator_messenger/features/messaging/structured_content.dart';
import 'package:calculator_messenger/features/messaging/sticker_gif_picker.dart';
import 'package:calculator_messenger/models/message.dart';
import 'package:calculator_messenger/providers/app_providers.dart';
import 'package:calculator_messenger/repositories/messenger_repository.dart';
import 'lock_biometric_test.dart' show ImmediatePinVault;

class FakeLocalCache implements LocalCache {
  FakeLocalCache([Map<String, dynamic>? initial])
      : data = initial ?? <String, dynamic>{};

  @override
  final Map<String, dynamic> data;

  int saveCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> save() async {
    saveCount++;
  }

  @override
  Future<void> forget() async {
    data.clear();
  }

  @override
  Future<void> clear() async {
    data.clear();
  }
}

String jwtPart(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

Future<void> authenticateClient(
  SupabaseClient client, {
  String userId = 'owner',
}) async {
  final header = jwtPart({'alg': 'HS256'});
  final payload = jwtPart({
    'sub': userId,
    'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  });
  final token = '$header.$payload.unit-test';
  await client.auth.recoverSession(
    jsonEncode({
      'access_token': token,
      'refresh_token': 'unit-test',
      'token_type': 'bearer',
      'user': {
        'id': userId,
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'aud': 'authenticated',
        'created_at': '2026-01-01T00:00:00Z',
      },
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessage Model - Starred & CopyWith', () {
    test('fromJson parses starred boolean correctly', () {
      final msgStarred = ChatMessage.fromJson({
        'id': 'msg-1',
        'conversation_id': 'c-1',
        'sender_id': 'user-1',
        'body': 'Starred text',
        'kind': 'text',
        'created_at': '2026-10-18T10:00:00Z',
        'starred': true,
      });
      expect(msgStarred.starred, isTrue);

      final msgUnstarred = ChatMessage.fromJson({
        'id': 'msg-2',
        'conversation_id': 'c-1',
        'sender_id': 'user-1',
        'body': 'Regular text',
        'kind': 'text',
        'created_at': '2026-10-18T10:00:00Z',
        'starred': false,
      });
      expect(msgUnstarred.starred, isFalse);

      final msgDefault = ChatMessage.fromJson({
        'id': 'msg-3',
        'conversation_id': 'c-1',
        'sender_id': 'user-1',
        'body': 'No starred property',
        'kind': 'text',
        'created_at': '2026-10-18T10:00:00Z',
      });
      expect(msgDefault.starred, isFalse);
    });

    test('copyWith updates starred while preserving other fields', () {
      final original = ChatMessage(
        id: 'msg-4',
        conversationId: 'c-1',
        senderId: 'owner',
        body: 'Keep me safe',
        kind: 'text',
        createdAt: DateTime.utc(2026, 10, 18, 12, 0),
        starred: false,
      );

      final updated = original.copyWith(starred: true);
      expect(updated.starred, isTrue);
      expect(updated.id, original.id);
      expect(updated.conversationId, original.conversationId);
      expect(updated.senderId, original.senderId);
      expect(updated.body, original.body);
      expect(updated.kind, original.kind);
      expect(updated.createdAt, original.createdAt);

      final bodyUpdated = updated.copyWith(body: 'Edited safe text');
      expect(bodyUpdated.starred, isTrue);
      expect(bodyUpdated.body, 'Edited safe text');
    });
  });

  group('DeviceSettings - Chat Folders', () {
    late LockController lock;
    late DeviceSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      lock = LockController(ImmediatePinVault());
      settings = DeviceSettings(await SharedPreferences.getInstance(), lock);
    });

    test('customFolders starts empty and can add unique non-empty folders', () async {
      expect(settings.customFolders, isEmpty);

      await settings.addCustomFolder('Work');
      expect(settings.customFolders, ['Work']);

      // Duplicate addition is ignored
      await settings.addCustomFolder('Work');
      expect(settings.customFolders, ['Work']);

      // Empty or whitespace folder is ignored
      await settings.addCustomFolder('   ');
      expect(settings.customFolders, ['Work']);

      await settings.addCustomFolder('Friends & Family');
      expect(settings.customFolders, ['Work', 'Friends & Family']);
    });

    test('removeCustomFolder removes existing folder', () async {
      await settings.addCustomFolder('Work');
      await settings.addCustomFolder('Projects');
      expect(settings.customFolders, ['Work', 'Projects']);

      await settings.removeCustomFolder('Work');
      expect(settings.customFolders, ['Projects']);

      // Removing non-existent folder is a safe no-op
      await settings.removeCustomFolder('NonExistent');
      expect(settings.customFolders, ['Projects']);
    });

    test('getFoldersForChat, setFoldersForChat, and toggleChatFolder manage chat assignments', () async {
      const cid = 'chat-alpha';
      expect(settings.getFoldersForChat(cid), isEmpty);

      await settings.setFoldersForChat(cid, ['Work', 'Important']);
      expect(settings.getFoldersForChat(cid), ['Work', 'Important']);

      // Toggle off 'Work'
      await settings.toggleChatFolder(cid, 'Work');
      expect(settings.getFoldersForChat(cid), ['Important']);

      // Toggle on 'Projects'
      await settings.toggleChatFolder(cid, 'Projects');
      expect(settings.getFoldersForChat(cid), ['Important', 'Projects']);
    });
  });

  group('Chat List Screen - Filtering & Sticky Pinned Sorting Logic', () {
    late LockController lock;
    late DeviceSettings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      lock = LockController(ImmediatePinVault());
      settings = DeviceSettings(await SharedPreferences.getInstance(), lock);
    });

    final sampleChats = [
      {
        'id': 'chat-1',
        'title': 'Alice',
        'kind': 'direct',
        'archived': false,
        'pinned': false,
        'unread': 2,
        'updated_at': '2026-10-18T10:00:00Z',
      },
      {
        'id': 'chat-2',
        'title': 'Work Team',
        'kind': 'group',
        'archived': false,
        'pinned': true,
        'unread': 0,
        'updated_at': '2026-10-18T08:00:00Z',
      },
      {
        'id': 'chat-3',
        'title': 'Bob',
        'kind': 'direct',
        'archived': false,
        'pinned': true,
        'unread': 1,
        'updated_at': '2026-10-18T09:00:00Z',
      },
      {
        'id': 'chat-4',
        'title': 'Old Archive',
        'kind': 'direct',
        'archived': true,
        'pinned': false,
        'unread': 0,
        'updated_at': '2026-10-18T11:00:00Z',
      },
      {
        'id': 'chat-5',
        'title': 'Project Alpha',
        'kind': 'group',
        'archived': false,
        'pinned': false,
        'unread': 0,
        'updated_at': '2026-10-18T12:00:00Z',
      },
    ];

    List<Map<String, dynamic>> filterAndSort(
      List<Map<String, dynamic>> list,
      String selectedFolder, {
      String query = '',
    }) {
      final isArchivedFolder = selectedFolder == 'Archived';
      final filtered = list.where((c) {
        if (!(c['title'] as String).toLowerCase().contains(query.toLowerCase())) {
          return false;
        }
        final isArchived = c['archived'] == true;
        if (isArchivedFolder) return isArchived;
        if (isArchived) return false;

        if (selectedFolder == 'All') return true;
        if (selectedFolder == 'Unread') {
          return (c['unread'] as num? ?? 0) > 0;
        }
        if (selectedFolder == 'Direct') return c['kind'] == 'direct';
        if (selectedFolder == 'Groups') return c['kind'] == 'group';

        final assigned = settings.getFoldersForChat(c['id'] as String);
        return assigned.contains(selectedFolder);
      }).toList();

      filtered.sort((a, b) {
        final aPinned = a['pinned'] == true;
        final bPinned = b['pinned'] == true;
        if (aPinned != bPinned) return aPinned ? -1 : 1;
        final aTime = DateTime.tryParse(a['updated_at'] ?? '') ?? DateTime(1970);
        final bTime = DateTime.tryParse(b['updated_at'] ?? '') ?? DateTime(1970);
        return bTime.compareTo(aTime);
      });
      return filtered;
    }

    test('Sticky pinned chats sort strictly to the top before unpinned chats', () {
      final sorted = filterAndSort(sampleChats, 'All');
      // Pinned chats: chat-3 (09:00), chat-2 (08:00)
      // Unpinned chats: chat-5 (12:00), chat-1 (10:00)
      // chat-4 is archived, so excluded from 'All'
      expect(sorted.map((c) => c['id']).toList(), [
        'chat-3',
        'chat-2',
        'chat-5',
        'chat-1',
      ]);
      expect(sorted[0]['pinned'], isTrue);
      expect(sorted[1]['pinned'], isTrue);
      expect(sorted[2]['pinned'], isFalse);
      expect(sorted[3]['pinned'], isFalse);
    });

    test('Unread folder filters only unread and sorts pinned unread first', () {
      final unread = filterAndSort(sampleChats, 'Unread');
      // chat-1 (unread 2, unpinned) and chat-3 (unread 1, pinned)
      expect(unread.map((c) => c['id']).toList(), ['chat-3', 'chat-1']);
    });

    test('Direct and Groups folders correctly partition conversations', () {
      final direct = filterAndSort(sampleChats, 'Direct');
      expect(direct.map((c) => c['id']).toList(), ['chat-3', 'chat-1']);

      final groups = filterAndSort(sampleChats, 'Groups');
      expect(groups.map((c) => c['id']).toList(), ['chat-2', 'chat-5']);
    });

    test('Archived folder contains only archived chats', () {
      final archived = filterAndSort(sampleChats, 'Archived');
      expect(archived.map((c) => c['id']).toList(), ['chat-4']);
    });

    test('Custom folder filters chats assigned to that custom folder', () async {
      await settings.addCustomFolder('Special');
      await settings.setFoldersForChat('chat-5', ['Special']);

      final specialChats = filterAndSort(sampleChats, 'Special');
      expect(specialChats.map((c) => c['id']).toList(), ['chat-5']);
    });
  });

  group('MessengerRepository - Starred Messages', () {
    test('starMessage and unstarMessage update cache and invoke database RPCs', () async {
      final rpcCalls = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.contains('/rpc/')) {
            final rpcName = request.url.pathSegments.last;
            rpcCalls.add({
              'rpc': rpcName,
              'body': jsonDecode(request.body),
            });
            return http.Response(
              'null',
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache();
      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        expect(repo.isMessageStarred('msg-100'), isFalse);

        await repo.starMessage('msg-100', 'chat-xyz');
        expect(repo.isMessageStarred('msg-100'), isTrue);
        expect((cache.data['starred_messages'] as List).contains('msg-100'), isTrue);
        expect(rpcCalls.any((call) => call['rpc'] == 'star_message' && call['body']['mid'] == 'msg-100'), isTrue);

        await repo.unstarMessage('msg-100');
        expect(repo.isMessageStarred('msg-100'), isFalse);
        expect((cache.data['starred_messages'] as List).contains('msg-100'), isFalse);
        expect(rpcCalls.any((call) => call['rpc'] == 'unstar_message' && call['body']['mid'] == 'msg-100'), isTrue);
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });

    test('getStarredMessages returns remote rows or falls back to local cache on error', () async {
      bool failRemote = false;
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (failRemote) {
            throw http.ClientException('network offline');
          }
          if (request.url.path.contains('starred_messages')) {
            return http.Response(
              jsonEncode([
                {
                  'message_id': 'star-remote-1',
                  'conversation_id': 'chat-1',
                  'created_at': '2026-10-18T10:00:00Z',
                  'messages': {
                    'id': 'star-remote-1',
                    'body': 'Remote starred message',
                    'kind': 'text',
                  },
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache({
        'starred_messages': ['star-local-1'],
        'messages.chat-1': [
          {
            'id': 'star-local-1',
            'conversation_id': 'chat-1',
            'sender_id': 'owner',
            'body': 'Local fallback message',
            'kind': 'text',
            'created_at': '2026-10-18T09:00:00Z',
          },
        ],
      });

      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        // 1. Online remote fetch
        final remoteRows = await repo.getStarredMessages();
        expect(remoteRows, hasLength(1));
        expect(remoteRows.first['message_id'], 'star-remote-1');

        // 2. Offline fallback to cached messages
        failRemote = true;
        final localFallback = await repo.getStarredMessages();
        expect(localFallback, hasLength(1));
        expect(localFallback.first['id'], 'star-local-1');
        expect(localFallback.first['body'], 'Local fallback message');
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });
  });

  group('MessengerRepository - Scheduled Messages', () {
    test('scheduleMessage and cancelScheduledMessage manage local queue and database table', () async {
      final dbOperations = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          dbOperations.add({
            'method': request.method,
            'url': request.url.toString(),
            'body': request.body.isNotEmpty ? jsonDecode(request.body) : null,
          });
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache();
      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        final sendTime = DateTime.now().add(const Duration(hours: 3));
        final scheduledId = await repo.scheduleMessage(
          'chat-sched',
          'Automated reminder',
          sendTime,
        );
        expect(scheduledId, isNotEmpty);

        final localList = (cache.data['scheduled_messages'] as List).cast<Map<String, dynamic>>();
        expect(localList.any((m) => m['id'] == scheduledId), isTrue);
        expect(dbOperations.any((op) => op['method'] == 'POST' && op['url'].contains('scheduled_messages')), isTrue);

        await repo.cancelScheduledMessage(scheduledId);
        final updatedList = (cache.data['scheduled_messages'] as List).cast<Map<String, dynamic>>();
        expect(updatedList.any((m) => m['id'] == scheduledId), isFalse);
        expect(dbOperations.any((op) => op['method'] == 'DELETE' && op['url'].contains('scheduled_messages')), isTrue);
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });

    test('dispatchDueScheduledMessages delivers overdue messages and preserves future messages', () async {
      final sentMessages = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.contains('/rpc/send_message')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sentMessages.add(body);
            return http.Response(
              jsonEncode(body['mid']),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final dueTime = DateTime.now().subtract(const Duration(minutes: 5));
      final futureTime = DateTime.now().add(const Duration(hours: 2));

      final cache = FakeLocalCache({
        'scheduled_messages': [
          {
            'id': 'due-msg-1',
            'conversation_id': 'chat-1',
            'sender_id': 'owner',
            'body': 'Due for sending',
            'kind': 'text',
            'scheduled_for': dueTime.toUtc().toIso8601String(),
          },
          {
            'id': 'future-msg-2',
            'conversation_id': 'chat-1',
            'sender_id': 'owner',
            'body': 'Send later',
            'kind': 'text',
            'scheduled_for': futureTime.toUtc().toIso8601String(),
          },
        ],
      });

      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        await repo.dispatchDueScheduledMessages();

        final remaining = (cache.data['scheduled_messages'] as List).cast<Map<String, dynamic>>();
        expect(remaining.map((m) => m['id']).toList(), ['future-msg-2']);

        // Verify due message was enqueued into outbox for delivery
        final outbox = (cache.data['outbox'] as List? ?? []).cast<Map<String, dynamic>>();
        expect(outbox.any((m) => m['body'] == 'Due for sending'), isTrue);
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });
  });

  group('MessengerRepository - Polls, Stickers & GIFs', () {
    test('sendPoll validates minimum options and sends structured poll payload', () async {
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache();
      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        // Must have at least 2 non-empty options
        expect(
          () => repo.sendPoll('chat-poll', 'Favorite fruit?', ['Apple']),
          throwsArgumentError,
        );
        expect(
          () => repo.sendPoll('chat-poll', 'Favorite fruit?', ['  ', ' ']),
          throwsArgumentError,
        );

        final pollId = await repo.sendPoll(
          'chat-poll',
          'Meeting time?',
          ['10 AM', '2 PM', '4 PM'],
          multiple: true,
        );
        expect(pollId, isNotEmpty);

        final outbox = (cache.data['outbox'] as List).cast<Map<String, dynamic>>();
        final queued = outbox.firstWhere((m) => m['id'] == pollId);
        expect(queued['kind'], 'poll');

        final payload = jsonDecode(queued['body'] as String) as Map<String, dynamic>;
        expect(payload['question'], 'Meeting time?');
        expect(payload['options'], ['10 AM', '2 PM', '4 PM']);
        expect(payload['multiple'], isTrue);
        expect(payload['votes'], isEmpty);
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });

    test('votePoll invokes database RPC vote_poll', () async {
      final rpcInvocations = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.contains('/rpc/vote_poll')) {
            rpcInvocations.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('null', 200, headers: {'content-type': 'application/json'});
          }
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache();
      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        await repo.votePoll('msg-poll-1', 2);
        expect(rpcInvocations, hasLength(1));
        expect(rpcInvocations.first['mid'], 'msg-poll-1');
        expect(rpcInvocations.first['option_index'], 2);
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });

    test('sendSticker and sendGif send structured payloads with appropriate kinds', () async {
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache();
      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );

      try {
        await repo.prepare();

        final stickerId = await repo.sendSticker('chat-1', {
          'pack': 'reactions',
          'name': 'thumbs_up',
          'emoji': '👍',
          'title': 'Thumbs Up',
        });
        expect(stickerId, isNotEmpty);

        final gifId = await repo.sendGif('chat-1', {
          'url': 'https://example.com/celebrate.gif',
          'title': 'Celebration',
        });
        expect(gifId, isNotEmpty);

        final outbox = (cache.data['outbox'] as List).cast<Map<String, dynamic>>();
        final stickerItem = outbox.firstWhere((m) => m['id'] == stickerId);
        expect(stickerItem['kind'], 'sticker');
        expect(jsonDecode(stickerItem['body'])['emoji'], '👍');

        final gifItem = outbox.firstWhere((m) => m['id'] == gifId);
        expect(gifItem['kind'], 'gif');
        expect(jsonDecode(gifItem['body'])['url'], 'https://example.com/celebrate.gif');
      } finally {
        await repo.dispose();
        await client.dispose();
      }
    });
  });

  group('Widgets - PollWidget & StructuredContent', () {
    testWidgets('PollWidget renders question, options, vote tally, and allows voting', (tester) async {
      final votesReceived = <Map<String, dynamic>>[];
      final client = SupabaseClient(
        'https://example.invalid',
        'unit-test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.contains('/rpc/vote_poll')) {
            votesReceived.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('null', 200, headers: {'content-type': 'application/json'});
          }
          return http.Response('[]', 200, headers: {'content-type': 'application/json'});
        }),
      );
      await authenticateClient(client);

      final cache = FakeLocalCache();
      final repo = MessengerRepository(
        client,
        cacheFactory: (_) => cache,
        connectivity: const Stream.empty(),
      );
      await repo.prepare();

      final pollPayload = {
        'question': 'Team lunch spot?',
        'options': ['Pizza', 'Tacos', 'Sushi'],
        'multiple': false,
        'votes': {
          'user-1': [0],
          'user-2': [0],
          'owner': [1],
        },
      };

      final pollMessage = ChatMessage(
        id: 'msg-poll-live',
        conversationId: 'chat-lunch',
        senderId: 'owner',
        body: jsonEncode(pollPayload),
        kind: 'poll',
        createdAt: DateTime.now(),
      );

      debugPrint('[poll-widget-test] creating widget');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messengerProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PollWidget(message: pollMessage),
            ),
          ),
        ),
      );
      debugPrint('[poll-widget-test] widget pumped');
      await tester.pumpAndSettle(const Duration(milliseconds: 50), timeout: const Duration(seconds: 5));
      debugPrint('[poll-widget-test] first settlement complete');

      expect(find.text('Team lunch spot?'), findsOneWidget);
      expect(find.text('Pizza'), findsOneWidget);
      expect(find.text('Tacos'), findsOneWidget);
      expect(find.text('Sushi'), findsOneWidget);
      expect(find.text('3 votes · Single choice'), findsOneWidget);

      // Tap 'Pizza' (index 0) to change vote
      debugPrint('[poll-widget-test] tapping vote');
      await tester.tap(find.text('Pizza'));
      debugPrint('[poll-widget-test] vote tapped');
      await tester.pumpAndSettle(const Duration(milliseconds: 50), timeout: const Duration(seconds: 5));
      debugPrint('[poll-widget-test] vote pump settled');

      expect(votesReceived, hasLength(1));
      expect(votesReceived.first['mid'], 'msg-poll-live');
      expect(votesReceived.first['option_index'], 0);

      // Dispose the widget tree before closing the repository it reads.
      debugPrint('[poll-widget-test] unmounting widget');
      await tester.pumpWidget(const SizedBox.shrink());
      debugPrint('[poll-widget-test] unmounted, disposing repo');
      await repo.dispose().timeout(const Duration(seconds: 10));
      debugPrint('[poll-widget-test] repo disposed, disposing Supabase');
      await client.dispose().timeout(const Duration(seconds: 10));
      debugPrint('[poll-widget-test] disposal complete');
    }, timeout: const Timeout(Duration(minutes: 1)));

    testWidgets('StructuredContent renders sticker and gif content properly', (tester) async {
      final stickerMessage = ChatMessage(
        id: 'msg-sticker-1',
        conversationId: 'chat-1',
        senderId: 'owner',
        body: jsonEncode({
          'pack': 'reactions',
          'emoji': '🚀',
          'title': 'Rocket Launch',
        }),
        kind: 'sticker',
        createdAt: DateTime.now(),
      );

      final gifMessage = ChatMessage(
        id: 'msg-gif-1',
        conversationId: 'chat-1',
        senderId: 'owner',
        body: jsonEncode({
          'url': 'https://example.com/celebration.gif',
          'title': 'Party Time',
        }),
        kind: 'gif',
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                StructuredContent(message: stickerMessage),
                StructuredContent(message: gifMessage),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Verify sticker rendered
      expect(find.text('🚀'), findsOneWidget);
      expect(find.text('Rocket Launch'), findsOneWidget);

      // Verify GIF title rendered
      expect(find.text('Party Time'), findsOneWidget);
    });

    test('StickerPacks has curated categories and emojis', () {
      expect(StickerPacks.packs.keys, containsAll([
        'Expressions',
        'Celebrations',
        'Reactions',
        'Animals',
      ]));
      for (final pack in StickerPacks.packs.values) {
        expect(pack, isNotEmpty);
        expect(pack.every((s) => s.containsKey('emoji') && s.containsKey('name')), isTrue);
      }
    });
  });
}
