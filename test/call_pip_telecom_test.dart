import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:calculator_messenger/features/calls/call_controller.dart';
import 'package:calculator_messenger/features/calls/call_transport.dart';

class MockBackend implements CallBackend {
  final streams = <String, StreamController<List<Map<String, dynamic>>>>{};
  final transitions = <String>[];
  String currentUserId = 'user-alice';

  @override
  String get userId => currentUserId;

  @override
  Future<bool> authorized(String id) async => true;

  @override
  Future<CallGrant> grant(String id) async =>
      const CallGrant('wss://test.livekit.cloud', 'mock-token');

  @override
  Stream<List<Map<String, dynamic>>> watch(String id) =>
      (streams[id] ??= StreamController.broadcast(sync: true)).stream;

  @override
  Future<void> transition(String id, String action) async {
    transitions.add('$id:$action');
  }

  void emit(String id, Map<String, dynamic> metadata) {
    streams[id]!.add([metadata]);
  }

  Future<void> close() async {
    for (final stream in streams.values) {
      await stream.close();
    }
  }
}

class MockDevice implements CallDevice {
  bool pipActive = false;
  bool allowPip = true;
  final telecomCalls = <String>[];
  final endedCalls = <String>[];

  @override
  Future<bool> enterPip() async {
    if (allowPip) {
      pipActive = true;
      return true;
    }
    return false;
  }

  @override
  Future<void> closePip() async {
    pipActive = false;
  }

  @override
  Future<void> startTelecomCall(String id, String callerName, bool isVideo) async {
    telecomCalls.add('$id:$callerName:$isVideo');
  }

  @override
  Future<void> endTelecomCall(String id) async {
    endedCalls.add(id);
  }

  @override
  Future<void> permissions(bool video) async {}

  @override
  Future<void> start(
    String session,
    String callId,
    bool video, {
    String? contactName,
    int? startTime,
  }) async {}

  @override
  Future<void> stop(String id) async {}

  @override
  Future<bool> projectionConsent() async => true;

  @override
  Future<void> projection(String session, bool enabled) async {}
}

class MockTransport extends CallTransport {
  final operations = <String>[];

  @override
  Room? get room => null;

  @override
  Future<void> connect(CallGrant grant) async {
    operations.add('connect');
  }

  @override
  Future<void> camera(bool enabled) async {
    operations.add('camera:$enabled');
  }

  @override
  Future<void> microphone(bool enabled) async {
    operations.add('mic:$enabled');
  }

  @override
  Future<void> speaker(bool enabled) async {
    operations.add('speaker:$enabled');
  }

  @override
  Future<void> switchCamera(bool front) async {
    operations.add('switch-camera:$front');
  }

