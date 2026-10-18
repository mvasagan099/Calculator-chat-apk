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
      if (call.method == 'pipChanged') {
        inPip = call.arguments == true;
        _notify();
      }
      if (call.method == 'telecomAnswer' && call.arguments == callId) {
        await accept();
      }
      if (call.method == 'telecomReject' && call.arguments == callId) {
        await reject();
      }
    });
  }
  final CallBackend backend;
  final CallDevice device;
  final CallTransport Function() createTransport;
  bool inPip = false;
  void Function(Map<String, dynamic> metadata)? onMissedCall;
  Room? get room => _attempt?.transport?.room;
  bool get finished => _ended;
  bool get joined =>
      metadata?['self_state'] == 'joined' ||
      (metadata?['self_state'] == null && metadata?['state'] == 'accepted');
  bool get sharing => _attempt?.transport?.sharing ?? false;
  bool _sharingBusy = false;
  bool audioOnly = false;
  int _sharingEpoch = 0;
  bool get reconnecting => _attempt?.transport?.reconnecting ?? false;
  String? callId;

  Future<bool> enterPip() async {
    if (_disposed || _ended || !joined) return false;
    final res = await device.enterPip();
    if (res) {
      inPip = true;
      _notify();
    }
    return res;
  }

  Future<void> closePip() async {
    inPip = false;
    await device.closePip();
    _notify();
  }

  Future<void> handleRelock() async {
    if (inPip) {
      await closePip();
    }
    if (camera) {
      camera = false;
      await _attempt?.transport?.camera(false);
    }
    _notify();
  }
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
  DateTime? _lastTimeout, _lastAuthorization;
  bool _checkingAuthorization = false;
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
    if (_disposed || (callId == id && !_ended)) return;
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
            if (_disposed || generation != _generation || _ended) {
              return;
            }
            if (rows.isEmpty) {
              _ended = true;
              metadata = {...?metadata, 'state': 'unavailable'};
              unawaited(disconnect());
              _notify();
              return;
            }
            final previousState = metadata?['state'];
            final previousSelf = metadata?['self_state'];
            metadata = rows.first;
            final state = metadata!['state'];
            final selfState = metadata?['self_state'];
            if (previousState != 'ringing' &&
                state == 'ringing' &&
                metadata?['caller_id'] != backend.userId) {
              unawaited(
                device
                    .startTelecomCall(
                      id,
                      metadata?['caller_name'] as String? ?? 'Caller',
                      metadata?['video'] == true,
                    )
                    .catchError((Object _) {}),
              );
            }
            if (previousState == 'ringing' &&
                (state == 'cancelled' || state == 'timeout' || state == 'missed' || selfState == 'missed') &&
                previousSelf == 'invited' &&
                metadata?['caller_id'] != backend.userId) {
              try {
                onMissedCall?.call(metadata!);
              } catch (_) {}
            }
            if (!['ringing', 'accepted'].contains(state) ||
                [
                  'removed',
                  'declined',
                  'busy',
                  'missed',
                ].contains(metadata?['self_state'])) {
              _ended = true;
              unawaited(disconnect());
            } else if (state == 'accepted' &&
                joined &&
                _attempt == null &&
                error == null) {
              unawaited(_connectSafely());
            }
            _notify();
          },
          onError: (Object _) {
            if (_disposed || generation != _generation || _ended) return;
            error =
                'Call authorization or updates unavailable. Reopen the call to retry.';
            _ended = true;
            unawaited(disconnect());
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
      if (_attempt != null &&
          (_lastAuthorization == null ||
              now.difference(_lastAuthorization!) >=
                  const Duration(seconds: 15))) {
        _lastAuthorization = now;
        unawaited(verifyAuthorization());
      }
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

  Future<void> verifyAuthorization() async {
    final id = callId;
    final generation = _generation;
    if (id == null || _ended || _disposed || _checkingAuthorization) return;
    _checkingAuthorization = true;
    try {
      final allowed = await backend
          .authorized(id)
          .timeout(const Duration(seconds: 10));
      if (!allowed && generation == _generation && !_disposed && !_ended) {
        _ended = true;
        metadata = {...?metadata, 'state': 'unavailable'};
        error = 'Call access has been withdrawn.';
        await disconnect();
      }
    } catch (_) {
      /* Temporary network loss is handled by the SDK reconnect path. */
    } finally {
      _checkingAuthorization = false;
    }
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
    await backend.transition(
      id,
      metadata?['self_state'] == 'left' ? 'join' : 'accept',
    );
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
    audioOnly = false;
    camera = false;
    frontCamera = true;
    error = null;
    final video = metadata?['video'] == true;
    _notify();
    try {
      final grant = await backend.grant(id);
      if (!_current(attempt)) return;
      // Ask before entering an SDK capture operation. A permission dialog can
      // remain open after the user has ended the call.
      await device.permissions(false);
      if (!_current(attempt)) return;
      var useCamera = video;
      if (video) {
        try {
          await device.permissions(true);
        } catch (_) {
          useCamera = false;
        }
      }
      if (!_current(attempt)) return;
      final transport = createTransport();
      attempt.transport = transport;
      transport.addListener(_mediaChanged);
      await transport.connect(grant);
      if (!_current(attempt)) return;
      await device.start(attempt.serviceId, id, useCamera);
      if (!_current(attempt)) return;
      await transport.microphone(true);
      if (!_current(attempt)) return;
      mic = true;
      if (useCamera) {
        try {
          await transport.camera(true);
        } catch (_) {
          useCamera = false;
        }
      }
      if (!_current(attempt)) return;
      camera = useCamera;
      if (video && !camera) error = 'Camera unavailable. Audio remains active.';
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
      device.projection(attempt.serviceId, false).catchError((Object _) {}),
    ]);
  }

  void _mediaChanged() {
    if (_attempt?.transport?.failed == true && !_ended) {
      error = 'The call connection ended.';
      unawaited(_finish('disconnect').catchError((Object _) {}));
    }
    if (!sharing) {
      final attempt = _attempt;
      if (attempt != null) {
        unawaited(
          device.projection(attempt.serviceId, false).catchError((Object _) {}),
        );
      }
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
    if (enabled) {
      await device.permissions(true);
      if (!_current(attempt)) return;
      try { await device.start(attempt.serviceId, callId!, true); }
      catch (_) { if(_current(attempt)) await _finish('disconnect'); rethrow; }
      if (!_current(attempt)) return;
    }
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

  Future<void> toggleAudioOnly() async {
    final attempt = _attempt;
    if (attempt?.transport == null || !_current(attempt!)) return;
    final enabled = !audioOnly;
    if (enabled) {
      await stopSharing();
      await attempt.transport!.camera(false);
      if (!_current(attempt)) return;
      camera = false;
    }
    await attempt.transport!.receiveVideo(!enabled);
    if (_current(attempt)) {
      audioOnly = enabled;
      _notify();
    }
  }

  Future<void> stopSharing() async {
    ++_sharingEpoch;
    final attempt = _attempt;
    if (attempt == null) return;
    try {
      await attempt.transport?.screenShare(false);
    } finally {
      await device.projection(attempt.serviceId, false);
      _notify();
    }
  }

  Future<void> toggleSharing(
    Future<bool> Function(Future<bool> Function()) consent,
  ) async {
    final attempt = _attempt;
    if (attempt?.transport == null ||
        !_current(attempt!) ||
        connecting ||
        _sharingBusy) {
      return;
    }
    if (sharing) {
      await stopSharing();
      return;
    }
    _sharingBusy = true;
    final epoch = ++_sharingEpoch;
    try {
      if (!await consent(device.projectionConsent) ||
          !_current(attempt) ||
          epoch != _sharingEpoch) {
        return;
      }
      await device.projection(attempt.serviceId, true);
      if (!_current(attempt) || epoch != _sharingEpoch) return;
      await attempt.transport!.screenShare(true);
      if (!_current(attempt) || epoch != _sharingEpoch) {
        await attempt.transport!.screenShare(false);
      }
    } finally {
      if (!sharing) await device.projection(attempt.serviceId, false);
      _sharingBusy = false;
      _notify();
    }
  }

  Future<void> endForAll() => _finish('end_for_all');
  Future<void> end() =>
      _finish(metadata?['group_call'] == true ? 'leave' : 'end');
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
    ++_sharingEpoch;
    if (inPip) await closePip();
    final previous = _attempt;
    final id = callId;
    if (id != null) {
      unawaited(device.endTelecomCall(id).catchError((Object _) {}));
    }
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
    _lastAuthorization = null;
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
