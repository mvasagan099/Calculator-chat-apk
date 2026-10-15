import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/security/encrypted_cache.dart';
import '../core/security/pin_vault.dart';
import '../models/message.dart';

class MessengerRepository {
  MessengerRepository(this.client);
  final SupabaseClient client;
  String get uid => client.auth.currentUser!.id;
  EncryptedCache? _cache;
  String? _cacheOwner;
  bool _flushing = false;
  Completer<void>? _flushDone;
  Future<void>? _preparing;
  Timer? _retryTimer;
  final _hiddenIds = <String>{};
  bool isHidden(String id) => _hiddenIds.contains(id);
  StreamSubscription<List<ConnectivityResult>>? _connection;
  final _changes = StreamController<void>.broadcast();
  Future<void> prepare() async {
    if (_preparing != null) await _preparing;
    if (_cacheOwner == uid && _cache != null) return;
    _preparing = _initialize();
    try {
      await _preparing;
    } finally {
      _preparing = null;
    }
  }

  Future<void> _initialize() async {
    final owner = uid;
    final cache = EncryptedCache(owner, const DeviceSecretStore());
    await cache.initialize();
    await _connection?.cancel();
    _cacheOwner = owner;
    _cache = cache;
    _connection = Connectivity().onConnectivityChanged.listen((_) {
      unawaited(flush());
    });
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 15), (_) => flush());
    unawaited(flush());
  }

  List<Map<String, dynamic>> get _outbox =>
      (_cache?.data['outbox'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  Future<void> _saveOutbox(List<Map<String, dynamic>> values) async {
    _cache!.data['outbox'] = values;
    await _cache!.save();
    _changes.add(null);
  }

  Stream<List<Map<String, dynamic>>> conversations() async* {
    await prepare();
    if (_cache!.data['conversations'] != null) {
      yield (_cache!.data['conversations'] as List)
          .cast<Map<String, dynamic>>();
    }
    yield* watch(
      ['conversations', 'messages', 'conversation_members'],
      () async {
        final rows = (await client.rpc('conversation_list') as List)
            .cast<Map<String, dynamic>>();
        _cache!.data['conversations'] = rows;
        await _cache!.save();
        return rows;
      },
    );
  }

  Stream<T> watch<T>(
    List<String> tables,
    Future<T> Function() fetch, {
    String? cid,
  }) {
    late StreamController<T> controller;
    RealtimeChannel? channel;
    Timer? refresh;
    var fetching = false, again = false, closed = false;
    Future<void> load() async {
      if (closed) return;
      if (fetching) {
        again = true;
        return;
      }
      fetching = true;
      try {
        final value = await fetch();
        if (!closed) controller.add(value);
      } catch (e, st) {
        if (!closed) controller.addError(e, st);
      } finally {
        fetching = false;
        if (again) {
          again = false;
          unawaited(load());
        }
      }
    }

    controller = StreamController<T>(
      onListen: () {
        channel = client.channel('watch-${const Uuid().v4()}');
        for (final table in tables) {
          channel!.onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            filter: cid == null
                ? null
                : PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'conversation_id',
                    value: cid,
                  ),
            callback: (_) => load(),
          );
        }
        channel!.subscribe((state, error) {
          if (state == RealtimeSubscribeStatus.subscribed) unawaited(load());
        });
        refresh = Timer.periodic(const Duration(seconds: 15), (_) => load());
        unawaited(load());
      },
      onCancel: () async {
        closed = true;
        refresh?.cancel();
        if (channel != null) await client.removeChannel(channel!);
      },
    );
    return controller.stream;
  }

  static const messageSelect =
      '*,profiles!messages_sender_id_fkey(display_name),message_attachments(*),message_reactions(*),message_receipts(*)';
  Future<List<Map<String, dynamic>>> page(
    String cid, {
    Map<String, dynamic>? before,
    int limit = 50,
  }) async {
    var q = client
        .from('messages')
        .select(messageSelect)
        .eq('conversation_id', cid);
    if (before != null) {
      q = q.or(
        'created_at.lt.${before['created_at']},and(created_at.eq.${before['created_at']},id.lt.${before['id']})',
      );
    }
    return await q
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit);
  }

  Stream<List<ChatMessage>> messages(String cid) async* {
    await prepare();
    List<Map<String, dynamic>> rows =
        (_cache!.data['messages.$cid'] as List? ?? [])
            .cast<Map<String, dynamic>>();
    List<ChatMessage> merged() {
      final byId = {for (final r in rows) r['id']: r};
      for (final p in _outbox.where((e) => e['conversation_id'] == cid)) {
        byId.putIfAbsent(p['id'], () => p);
      }
      final list =
          byId.values
              .where((m) => !_hiddenIds.contains(m['id']))
              .map(ChatMessage.fromJson)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    }

    yield merged();
    late StreamController<List<ChatMessage>> output;
    StreamSubscription<void>? pending;
    StreamSubscription<List<Map<String, dynamic>>>? server;
    output = StreamController(
      onListen: () {
        pending = _changes.stream.listen((_) {
          if (!output.isClosed) output.add(merged());
        });
        server =
            watch(
              ['messages', 'message_receipts', 'message_reactions'],
              () async {
                final results = await page(cid);
                final hidden = await client
                    .from('message_hides')
                    .select('message_id')
                    .eq('user_id', uid);
                final ids = hidden.map((e) => e['message_id']).toSet();
                _hiddenIds.addAll(ids.cast<String>());
                rows = results.where((e) => !ids.contains(e['id'])).toList();
                final receivedIds = results.map((e) => e['id']).toSet();
                _cache!.data['outbox'] = _outbox
                    .where((m) => !receivedIds.contains(m['id']))
                    .toList();
                _cache!.data['messages.$cid'] = rows;
                final keys = _cache!.data.keys
                    .where((k) => k.startsWith('messages.'))
                    .toList();
                while (keys.length > 20) {
                  _cache!.data.remove(keys.removeAt(0));
                }
                await _cache!.save();
                return rows;
              },
            ).listen(
              (_) {
                if (!output.isClosed) output.add(merged());
              },
              onError: (Object e, StackTrace st) {
                if (!output.isClosed) output.addError(e, st);
              },
            );
      },
      onCancel: () async {
        await pending?.cancel();
        await server?.cancel();
      },
    );
    yield* output.stream;
  }

  Future<String> send(
    String cid,
    String body, {
    String kind = 'text',
    String? replyTo,
    bool forwarded = false,
    Map<String, dynamic>? attachment,
  }) async {
    await prepare();
    final id = const Uuid().v4();
    final item = <String, dynamic>{
      'id': id,
      'conversation_id': cid,
      'sender_id': uid,
      'body': body,
      'kind': kind,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'reply_to': replyTo,
      'forwarded': forwarded,
      'pending': true,
      'failed': false,
      'attachment': attachment,
    };
    await _saveOutbox([..._outbox, item]);
    unawaited(flush());
    return id;
  }

  Future<void> flush({bool includeTerminal = false}) async {
    if (_flushing ||
        _cache == null ||
        client.auth.currentUser?.id != _cacheOwner) {
      return;
    }
    _flushing = true;
    final completion = Completer<void>();
    _flushDone = completion;
    try {
      for (final item in _outbox) {
        if (item['committed'] == true ||
            (item['terminal'] == true && !includeTerminal)) {
          continue;
        }
        try {
          await client.rpc(
            'send_message',
            params: {
              'cid': item['conversation_id'],
              'mid': item['id'],
              'content': item['body'],
              'message_kind': item['kind'],
              'reply': item['reply_to'],
              'is_forwarded': item['forwarded'],
              'attachment': item['attachment'],
            },
          );
          await _saveOutbox(
            _outbox
                .map(
                  (e) => e['id'] == item['id']
                      ? {
                          ...e,
                          'committed': true,
                          'pending': false,
                          'failed': false,
                        }
                      : e,
                )
                .toList(),
          );
        } catch (error) {
          await _saveOutbox(
            _outbox
                .map(
                  (e) => e['id'] == item['id']
                      ? {
                          ...e,
                          'failed': true,
                          'terminal': error is PostgrestException,
                        }
                      : e,
                )
                .toList(),
          );
          if (error is! PostgrestException) break;
        }
      }
    } finally {
      _flushing = false;
      completion.complete();
    }
  }

  Future<void> discardPending(String id) async {
    await _saveOutbox(_outbox.where((m) => m['id'] != id).toList());
  }

  Future<void> hide(String id) async {
    await client
        .from('message_hides')
        .upsert(
          {'message_id': id, 'user_id': uid},
          onConflict: 'message_id,user_id',
          ignoreDuplicates: true,
        );
    _hiddenIds.add(id);
    for (final key
        in _cache?.data.keys.where((k) => k.startsWith('messages.')).toList() ??
            <String>[]) {
      _cache!.data[key] = (_cache!.data[key] as List)
          .where((m) => m['id'] != id)
          .toList();
    }
    await _cache?.save();
    _changes.add(null);
  }

  Future<void> clearLocal() async {
    _retryTimer?.cancel();
    await _connection?.cancel();
    await _preparing;
    await _flushDone?.future;
    await _cache?.clear();
    _cache = null;
    _cacheOwner = null;
    _hiddenIds.clear();
  }

  Future<void> dispose() async {
    _retryTimer?.cancel();
    await _connection?.cancel();
    await _changes.close();
  }
}