  @override
  Future<void> close() async {
    operations.add('close');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBackend backend;
  late MockDevice device;
  late MockTransport transport;
  late CallController controller;

  setUp(() {
    backend = MockBackend();
    device = MockDevice();
    transport = MockTransport();
    controller = CallController.withDependencies(
      backend,
      device,
      () => transport,
    );
  });

  tearDown(() async {
    controller.dispose();
    await backend.close();
  });

  group('Picture-in-Picture (PiP) Video Call Controls', () {
    test('enterPip returns false if call is not in joined state', () async {
      expect(controller.joined, isFalse);
      final entered = await controller.enterPip();
      expect(entered, isFalse);
      expect(controller.inPip, isFalse);
      expect(device.pipActive, isFalse);
    });

    test('enterPip succeeds and updates inPip when call is joined', () async {
      const callId = 'call-101';
      final watchFuture = controller.watchCall(callId);
      backend.emit(callId, {
        'id': callId,
        'state': 'accepted',
        'self_state': 'joined',
        'caller_id': 'user-bob',
        'caller_name': 'Bob',
        'video': true,
      });
      await watchFuture;

      expect(controller.joined, isTrue);

      var notified = false;
      controller.addListener(() => notified = true);

      final entered = await controller.enterPip();
      expect(entered, isTrue);
      expect(controller.inPip, isTrue);
      expect(device.pipActive, isTrue);
      expect(notified, isTrue);
    });

    test('closePip sets inPip to false and delegates to device.closePip', () async {
      controller.inPip = true;
      device.pipActive = true;

      var notified = false;
      controller.addListener(() => notified = true);

      await controller.closePip();
      expect(controller.inPip, isFalse);
      expect(device.pipActive, isFalse);
      expect(notified, isTrue);
    });

    test('pipChanged method call from platform channel updates inPip status', () async {
      expect(controller.inPip, isFalse);

      final encodedTrue = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('pipChanged', true),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('calculator_messenger/calls', encodedTrue, (ByteData? _) {});

      expect(controller.inPip, isTrue);

      final encodedFalse = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('pipChanged', false),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('calculator_messenger/calls', encodedFalse, (ByteData? _) {});

      expect(controller.inPip, isFalse);
    });

    test('PRIVACY CRITICAL: handleRelock immediately closes PiP and mutes camera', () async {
      const callId = 'call-relock';
      final watchFuture = controller.watchCall(callId);
      backend.emit(callId, {
        'id': callId,
        'state': 'accepted',
        'self_state': 'joined',
        'caller_id': 'user-bob',
        'caller_name': 'Bob',
        'video': true,
      });
      await watchFuture;

      await controller.enterPip();
      controller.camera = true;
      expect(controller.inPip, isTrue);
      expect(controller.camera, isTrue);

      // Trigger privacy relock
      await controller.handleRelock();

      // PiP must be closed and camera must be blanked
      expect(controller.inPip, isFalse);
      expect(device.pipActive, isFalse);
      expect(controller.camera, isFalse);
      expect(transport.operations, contains('camera:false'));
    });
  });

  group('Android Telecom Integration', () {
    test('starts telecom call when incoming call transitions to ringing', () async {
      const callId = 'call-telecom-1';
      final watchFuture = controller.watchCall(callId);

      backend.emit(callId, {
        'id': callId,
        'state': 'ringing',
        'self_state': 'invited',
        'caller_id': 'user-bob',
        'caller_name': 'Bob Ross',
        'video': true,
      });
      await watchFuture;

      expect(device.telecomCalls, contains('call-telecom-1:Bob Ross:true'));
    });

    test('telecomAnswer method call from TelecomConnectionService accepts call', () async {
      const callId = 'call-telecom-2';
      final watchFuture = controller.watchCall(callId);
      backend.emit(callId, {
        'id': callId,
        'state': 'ringing',
        'self_state': 'invited',
        'caller_id': 'user-bob',
        'caller_name': 'Bob',
        'video': true,
      });
      await watchFuture;

      final encoded = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('telecomAnswer', callId),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('calculator_messenger/calls', encoded, (ByteData? _) {});

      expect(backend.transitions, contains('$callId:accept'));
    });

    test('telecomReject method call from TelecomConnectionService rejects call', () async {
      const callId = 'call-telecom-3';
      final watchFuture = controller.watchCall(callId);
      backend.emit(callId, {
        'id': callId,
        'state': 'ringing',
        'self_state': 'invited',
        'caller_id': 'user-bob',
        'caller_name': 'Bob',
        'video': false,
      });
      await watchFuture;

      final encoded = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('telecomReject', callId),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('calculator_messenger/calls', encoded, (ByteData? _) {});

      expect(backend.transitions, contains('$callId:reject'));
    });

    test('disconnect triggers endTelecomCall on the active call', () async {
      const callId = 'call-telecom-4';
      final watchFuture = controller.watchCall(callId);
      backend.emit(callId, {
        'id': callId,
        'state': 'accepted',
        'self_state': 'joined',
        'caller_id': 'user-bob',
        'caller_name': 'Bob',
        'video': false,
      });
      await watchFuture;

      await controller.disconnect();

      expect(device.endedCalls, contains(callId));
    });
  });

  group('Missed Call Callbacks', () {
    test('fires onMissedCall callback when ringing call transitions to cancelled', () async {
      const callId = 'call-missed-1';
      Map<String, dynamic>? capturedMetadata;
      controller.onMissedCall = (meta) => capturedMetadata = meta;

      final watchFuture = controller.watchCall(callId);

      // 1. Ringing
      backend.emit(callId, {
        'id': callId,
        'state': 'ringing',
        'self_state': 'invited',
        'caller_id': 'user-charlie',
        'caller_name': 'Charlie',
      });
      await watchFuture;

      // 2. Caller cancelled before answer
      backend.emit(callId, {
        'id': callId,
        'state': 'cancelled',
        'self_state': 'invited',
        'caller_id': 'user-charlie',
        'caller_name': 'Charlie',
      });

      expect(capturedMetadata, isNotNull);
      expect(capturedMetadata!['id'], callId);
      expect(capturedMetadata!['caller_id'], 'user-charlie');
      expect(capturedMetadata!['state'], 'cancelled');
    });

    test('does NOT fire onMissedCall if user was the caller', () async {
      const callId = 'call-self-caller';
      var missedFired = false;
      controller.onMissedCall = (_) => missedFired = true;

      final watchFuture = controller.watchCall(callId);

      // Current user (alice) called someone else
      backend.emit(callId, {
        'id': callId,
        'state': 'ringing',
        'self_state': 'invited',
        'caller_id': backend.userId, // Alice
      });
      await watchFuture;

      backend.emit(callId, {
        'id': callId,
        'state': 'timeout',
        'self_state': 'invited',
        'caller_id': backend.userId,
      });

      expect(missedFired, isFalse);
    });
  });
}
