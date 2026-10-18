import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../core/security/local_cache.dart';
import '../core/security/sqlite_cache.dart';
import '../core/security/pin_vault.dart';
import '../models/message.dart';
import '../models/message_edit.dart';
import '../core/security/local_retention.dart';
import '../core/security/backup_service.dart';

typedef _CacheScope = ({LocalCache cache, String owner, int epoch});

/// Online-only, RAM-only fallback when encrypted local files cannot be opened.
/// No data from a failed encrypted cache is read, deleted, copied or replaced.
class _OnlineOnlyCache implements LocalCache {
  @override
  final Map<String, dynamic> data = {};
  @override
  Future<void> initialize() async {}
  @override
  Future<void> save() async {}
  @override
  Future<void> forget() async => data.clear();
  @override
  Future<void> clear() async => data.clear();
}


class MessengerRepository {
  MessengerRepository(
    this.client, {
    LocalCache Function(String owner)? cacheFactory,
    this.connectivity,
  }) : _cacheFactory =
           cacheFactory ??
           ((owner) => SqliteEncryptedCache(owner, const DeviceSecretStore()));
  final LocalCache Function(String owner) _cacheFactory;
  final Stream<List<ConnectivityResult>>? connectivity;
  final SupabaseClient client;
  String get uid => client.auth.currentUser!.id;
  LocalCache? _cache;
  String? _cacheOwner;
  bool _flushing = false, _disposed = false;
  bool _onlineOnly = false;
  /// Local encrypted drafts have NOT been recovered. No optimistic offline sends.
  bool get onlineOnly => _onlineOnly;
  /// A fixed allowlisted failure stage, never message bodies or file paths.
  String? get cacheRecoveryStage => _cacheRecoveryStage;
  String? _cacheRecoveryStage;
  final _onlineAttemptIds = <String, String>{};
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
  _CacheScope _captureCache() {
    final cache = _cache;
    final owner = client.auth.currentUser?.id;
    if (cache == null || owner == null || owner != _cacheOwner || _disposed) {
      throw StateError('Messaging session changed');
    }
    return (cache: cache, owner: owner, epoch: _sessionEpoch);
  }

  bool _currentCache(_CacheScope scope) =>
      !_disposed &&
      scope.epoch == _sessionEpoch &&
      identical(scope.cache, _cache) &&
      scope.owner == _cacheOwner &&
      client.auth.currentUser?.id == scope.owner;
  void _requireCache(_CacheScope scope) {
    if (!_currentCache(scope)) throw StateError('Messaging session changed');
  }

  Future<void> prepare() async {
    while (true) {
      if (_disposed) throw StateError('Messaging session closed');
      final suspending = _suspending;
      if (suspending != null) {
        await suspending;
        continue;
      }
      final preparing = _preparing;
      if (preparing != null) {
        await preparing;
        continue;
      }
      final owner = client.auth.currentUser?.id;
      if (owner == null) throw StateError('Sign in before loading messages');
      if (_cacheOwner == owner && _cache != null) return;
      final opening = _initialize();
      _preparing = opening;
      try {
        await opening;
      } finally {
        if (identical(_preparing, opening)) _preparing = null;
      }
    }
  }

