import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
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
  Future<bool> authorized(String id);
}

class SupabaseCallBackend implements CallBackend {
  SupabaseCallBackend(this.client);
  final SupabaseClient client;
  @override
  String? get userId => client.auth.currentUser?.id;
  @override
  Stream<List<Map<String, dynamic>>> watch(String id) => client
      .from('calls')
      .stream(primaryKey: ['id'])
      .eq('id', id)
      .asyncMap(
        (rows) async => rows.isEmpty
            ? <Map<String, dynamic>>[]
            : [
                Map<String, dynamic>.from(
                  await client.rpc('call_snapshot', params: {'callid': id}),
                ),
              ],
      );
  @override
  Future<void> transition(String id, String action) async {
    final result = await client.functions.invoke(
      'call-control',
      body: {'call_id': id, 'action': action},
    );
    if (result.status != 200) throw StateError('Call update unavailable');
  }

  @override
  Future<bool> authorized(String id) async {
    try {
      await client.rpc('authorize_call', params: {'callid': id});
      return true;
    } on PostgrestException catch (error) {
      if ([
        '42501',
        'P0001',
        '28000',
        'PGRST301',
        'PGRST302',
      ].contains(error.code)) {
        return false;
      }
      rethrow;
    }
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
  Future<bool> projectionConsent();
  Future<void> projection(String session, bool enabled);
  Future<bool> enterPip();
  Future<void> closePip();
  Future<void> startTelecomCall(String id, String callerName, bool isVideo);
  Future<void> endTelecomCall(String id);
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
  Future<bool> projectionConsent() => Helper.requestCapturePermission();
  @override
  Future<void> projection(String session, bool enabled) => channel
      .invokeMethod<void>('projection', {'id': session, 'enabled': enabled});
  @override
  Future<void> stop(String id) =>
      channel.invokeMethod<void>('stopCall', {'id': id});

  @override
  Future<bool> enterPip() async {
    try {
      final res = await channel.invokeMethod<bool>('enterPip');
      return res == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> closePip() async {
    try {
      await channel.invokeMethod<void>('closePip');
    } on MissingPluginException {
    } catch (_) {}
  }

  @override
  Future<void> startTelecomCall(String id, String callerName, bool isVideo) async {
    try {
      await channel.invokeMethod<void>('startTelecomCall', {
        'id': id,
        'name': callerName,
        'video': isVideo,
      });
    } on MissingPluginException {
    } catch (_) {}
  }

  @override
  Future<void> endTelecomCall(String id) async {
    try {
      await channel.invokeMethod<void>('endTelecomCall', {'id': id});
    } on MissingPluginException {
    } catch (_) {}
  }
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
  bool get sharing => false;
  Future<void> receiveVideo(bool enabled) async {}
  Future<void> screenShare(bool enabled) async {
    throw UnsupportedError('Screen sharing unavailable');
  }

  /// Starts cancellation immediately, then drains any SDK operation before disposal.
  Future<void> close();
}

class LiveKitCallTransport extends CallTransport {
  LiveKitCallTransport() {
    _room.addListener(_changed);
    _events = _room.createListener()
      ..on<TrackSubscribedEvent>((event) {
        if (!_receiveVideo && event.track is VideoTrack) {
          unawaited(event.publication.unsubscribe().catchError((Object _) {}));
        }
      })
      ..on<RoomResumingEvent>((_) {
        _reconnecting = true;
        _changed();
      })
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
  bool _receiveVideo = true;
  bool _reconnecting = false, _failed = false, _connectedOnce = false;
  @override
  bool get reconnecting => _reconnecting;
  @override
  bool get failed => _failed;
  bool _closed = false;
  Future<void> _pending = Future.value();
  Future<void>? _closing;
  LocalAudioTrack? _audio;
  LocalVideoTrack? _video, _screen;
  @override
  bool get sharing => _room.localParticipant?.isScreenShareEnabled() == true;
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
    final track = _room.localParticipant
        ?.getTrackPublicationBySource(TrackSource.camera)
        ?.track;
    if (track is LocalVideoTrack) {
      await track.setCameraPosition(
        front ? CameraPosition.front : CameraPosition.back,
      );
    }
  });

  @override
  Future<void> receiveVideo(bool enabled) => _run(() async {
    _receiveVideo = enabled;
    for (final participant in _room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        if (enabled) {
          await publication.subscribe();
        } else {
          await publication.unsubscribe();
        }
      }
    }
  });
  @override
  Future<void> screenShare(bool enabled) => _run(() async {
    final participant = _room.localParticipant;
    if (participant == null) throw StateError('Call disconnected');
    if (enabled) {
      final publication = await participant.setScreenShareEnabled(
        true,
        captureScreenAudio: false,
        screenShareCaptureOptions: const ScreenShareCaptureOptions(
          params: VideoParametersPresets.screenShareH720FPS5,
        ),
      );
      _screen = publication?.track as LocalVideoTrack?;
      if (_closed) await _screen?.stop();
    } else {
      final screen = _screen;
      try {
        await participant.setScreenShareEnabled(false);
      } finally {
        try {
          await screen?.stop();
        } finally {
          _screen = null;
        }
      }
    }
  });

  Future<void> _stopTracks() => Future.wait([
    if (_audio != null) _audio!.stop().catchError((Object _) => false),
    if (_video != null) _video!.stop().catchError((Object _) => false),
    if (_screen != null) _screen!.stop().catchError((Object _) => false),
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
          await _screen?.dispose();
          await AudioManager.instance.setSpeakerOutputPreferred(false);
          super.dispose();
        }
      }
    }();
  }
}
