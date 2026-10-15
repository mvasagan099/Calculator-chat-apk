import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'call_transport.dart';

class _Attempt {
  static int sequence = 0;
  final serviceId = '${DateTime.now().microsecondsSinceEpoch}-${sequence++}';
  bool cancelled = false;
  CallTransport? transport;
}

class CallController extends ChangeNotifier {
  CallController(SupabaseClient client)
    : this.withDependencies(
        SupabaseCallBackend(client),
        AndroidCallDevice(),
        LiveKitCallTransport.new,
      );

  CallController.withDependencies(
    this.backend,
    this.device,
    this.createTransport,
  ) {
    AndroidCallDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'endCall' && call.arguments == callId) await end();
    });
  }
  final CallBackend backend;
  final CallDevice device;
  final CallTransport Function() createTransport;
  Room? get room => _attempt?.transport?.room;
  bool get reconnecting => _attempt?.transport?.reconnecting ?? false;
  String? callId;
  Map<String, dynamic>? metadata;
  StreamSubscription<List<Map<String, dynamic>>>? _subscription;
  Timer? _ticker, _endRetry;
  final _pendingEnds = <String, ({String action, String owner})>{};
  final _sendingEnds = <String>{};
  bool get hasPendingEnd => _pendingEnds.isNotEmpty;

  Future<void> syncPendingEnds() async {
    for (final id in _pendingEnds.keys.toList()) {
      await _syncEnd(id);
    }
  }

  Future<void> _syncEnd(String id) async {
    final pending = _pendingEnds[id];
    if (pending == null || _disposed || !_sendingEnds.add(id)) return;
    try {
      // A queued terminal operation must never cross an account boundary.
      if (backend.userId != pending.owner) {
        _pendingEnds.remove(id);
        return;
      }
      await backend
          .transition(id, pending.action)
          .timeout(const Duration(seconds: 10));
      _pendingEnds.remove(id);
    } finally {
      _sendingEnds.remove(id);
      if (_pendingEnds.isEmpty) {
        _endRetry?.cancel();
        _endRetry = null;
      }
      _notify();
    }
  }

  _Attempt? _attempt;
  bool _disposed = false, _ended = false, _timeoutPending = false;
  int _generation = 0;
  DateTime? _lastTimeout;
  bool connecting = false,
      mic = true,
      camera = false,
      speaker = false,
      frontCamera = true;
  String? error;
  Duration duration = Duration.zero;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> observe(String id) async {
    if (_disposed || callId == id) return;
    if (callId != null) {
      if (!_ended && ['ringing', 'accepted'].contains(metadata?['state'])) {
        throw StateError('End the current call first');
      }
      await reset();
    }
    if (_disposed) return;
    final generation = ++_generation;
    callId = id;
    _ended = false;
    error = null;
    // Supabase stream supplies the initial snapshot and subsequent updates.
    // A separate SELECT could overwrite a newer terminal realtime event.
    _subscription = backend
        .watch(id)
        .listen(
          (rows) {
            if (_disposed ||
                generation != _generation ||
                rows.isEmpty ||
                _ended) {
              return;
            }
            metadata = rows.first;
            final state = metadata!['state'];
            if (!['ringing', 'accepted'].contains(state)) {
              _ended = true;
              unawaited(disconnect());
            } else if (state == 'accepted' &&
                _attempt == null &&
                error == null) {
              unawaited(_connectSafely());
            }
            _notify();
          },
          onError: (Object _) {
            if (_disposed || generation != _generation || _ended) return;
            error = 'Call updates interrupted. Check your connection.';
            _notify();
          },
        );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final call = metadata;
      if (_ended || call == null) return;
      if (call['answered_at'] != null) {
        duration = DateTime.now().difference(
          DateTime.parse(call['answered_at']),
        );
      }
      final now = DateTime.now();
      if (call['state'] == 'ringing' &&
          call['caller_id'] == backend.userId &&
          now.difference(DateTime.parse(call['created_at'])) >
              const Duration(seconds: 45) &&
          !_timeoutPending &&
          (_lastTimeout == null ||
              now.difference(_lastTimeout!) > const Duration(seconds: 10))) {
        _timeoutPending = true;
        _lastTimeout = now;
        unawaited(
          backend
              .transition(id, 'timeout')
              .catchError((Object _) {})
              .whenComplete(() {
                _timeoutPending = false;
              }),
        );
      }
      _notify();
    });
    _notify();
  }

  Future<void> _connectSafely() async {
    try {
      await connect();
    } catch (_) {
      /* Error already exposed in state. */
    }
  }

  Future<void> accept() async {
    final id = callId;
    final generation = _generation;
    if (id == null || _ended || _disposed) return;
    await backend.transition(id, 'accept');
    if (generation == _generation && !_ended && !_disposed) await connect();
  }

  Future<void> reject() => _finish('reject');

  bool _current(_Attempt attempt) =>
      !_disposed &&
      !_ended &&
      !attempt.cancelled &&
      identical(_attempt, attempt);

  Future<void> connect() async {
    final id = callId;
    if (_disposed || _ended || connecting || _attempt != null || id == null) {
      return;
    }
    final attempt = _Attempt();
    _attempt = attempt;
    connecting = true;
    error = null;
    final video = metadata?['video'] == true;
    _notify();
    try {
      final grant = await backend.grant(id);
      if (!_current(attempt)) return;
      // Ask before entering an SDK capture operation. A permission dialog can
      // remain open after the user has ended the call.
      await device.permissions(video);
      if (!_current(attempt)) return;
      final transport = createTransport();
      attempt.transport = transport;
      transport.addListener(_mediaChanged);
      await transport.connect(grant);
      if (!_current(attempt)) return;
      await device.start(attempt.serviceId, id, video);
      if (!_current(attempt)) return;
      await transport.microphone(true);
      if (!_current(attempt)) return;
      mic = true;
      if (video) await transport.camera(true);
      if (!_current(attempt)) return;
      camera = video;
      await transport.speaker(speaker);
    } catch (_) {
      if (_current(attempt)) {
        error = 'Could not connect. Check your connection and permissions.';
        _attempt = null;
        attempt.cancelled = true;
        rethrow;
      }
    } finally {
      if (!_current(attempt)) {
        await _close(attempt);
      }
      if (identical(_attempt, attempt) || _attempt == null) {
        connecting = false;
        _notify();
      }
    }
  }

  Future<void> _close(_Attempt attempt) async {
    attempt.cancelled = true;
    final transport = attempt.transport;
    transport?.removeListener(_mediaChanged);
    // Stop is repeated after the connecting task settles; a late native start
    // is bound to this attempt and cannot stop a newer foreground call.
    await Future.wait([
      if (transport != null) transport.close().catchError((Object _) {}),
      device.stop(attempt.serviceId).catchError((Object _) {}),
    ]);
  }

  void _mediaChanged() {
    if (_attempt?.transport?.failed == true && !_ended) {
      error = 'The call connection ended.';
      unawaited(_finish('disconnect').catchError((Object _) {}));
    }
    _notify();
  }

  Future<void> toggleMic() async {
    final attempt = _attempt;
    if (attempt?.transport == null || connecting || !_current(attempt!)) return;
    final enabled = !mic;
    await attempt.transport!.microphone(enabled);
    if (_current(attempt)) {
      mic = enabled;
      _notify();
    }
  }

  Future<void> toggleCamera() async {
    final attempt = _attempt;
    if (attempt?.transport == null || connecting || !_current(attempt!)) return;
    final enabled = !camera;
    await attempt.transport!.camera(enabled);
    if (_current(attempt)) {
      camera = enabled;
      _notify();
    }
  }

  Future<void> toggleSpeaker() async {
    final attempt = _attempt;
    if (attempt?.transport == null || connecting || !_current(attempt!)) return;
    final enabled = !speaker;
    await attempt.transport!.speaker(enabled);
    if (_current(attempt)) {
      speaker = enabled;
      _notify();
    }
  }

  Future<void> switchCamera() async {
    final attempt = _attempt;
    if (attempt?.transport == null || connecting || !_current(attempt!)) return;
    final front = !frontCamera;
    await attempt.transport!.switchCamera(front);
    if (_current(attempt)) {
      frontCamera = front;
      _notify();
    }
  }

  Future<void> end() => _finish('end');
  Future<void> _finish(String action) async {
    final id = callId;
    if (id == null || _ended || _disposed) return;
    _ended = true;
    metadata = {
      ...?metadata,
      'state': action == 'reject'
          ? 'rejected'
          : action == 'disconnect'
          ? 'disconnected'
          : 'ended',
    };
    // Start local teardown before a network operation that may be offline.
    unawaited(disconnect());
    _notify();
    final owner = backend.userId;
    if (owner == null) return;
    _pendingEnds[id] = (action: action, owner: owner);
    _endRetry ??= Timer.periodic(const Duration(seconds: 5), (_) {
      for (final pendingId in _pendingEnds.keys.toList()) {
        unawaited(_syncEnd(pendingId).catchError((Object _) {}));
      }
    });
    await _syncEnd(id);
  }

  Future<void> disconnect() async {
    final previous = _attempt;
    final id = callId;
    _attempt = null;
    connecting = false;
    if (previous != null && id != null) await _close(previous);
    _notify();
  }

  Future<void> reset() async {
    ++_generation;
    _ended = true;
    final closing = disconnect();
    final subscription = _subscription;
    _subscription = null;
    _ticker?.cancel();
    _ticker = null;
    callId = null;
    metadata = null;
    duration = Duration.zero;
    _lastTimeout = null;
    _timeoutPending = false;
    await subscription?.cancel();
    await closing;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _ended = true;
    _subscription?.cancel();
    _ticker?.cancel();
    _endRetry?.cancel();
    _pendingEnds.clear();
    unawaited(disconnect());
    AndroidCallDevice.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
