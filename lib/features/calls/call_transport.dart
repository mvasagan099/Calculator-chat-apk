import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CallGrant {
  const CallGrant(this.url, this.token);
  final String url, token;
}

abstract interface class CallBackend {
  String? get userId;
  Stream<List<Map<String, dynamic>>> watch(String id);
  Future<void> transition(String id, String action);
  Future<CallGrant> grant(String id);
}

class SupabaseCallBackend implements CallBackend {
  SupabaseCallBackend(this.client);
  final SupabaseClient client;
  @override
  String? get userId => client.auth.currentUser?.id;
  @override
  Stream<List<Map<String, dynamic>>> watch(String id) =>
      client.from('calls').stream(primaryKey: ['id']).eq('id', id);
  @override
  Future<void> transition(String id, String action) async {
    await client.rpc(
      'transition_call',
      params: {'callid': id, 'action': action},
    );
  }

  @override
  Future<CallGrant> grant(String id) async {
    final response = await client.functions.invoke(
      'livekit-token',
      body: {'call_id': id},
    );
    if (response.status != 200) throw StateError('Room access unavailable');
    return CallGrant(
      response.data['url'] as String,
      response.data['token'] as String,
    );
  }
}

abstract interface class CallDevice {
  Future<void> permissions(bool video);
  Future<void> start(String session, String callId, bool video);
  Future<void> stop(String id);
}

class AndroidCallDevice implements CallDevice {
  static const channel = MethodChannel('calculator_messenger/calls');
  static Future<void> bluetoothPermission() =>
      channel.invokeMethod<void>('requestBluetooth');
  @override
  Future<void> permissions(bool video) =>
      channel.invokeMethod<void>('requestPermissions', {'video': video});
  @override
  Future<void> start(String session, String callId, bool video) =>
      channel.invokeMethod<void>('startCall', {
        'id': session,
        'callId': callId,
        'video': video,
      });
  @override
  Future<void> stop(String id) =>
      channel.invokeMethod<void>('stopCall', {'id': id});
}

abstract class CallTransport extends ChangeNotifier {
  Room? get room;
  bool get reconnecting => false;
  bool get failed => false;
  Future<void> connect(CallGrant grant);
  Future<void> microphone(bool enabled);
  Future<void> camera(bool enabled);
  Future<void> speaker(bool enabled);
  Future<void> switchCamera(bool front);

  /// Starts cancellation immediately, then drains any SDK operation before disposal.
  Future<void> close();
}

class LiveKitCallTransport extends CallTransport {
  LiveKitCallTransport() {
    _room.addListener(_changed);
    _events = _room.createListener()
      ..on<RoomReconnectingEvent>((_) {
        _reconnecting = true;
        _changed();
      })
      ..on<RoomReconnectedEvent>((_) {
        _reconnecting = false;
        _changed();
      })
      ..on<RoomDisconnectedEvent>((_) {
        if (_connectedOnce && !_closed) {
          _failed = true;
          _changed();
        }
      });
  }
  final Room _room = Room(
    roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
  );
  late final EventsListener<RoomEvent> _events;
  bool _reconnecting = false, _failed = false, _connectedOnce = false;
  @override
  bool get reconnecting => _reconnecting;
  @override
  bool get failed => _failed;
  bool _closed = false;
  Future<void> _pending = Future.value();
  Future<void>? _closing;
  LocalAudioTrack? _audio;
  LocalVideoTrack? _video;
  @override
  Room get room => _room;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) {
    final next = _pending.then((_) async {
      if (!_closed) await action();
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> connect(CallGrant grant) => _run(() async {
    await _room.connect(grant.url, grant.token);
    _connectedOnce = true;
  });
  @override
  Future<void> microphone(bool enabled) => _run(() async {
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('Call disconnected');
    if (enabled && _audio == null) {
      final track = await LocalAudioTrack.create();
      _audio = track;
      if (_closed) {
        await track.stop();
        return;
      }
      try {
        await participant.publishAudioTrack(track);
      } catch (_) {
        await track.stop();
        rethrow;
      }
    } else {
      await participant.setMicrophoneEnabled(enabled);
    }
    if (_closed) await _audio?.stop();
  });
  @override
  Future<void> camera(bool enabled) => _run(() async {
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('Call disconnected');
    if (enabled && _video == null) {
      final track = await LocalVideoTrack.createCameraTrack();
      _video = track;
      if (_closed) {
        await track.stop();
        return;
      }
      try {
        await participant.publishVideoTrack(track);
      } catch (_) {
        await track.stop();
        rethrow;
      }
    } else {
      await participant.setCameraEnabled(enabled);
    }
    if (_closed) await _video?.stop();
  });
  @override
  Future<void> speaker(bool enabled) =>
      _run(() => AudioManager.instance.setSpeakerOutputPreferred(enabled));
  @override
  Future<void> switchCamera(bool front) => _run(() async {
    final track =
        _room.localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (track is LocalVideoTrack) {
      await track.setCameraPosition(
        front ? CameraPosition.front : CameraPosition.back,
      );
    }
  });

  Future<void> _stopTracks() => Future.wait([
    if (_audio != null) _audio!.stop().catchError((Object _) => false),
    if (_video != null) _video!.stop().catchError((Object _) => false),
  ]).then((_) {});

  @override
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _room.removeListener(_changed);
    // Interrupt networking immediately. A capture operation already inside the
    // SDK must also finish before the final teardown, so it cannot outlive us.
    final stopped = _stopTracks();
    final interrupted = _room.disconnect().catchError((Object _) {});
    return _closing = () async {
      await _events.dispose();
      await stopped;
      await interrupted;
      await _pending;
      await _stopTracks();
      try {
        await _room.disconnect();
      } finally {
        try {
          await _room.dispose();
        } finally {
          await _audio?.dispose();
          await _video?.dispose();
          super.dispose();
        }
      }
    }();
  }
}