  Future<void> _initialize() async {
    final owner = uid;
    final epoch = _sessionEpoch;
    LocalCache cache = _cacheFactory(owner);
    bool onlineFallback = false;
    String? recoveryStage;
    try {
      await cache.initialize();
    } catch (error) {
      // Extract only a fixed stage code; never display exception details.
      const safeStages = {
        'key-read', 'key-derive', 'sqlite-open', 'sqlite-meta',
        'legacy-decrypt', 'initial-save', 'initial-verify',
        'sqlite-decrypt', 'cache-refresh',
      };
      final candidate = RegExp(r'Encrypted local cache is unavailable \(([a-z-]+)\)')
          .firstMatch(error.toString())?.group(1);
      recoveryStage = safeStages.contains(candidate) ? candidate : 'unknown';
      // Cache initialize fails closed and preserves its files. Never recreate
      // its Keystore key, purge ciphertext or migrate an unreadable outbox.
      try { await cache.forget(); } catch (_) {}
      cache = _OnlineOnlyCache();
      onlineFallback = true;
      await cache.initialize();
    }
    await _connection?.cancel();
    await _flushDone?.future;
    if (_disposed ||
        epoch != _sessionEpoch ||
        client.auth.currentUser?.id != owner) {
      await cache.forget();
      throw StateError('Messaging session changed');
    }
    final previous = _cache;
    _cache = null;
    await previous?.forget();
    if (_disposed ||
        epoch != _sessionEpoch ||
        client.auth.currentUser?.id != owner) {
      await cache.forget();
      throw StateError('Messaging session changed');
    }
    _hiddenIds.clear();
    _cacheOwner = owner;
    _cache = cache;
    _onlineOnly = onlineFallback;
    _cacheRecoveryStage = recoveryStage;
    _onlineAttemptIds.clear();
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
  Future<void> _saveOutbox(
    List<Map<String, dynamic>> values, {
    _CacheScope? scope,
  }) async {
    final target = scope ?? _captureCache();
    _requireCache(target);
    target.cache.data['outbox'] = values;
    await target.cache.save();
    _requireCache(target);
    if (!_changes.isClosed) _changes.add(null);
  }

  Stream<List<Map<String, dynamic>>> conversations() async* {
    await prepare();
    final scope = _captureCache();
    if (scope.cache.data['conversations'] != null) {
      yield (scope.cache.data['conversations'] as List)
          .cast<Map<String, dynamic>>();
    }
    if (!_currentCache(scope)) return;
    yield* watch(
      ['conversations', 'messages', 'conversation_members'],
      () async {
        _requireCache(scope);
        final rows = (await client.rpc('conversation_list') as List)
            .cast<Map<String, dynamic>>();
        _requireCache(scope);
        scope.cache.data['conversations'] = rows;
        await scope.cache.save();
        return rows;
      },
    );
  }

  Future<void> sync() async {
    await prepare();
    final scope = _captureCache();
    final rows = (await client.rpc('conversation_list') as List)
        .cast<Map<String, dynamic>>();
    _requireCache(scope);
    scope.cache.data['conversations'] = rows;
    await scope.cache.save();
    if (!_changes.isClosed) _changes.add(null);
    unawaited(flush().catchError((Object _) {}));
    unawaited(dispatchDueScheduledMessages().catchError((Object _) {}));
  }

  Future<void> markConversationRead(String cid) async {
    try {
      await client.rpc('ack_messages', params: {'cid': cid, 'mark_read': true});
      await sync();
    } catch (_) {}
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

  Future<String> exportBackup(String password, {BackupService? service}) async {
    await prepare();
    final scope = _captureCache();
    if (_onlineOnly) {
      throw StateError('Cannot create backup in online-only fallback mode');
    }
    final backupService = service ?? BackupService();
    return await backupService.createBackup(
      password: password,
      userId: scope.owner,
      cache: scope.cache,
    );
  }

  Future<BackupRestoreResult> importBackup(String password, String backupJson, {BackupService? service}) async {
    await prepare();
    final scope = _captureCache();
    final backupService = service ?? BackupService();
    final result = await backupService.restoreBackup(
      password: password,
      backupJson: backupJson,
      currentUserId: scope.owner,
      cache: scope.cache,
    );
    _hiddenIds.clear();
    if (!_changes.isClosed) _changes.add(null);
    return result;
  }

  Future<void> purgeExpiredLocal() async {
    if (_cache == null) return;
    final scope = _captureCache();
    if (!pruneLocalData(scope.cache.data, DateTime.now())) return;
    await scope.cache.save();
    _requireCache(scope);
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
    final scope = _captureCache();
    List<Map<String, dynamic>> rows =
        (scope.cache.data['messages.$cid'] as List? ?? [])
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
    if (!_currentCache(scope)) return;
    late StreamController<List<ChatMessage>> output;
    StreamSubscription<void>? pending;
    StreamSubscription<List<Map<String, dynamic>>>? server;
    output = StreamController(
      onListen: () {
        pending = _changes.stream.listen((_) {
          if (!output.isClosed && _currentCache(scope)) output.add(merged());
        });
        server =
            watch(
              ['messages', 'message_receipts', 'message_reactions'],
              () async {
                _requireCache(scope);
                final results = await loadWindow(cid, {
                  ...rows.take(200).map((row) => row['id'] as String),
                  ...?historyIds?.call(),
                });
                _requireCache(scope);
                final hidden = await client
                    .from('message_hides')
                    .select('message_id')
                    .eq('user_id', scope.owner);
                _requireCache(scope);
                final ids = hidden.map((e) => e['message_id']).toSet();
                _hiddenIds.addAll(ids.cast<String>());
                rows = results.where((e) => !ids.contains(e['id'])).toList();
                final receivedIds = results.map((e) => e['id']).toSet();
                scope.cache.data['outbox'] = _outbox
                    .where((m) => !receivedIds.contains(m['id']))
                    .toList();
                scope.cache.data['messages.$cid'] = rows.take(200).toList();
                final keys = scope.cache.data.keys
                    .where((k) => k.startsWith('messages.'))
                    .toList();
                while (keys.length > 20) {
                  scope.cache.data.remove(keys.removeAt(0));
                }
                await scope.cache.save();
                return rows;
              },
              cid: cid,
            ).listen(
              (_) {
                if (!output.isClosed && _currentCache(scope)) {
                  output.add(merged());
                }
              },
              onError: (Object e, StackTrace st) {
                if (!output.isClosed && _currentCache(scope)) {
                  output.addError(e, st);
                }
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
    final owner = client.auth.currentUser?.id;
    final epoch = _sessionEpoch;
    await prepare();
    final scope = _captureCache();
    if (scope.owner != owner || scope.epoch != epoch) {
      throw StateError('Messaging session changed');
    }
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
    if (_onlineOnly) {
      // Never claim delivery based on a volatile RAM outbox. Confirm with
      // Supabase before clearing the sender's message field. A retry of the
      // same unchanged text reuses its UUID if the prior response was lost.
      final media = ['image', 'video', 'audio', 'voice', 'file'].contains(kind);
      if (!((kind == 'text' && attachment == null && !viewOnce) ||
            (media && attachment != null &&
                (!viewOnce || ['image', 'video'].contains(kind))))) {
        throw StateError(
          'Encrypted local cache requires recovery before sending this file type.',
        );
      }
      final fingerprint = jsonEncode([
        cid, body, kind, replyTo, forwarded, seconds, viewOnce, attachment,
      ]);
      final onlineId = _onlineAttemptIds.putIfAbsent(
        fingerprint,
        () => const Uuid().v4(),
      );
      try {
        await client.rpc(
          viewOnce ? 'send_view_once_message' : 'send_message',
          params: viewOnce
              ? {
                  'cid': cid,
                  'mid': onlineId,
                  'attachment': attachment,
                  'media_kind': kind,
                }
              : {
                  'cid': cid,
                  'mid': onlineId,
                  'content': body,
                  'message_kind': kind,
                  'reply': replyTo,
                  'is_forwarded': forwarded,
                  'attachment': attachment,
                },
        ).timeout(const Duration(seconds: 15));
        _requireCache(scope);
        _onlineAttemptIds.remove(fingerprint);
        return onlineId;
      } catch (_) {
        _requireCache(scope);
        // Keep the attempt ID in memory for retry. The UI retains text when
        // this future fails; no error is mistaken for successful delivery.
        throw StateError(
          media
              ? 'Attachment send not confirmed. Check chat before trying again to avoid duplicates.'
              : 'Message was not confirmed by server. Retry when online.',
        );
      }
    }
    await _saveOutbox([..._outbox, item], scope: scope);
    unawaited(flush().catchError((Object _) {}));
    return id;
  }

  Future<void> flush({bool includeTerminal = false}) async {
    if (_onlineOnly) return; // Never flush an undecrypted encrypted outbox.
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
    final scope = _captureCache();
    final completion = Completer<void>();
    _flushDone = completion;
    try {
      await purgeExpiredLocal();
      final attempted = <String>{};
      while (true) {
        if (!_currentCache(scope)) break;
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
          _requireCache(scope);
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
            scope: scope,
          );
        } catch (error) {
          if (!_currentCache(scope)) break;
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
            scope: scope,
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
    await prepare();
    final scope = _captureCache();
    await client
        .from('message_hides')
        .upsert(
          {'message_id': id, 'user_id': scope.owner},
          onConflict: 'message_id,user_id',
          ignoreDuplicates: true,
        );
    _requireCache(scope);
    _hiddenIds.add(id);
    for (final key
        in scope.cache.data.keys
            .where((k) => k.startsWith('messages.'))
            .toList()) {
      scope.cache.data[key] = (scope.cache.data[key] as List)
          .where((m) => m['id'] != id)
          .toList();
    }
    await scope.cache.save();
    if (!_changes.isClosed) _changes.add(null);
  }

  // --- Starred / Saved Messages ---
  Future<void> starMessage(String mid, String cid) async {
    await prepare();
    final scope = _captureCache();
    final starred = (scope.cache.data['starred_messages'] as List? ?? []).cast<String>().toSet();
    starred.add(mid);
    scope.cache.data['starred_messages'] = starred.toList();
    await scope.cache.save();
    try {
      await client.rpc('star_message', params: {'mid': mid, 'cid': cid});
    } catch (_) {}
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> unstarMessage(String mid) async {
    await prepare();
    final scope = _captureCache();
    final starred = (scope.cache.data['starred_messages'] as List? ?? []).cast<String>().toSet();
    starred.remove(mid);
    scope.cache.data['starred_messages'] = starred.toList();
    await scope.cache.save();
    try {
      await client.rpc('unstar_message', params: {'mid': mid});
    } catch (_) {}
    if (!_changes.isClosed) _changes.add(null);
  }

  bool isMessageStarred(String mid) {
    if (_cache == null) return false;
    final starred = (_cache!.data['starred_messages'] as List? ?? []).cast<String>();
    return starred.contains(mid);
  }

  Stream<Set<String>> watchStarred(String cid) async* {
    await prepare();
    final scope = _captureCache();
    final initial = (scope.cache.data['starred_messages'] as List? ?? []).cast<String>().toSet();
    yield initial;
    yield* watch(['starred_messages'], () async {
      try {
        final rows = await client
            .from('starred_messages')
            .select('message_id')
            .eq('conversation_id', cid)
            .eq('user_id', scope.owner);
        final ids = (rows as List).map((r) => r['message_id'] as String).toSet();
        scope.cache.data['starred_messages'] = ids.toList();
        await scope.cache.save();
        return ids;
      } catch (_) {
        return (scope.cache.data['starred_messages'] as List? ?? []).cast<String>().toSet();
      }
    });
  }

  Future<List<Map<String, dynamic>>> getStarredMessages({String? conversationId}) async {
    await prepare();
    final scope = _captureCache();
    try {
      var query = client
          .from('starred_messages')
          .select('message_id, conversation_id, created_at, messages(*, profiles:sender_id(display_name))')
          .eq('user_id', scope.owner);
      if (conversationId != null) {
        query = query.eq('conversation_id', conversationId);
      }
      final rows = await query.order('created_at', ascending: false);
      return (rows as List).cast<Map<String, dynamic>>();
    } catch (_) {
      // Fallback to local cache
      final starredIds = (scope.cache.data['starred_messages'] as List? ?? []).cast<String>().toSet();
      final allMessages = <Map<String, dynamic>>[];
      for (final key in scope.cache.data.keys.where((k) => k.startsWith('messages.'))) {
        if (conversationId != null && key != 'messages.$conversationId') continue;
        final list = (scope.cache.data[key] as List? ?? []).cast<Map<String, dynamic>>();
        for (final m in list) {
          if (starredIds.contains(m['id'])) {
            allMessages.add(m);
          }
        }
      }
      return allMessages;
    }
  }

  // --- Scheduled Messages ---
  Future<String> scheduleMessage(
    String cid,
    String body,
    DateTime scheduledFor, {
    String kind = 'text',
  }) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('Not authenticated');
    final id = const Uuid().v4();
    await prepare();
    final scope = _captureCache();
    final localList = (scope.cache.data['scheduled_messages'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final entry = {
      'id': id,
      'conversation_id': cid,
      'sender_id': owner,
      'body': body,
      'kind': kind,
      'scheduled_for': scheduledFor.toUtc().toIso8601String(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    localList.add(entry);
    scope.cache.data['scheduled_messages'] = localList;
    await scope.cache.save();

    try {
      await client.from('scheduled_messages').insert(entry);
    } catch (_) {}
    if (!_changes.isClosed) _changes.add(null);
    return id;
  }

  Future<void> cancelScheduledMessage(String id) async {
    await prepare();
    final scope = _captureCache();
    final localList = (scope.cache.data['scheduled_messages'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['id'] != id)
        .toList();
    scope.cache.data['scheduled_messages'] = localList;
    await scope.cache.save();

    try {
      await client.from('scheduled_messages').delete().eq('id', id);
    } catch (_) {}
    if (!_changes.isClosed) _changes.add(null);
  }

  Stream<List<Map<String, dynamic>>> scheduledMessages(String cid) async* {
    await prepare();
    final scope = _captureCache();
    final initial = (scope.cache.data['scheduled_messages'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((e) => e['conversation_id'] == cid)
        .toList();
    yield initial;

    yield* watch(['scheduled_messages'], () async {
      try {
        final rows = await client
            .from('scheduled_messages')
            .select()
            .eq('conversation_id', cid)
            .order('scheduled_for');
        final items = (rows as List).cast<Map<String, dynamic>>();
        scope.cache.data['scheduled_messages'] = items;
        await scope.cache.save();
        return items;
      } catch (_) {
        return (scope.cache.data['scheduled_messages'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((e) => e['conversation_id'] == cid)
            .toList();
      }
    });
  }

  Future<void> dispatchDueScheduledMessages() async {
    await prepare();
    final scope = _captureCache();
    final now = DateTime.now();
    final localList = (scope.cache.data['scheduled_messages'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final due = <Map<String, dynamic>>[];
    final remaining = <Map<String, dynamic>>[];

    for (final item in localList) {
      final scheduledTime = DateTime.tryParse(item['scheduled_for'] ?? '');
      if (scheduledTime != null && !scheduledTime.isAfter(now)) {
        due.add(item);
      } else {
        remaining.add(item);
      }
    }

    if (due.isEmpty) return;

    scope.cache.data['scheduled_messages'] = remaining;
    await scope.cache.save();

    for (final item in due) {
      try {
        await send(
          item['conversation_id'] as String,
          item['body'] as String,
          kind: item['kind'] as String? ?? 'text',
        );
      } catch (_) {
        // Re-queue only if local outbox persistence actually failed.
        remaining.add(item);
        continue;
      }
      // A remote cleanup error must not re-queue a message already committed
      // to the encrypted outbox, where it would otherwise be sent twice.
      try {
        await client.from('scheduled_messages').delete().eq('id', item['id']);
      } catch (_) {
        // Retry remote cleanup independently; local send remains committed.
      }
    }
    scope.cache.data['scheduled_messages'] = remaining;
    await scope.cache.save();
    if (!_changes.isClosed) _changes.add(null);
  }

  // --- Group Polls ---
  Future<String> sendPoll(
    String cid,
    String question,
    List<String> options, {
    bool multiple = false,
  }) async {
    final trimmedOptions = options.map((o) => o.trim()).where((o) => o.isNotEmpty).toList();
    if (trimmedOptions.length < 2) {
      throw ArgumentError('Poll must have at least 2 options');
    }
    final pollData = {
      'question': question.trim(),
      'options': trimmedOptions,
      'multiple': multiple,
      'votes': <String, dynamic>{},
    };
    return send(cid, jsonEncode(pollData), kind: 'poll');
  }

  Future<void> votePoll(String mid, int optionIndex) async {
    await prepare();
    try {
      await client.rpc('vote_poll', params: {
        'mid': mid,
        'option_index': optionIndex,
      });
    } catch (_) {}
    if (!_changes.isClosed) _changes.add(null);
  }

  // --- Stickers & GIFs ---
  Future<String> sendSticker(String cid, Map<String, dynamic> stickerData) {
    return send(cid, jsonEncode(stickerData), kind: 'sticker');
  }

  Future<String> sendGif(String cid, Map<String, dynamic> gifData) {
    return send(cid, jsonEncode(gifData), kind: 'gif');
  }

  // --- Message Edit History ---
  Future<List<MessageEditRevision>> getEditHistory(String mid) async {
    await prepare();
    try {
      final rows = await client
          .from('message_edits')
          .select()
          .eq('message_id', mid)
          .order('edited_at', ascending: false);
      return (rows as List)
          .cast<Map<String, dynamic>>()
          .map(MessageEditRevision.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
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
    _onlineOnly = false;
    _cacheRecoveryStage = null;
    _onlineAttemptIds.clear();
    _hiddenIds.clear();
  }

  Future<void> clearLocal() async {
    // An unreadable encrypted outbox may contain unsent messages. Never delete
    // its ciphertext/key through the in-app clear action during recovery.
    if (_onlineOnly) {
      throw StateError('Encrypted local cache needs recovery. Existing files were preserved; do not clear app data.');
    }
    await suspend();
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
    _onlineOnly = false;
    _cacheRecoveryStage = null;
    _onlineAttemptIds.clear();
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
    _onlineOnly = false;
    _cacheRecoveryStage = null;
    _onlineAttemptIds.clear();
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
