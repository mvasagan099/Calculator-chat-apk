import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/security/encrypted_cache.dart';
import '../core/security/pin_vault.dart';
import '../models/message.dart';
import '../core/security/local_retention.dart';

class MessengerRepository {
  MessengerRepository(
    this.client, {
    EncryptedCache Function(String owner)? cacheFactory,
    this.connectivity,
  }) : _cacheFactory =
           cacheFactory ??
           ((owner) => EncryptedCache(owner, const DeviceSecretStore()));
  final EncryptedCache Function(String owner) _cacheFactory;
  final Stream<List<ConnectivityResult>>? connectivity;
  final SupabaseClient client;
  String get uid => client.auth.currentUser!.id;
  EncryptedCache? _cache;
  String? _cacheOwner;
  bool _flushing = false, _disposed = false;
  Completer<void>? _flushDone;
  Future<void>? _preparing, _suspending;
  int _sessionEpoch = 0;
  Timer? _retryTimer;
  final _hiddenIds = <String>{};
  bool isHidden(String id) => _hiddenIds.contains(id);
  StreamSubscription<List<ConnectivityResult>>? _connection;
  final _changes = StreamController<void>.broadcast();
  final _channels = <RealtimeChannel>{};
  final _timers = <Timer>{};
  Future<void> prepare() async {
    if (_disposed) throw StateError('Messaging session closed');
    await _suspending;
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
    final epoch = _sessionEpoch;
    final cache = _cacheFactory(owner);
    await cache.initialize();
    await _connection?.cancel();
    await _flushDone?.future;
    if (_disposed ||
        epoch != _sessionEpoch ||
        client.auth.currentUser?.id != owner) {
      throw StateError('Messaging session changed');
    }
    _hiddenIds.clear();
    _cacheOwner = owner;
    _cache = cache;
    _connection = (connectivity ?? Connectivity().onConnectivityChanged).listen(
      (_) {
        unawaited(flush().catchError((Object _) {}));
      },
    );
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(flush().catchError((Object _) {}));
    });
    unawaited(flush().catchError((Object _) {}));
  }

  List<Map<String, dynamic>> get _outbox =>
      (_cache?.data['outbox'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  Future<void> _saveOutbox(List<Map<String, dynamic>> values) async {
    _cache!.data['outbox'] = values;
    await _cache!.save();
    if (!_changes.isClosed) _changes.add(null);
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
    Timer? refresh, debounce;
    final owner = client.auth.currentUser?.id;
    final epoch = _sessionEpoch;
    var fetching = false, again = false, closed = false;
    Future<void> load() async {
      if (closed ||
          epoch != _sessionEpoch ||
          _disposed ||
          owner == null ||
          client.auth.currentUser?.id != owner) {
        return;
      }
      if (fetching) {
        again = true;
        return;
      }
      fetching = true;
      try {
        final value = await fetch();
        if (!closed &&
            epoch == _sessionEpoch &&
            !_disposed &&
            client.auth.currentUser?.id == owner) {
          controller.add(value);
        }
      } catch (e, st) {
        if (!closed && epoch == _sessionEpoch && !_disposed) {
          controller.addError(e, st);
        }
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
        _channels.add(channel!);
        for (final table in tables) {
          channel!.onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            filter: cid == null || table != 'messages'
                ? null
                : PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'conversation_id',
                    value: cid,
                  ),
            callback: (_) {
              if (closed ||
                  epoch != _sessionEpoch ||
                  _disposed ||
                  client.auth.currentUser?.id != owner) {
                return;
              }
              if (debounce != null) _timers.remove(debounce);
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 250), () {
                _timers.remove(debounce);
                unawaited(load());
              });
              _timers.add(debounce!);
            },
          );
        }
        channel!.subscribe((state, error) {
          if (state == RealtimeSubscribeStatus.subscribed) unawaited(load());
        });
        refresh = Timer.periodic(const Duration(seconds: 15), (_) => load());
        _timers.add(refresh!);
        unawaited(load());
      },
      onCancel: () async {
        closed = true;
        refresh?.cancel();
        debounce?.cancel();
        _timers.remove(refresh);
        _timers.remove(debounce);
        if (channel != null && _channels.remove(channel)) {
          await client.removeChannel(channel!);
        }
      },
    );
    return controller.stream;
  }

  Future<String> wallpaper(String cid) async {
    await prepare();
    return _cache!.data['wallpaper.$cid'] as String? ?? 'plain';
  }

  Future<void> setWallpaper(String cid, String value) async {
    if (!['plain', 'linen', 'dusk'].contains(value)) {
      throw ArgumentError.value(value);
    }
    await prepare();
    _cache!.data['wallpaper.$cid'] = value;
    await _cache!.save();
  }

  Future<void> purgeExpiredLocal() async {
    if (_cache == null) return;
    pruneLocalData(_cache!.data, DateTime.now());
    await _cache!.save();
    if (!_changes.isClosed) _changes.add(null);
  }

  void rememberExpiration(String cid, int seconds) {
    _cache?.data['expiration.$cid'] = seconds;
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

  /// Refresh loaded history by indexed IDs, in bounded requests. This keeps
  /// edits, deletions and receipts current beyond the newest keyset page.
  Future<List<Map<String, dynamic>>> loadWindow(
    String cid,
    Iterable<String> historyIds,
  ) async {
    final latest = await page(cid);
    final byId = {for (final row in latest) row['id'] as String: row};
    final missing = historyIds.toSet().difference(byId.keys.toSet()).toList();
    for (var offset = 0; offset < missing.length; offset += 50) {
      final batch = missing.skip(offset).take(50).toList();
      final rows = await client
          .from('messages')
          .select(messageSelect)
          .eq('conversation_id', cid)
          .inFilter('id', batch);
      for (final row in rows) {
        byId[row['id'] as String] = row;
      }
    }
    return byId.values.toList()..sort((a, b) {
      final time = DateTime.parse(
        b['created_at'],
      ).compareTo(DateTime.parse(a['created_at']));
      return time == 0
          ? (b['id'] as String).compareTo(a['id'] as String)
          : time;
    });
  }

  Stream<List<ChatMessage>> messages(
    String cid, {
    Iterable<String> Function()? historyIds,
  }) async* {
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
              .where(
                (m) =>
                    !_hiddenIds.contains(m['id']) &&
                    !recordExpired(m, DateTime.now()),
              )
              .map(ChatMessage.fromJson)
              .toList()
            ..sort(ChatMessage.newestFirst);
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
                final results = await loadWindow(cid, {
                  ...rows.take(200).map((row) => row['id'] as String),
                  ...?historyIds?.call(),
                });
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
                _cache!.data['messages.$cid'] = rows.take(200).toList();
                final keys = _cache!.data.keys
                    .where((k) => k.startsWith('messages.'))
                    .toList();
                while (keys.length > 20) {
                  _cache!.data.remove(keys.removeAt(0));
                }
                await _cache!.save();
                return rows;
              },
              cid: cid,
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
    bool viewOnce = false,
    Map<String, dynamic>? attachment,
  }) async {
    await prepare();
    if (viewOnce &&
        (forwarded ||
            !['image', 'video'].contains(kind) ||
            attachment == null)) {
      throw ArgumentError('View-once requires an original photo or video');
    }
    final duration = _cache!.data['expiration.$cid'] as int? ?? 0;
    final seconds = viewOnce
        ? (duration == 0 ? 86400 : duration.clamp(60, 86400))
        : duration;
    final created = DateTime.now().toUtc();
    final id = const Uuid().v4();
    final item = <String, dynamic>{
      'id': id,
      'conversation_id': cid,
      'sender_id': uid,
      'body': body,
      'kind': kind,
      'created_at': created.toIso8601String(),
      'expires_at': seconds > 0
          ? created.add(Duration(seconds: seconds)).toIso8601String()
          : null,
      'expiration_seconds': seconds,
      'view_once': viewOnce,
      'reply_to': replyTo,
      'forwarded': forwarded,
      'pending': true,
      'failed': false,
      'attachment': attachment,
    };
    await _saveOutbox([..._outbox, item]);
    unawaited(flush().catchError((Object _) {}));
    return id;
  }

  Future<void> flush({bool includeTerminal = false}) async {
    if (_flushing) {
      await _flushDone?.future;
      return;
    }
    if (_disposed ||
        _cache == null ||
        client.auth.currentUser?.id != _cacheOwner) {
      return;
    }
    _flushing = true;
    final completion = Completer<void>();
    _flushDone = completion;
    try {
      await purgeExpiredLocal();
      final attempted = <String>{};
      while (true) {
        if (_disposed || client.auth.currentUser?.id != _cacheOwner) break;
        final item = _outbox
            .where(
              (entry) =>
                  !attempted.contains(entry['id']) &&
                  entry['committed'] != true &&
                  (entry['terminal'] != true || includeTerminal),
            )
            .firstOrNull;
        if (item == null) break;
        attempted.add(item['id'] as String);
        try {
          await client
              .rpc(
                item['view_once'] == true
                    ? 'send_view_once_message'
                    : 'send_message',
                params: item['view_once'] == true
                    ? {
                        'cid': item['conversation_id'],
                        'mid': item['id'],
                        'attachment': item['attachment'],
                        'media_kind': item['kind'],
                      }
                    : {
                        'cid': item['conversation_id'],
                        'mid': item['id'],
                        'content': item['body'],
                        'message_kind': item['kind'],
                        'reply': item['reply_to'],
                        'is_forwarded': item['forwarded'],
                        'attachment': item['attachment'],
                      },
              )
              .timeout(const Duration(seconds: 15));
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
                          'terminal': !isRetryableMessageError(error),
                        }
                      : e,
                )
                .toList(),
          );
          if (isRetryableMessageError(error)) break;
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
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> suspend() {
    return _suspending ??= _suspend().whenComplete(() => _suspending = null);
  }

  Future<void> _suspend() async {
    ++_sessionEpoch;
    _retryTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final channels = _channels.toList();
    _channels.clear();
    await Future.wait(channels.map(client.removeChannel));
    await _connection?.cancel();
    await _preparing?.catchError((Object _) {});
    await _flushDone?.future;
    await _cache?.forget();
    _cache = null;
    _hiddenIds.clear();
  }

  Future<void> clearLocal() async {
    await _suspending;
    _retryTimer?.cancel();
    await _connection?.cancel();
    await _preparing;
    await _flushDone?.future;
    if (_cache != null) {
      await _cache!.clear();
    } else if (_cacheOwner != null) {
      await _cacheFactory(_cacheOwner!).clear();
    }
    _cache = null;
    _cacheOwner = null;
    _hiddenIds.clear();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _suspending;
    _retryTimer?.cancel();
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final channels = _channels.toList();
    _channels.clear();
    await Future.wait(channels.map(client.removeChannel));
    await _connection?.cancel();
    await _preparing?.catchError((Object _) {});
    await _flushDone?.future;
    await _cache?.forget();
    _cache = null;
    await _changes.close();
  }
}

/// Validation/permission failures require intervention; outages remain queued.
bool isRetryableMessageError(Object error) {
  if (error is! PostgrestException) return true;
  final code = error.code ?? '';
  return ['429', '502', '503', '504', '40001', '40P01'].contains(code) ||
      ['08', '53', '57', 'PGRST00'].any(code.startsWith);
}
