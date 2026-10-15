import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:calculator_messenger/features/calls/call_controller.dart';
import 'package:calculator_messenger/features/calls/call_transport.dart';

class TestBackend implements CallBackend {
  final streams = <String, StreamController<List<Map<String, dynamic>>>>{};
  final grants = <String, Completer<CallGrant>>{};
  Completer<void>? transitionPending;
  bool failTransition = false;
  String owner = 'owner';
  final transitions = <String>[];
  @override
  String get userId => owner;
  @override
  Stream<List<Map<String, dynamic>>> watch(String id) =>
      (streams[id] ??= StreamController.broadcast(sync: true)).stream;
  @override
  Future<CallGrant> grant(String id) =>
      (grants[id] ??= Completer<CallGrant>()).future;
  @override
  Future<void> transition(String id, String action) async {
    transitions.add('$id:$action');
    await transitionPending?.future;
    if (failTransition) throw StateError('offline');
  }

  void emit(String id, String state) => streams[id]!.add([
    {
      'id': id,
      'state': state,
      'caller_id': 'owner',
      'video': true,
      'created_at': DateTime.now().toIso8601String(),
    },
  ]);
  void allow(String id) => grants[id]!.complete(
    const CallGrant('wss://example.invalid', 'unit-test-token'),
  );
  Future<void> close() async {
    for (final stream in streams.values) {
      await stream.close();
    }
  }
}

class TestDevice implements CallDevice {
  Completer<void>? permissionPending, startPending;
  final stopped = <String>[];
  String? active;
  int permissionRequests = 0;
  @override
  Future<void> permissions(bool video) async {
    permissionRequests++;
    await permissionPending?.future;
  }

  @override
  Future<void> start(String session, String callId, bool video) async {
    await startPending?.future;
    active = session;
  }

  @override
  Future<void> stop(String id) async {
    stopped.add(id);
    if (active == id) active = null;
  }
}

class TestTransport extends CallTransport {
  Completer<void>? connectPending;
  bool closed = false, failMic = false, failedConnection = false;
  @override
  bool get failed => failedConnection;
  final operations = <String>[];
  @override
  Room? get room => null;
  @override
  Future<void> connect(CallGrant grant) async {
    operations.add('connect');
    await connectPending?.future;
  }

  @override
  Future<void> microphone(bool enabled) async {
    if (failMic) throw StateError('permission revoked');
    operations.add('mic:$enabled');
  }

  @override
  Future<void> camera(bool enabled) async => operations.add('camera:$enabled');
  @override
  Future<void> speaker(bool enabled) async =>
      operations.add('speaker:$enabled');
  @override
  Future<void> switchCamera(bool front) async => operations.add('front:$front');
  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TestBackend backend;
  late TestDevice device;
  late CallController controller;
  late List<TestTransport> transports;
  TestTransport Function()? factory;
  setUp(() {
    backend = TestBackend();
    device = TestDevice();
    transports = [];
    factory = null;
    controller = CallController.withDependencies(backend, device, () {
      final transport = factory?.call() ?? TestTransport();
      transports.add(transport);
      return transport;
    });
  });
  tearDown(() async {
    controller.dispose();
    await backend.close();
    await settle();
  });
  Future<void> start(String id) async {
    await controller.observe(id);
    backend.emit(id, 'accepted');
    await settle();
  }

  test(
    'ending during token request never asks permission or creates media',
    () async {
      await start('a');
      await controller.end();
      backend.allow('a');
      await settle();
      expect(device.permissionRequests, 0);
      expect(transports, isEmpty);
      expect(controller.connecting, isFalse);
    },
  );

  test(
    'ending during permission prompt prevents media after permission is granted',
    () async {
      device.permissionPending = Completer();
      await start('a');
      backend.allow('a');
      await settle();
      expect(device.permissionRequests, 1);
      await controller.end();
      device.permissionPending!.complete();
      await settle();
      expect(transports, isEmpty);
      expect(device.active, isNull);
    },
  );

  test('end interrupts a pending connection before server response', () async {
    final pending = Completer<void>();
    factory = () => TestTransport()..connectPending = pending;
    await start('a');
    backend.allow('a');
    await settle();
    backend.transitionPending = Completer();
    final ending = controller.end();
    await settle();
    expect(transports.single.closed, isTrue);
    pending.complete();
    await settle();
    expect(transports.single.operations, ['connect']);
    expect(device.active, isNull);
    backend.transitionPending!.complete();
    await ending;
  });

  test(
    'late native start is stopped without publishing microphone or camera',
    () async {
      device.startPending = Completer();
      await start('a');
      backend.allow('a');
      await settle();
      await controller.end();
      device.startPending!.complete();
      await settle();
      expect(device.active, isNull);
      expect(transports.single.operations, ['connect']);
    },
  );

  test(
    'delayed accepted snapshots cannot revive a locally ended call',
    () async {
      await start('a');
      await controller.end();
      backend.emit('a', 'accepted');
      backend.allow('a');
      await settle();
      expect(transports, isEmpty);
      expect(controller.metadata!['state'], 'ended');
    },
  );

  test('old request cleanup cannot stop a new call session', () async {
    await start('a');
    await controller.reset();
    await start('b');
    backend.allow('b');
    await settle();
    final active = device.active;
    expect(active, isNotNull);
    backend.allow('a');
    await settle();
    expect(device.active, active);
    expect(controller.callId, 'b');
    expect(transports.single.closed, isFalse);
  });

  test('late cleanup also preserves a retry of the same call ID', () async {
    await start('a');
    final oldGrant = backend.grants.remove('a')!;
    await controller.reset();
    await start('a');
    backend.allow('a');
    await settle();
    final active = device.active;
    expect(active, isNotNull);
    oldGrant.complete(const CallGrant('wss://example.invalid', 'old-token'));
    await settle();
    expect(device.active, active);
    expect(transports.single.closed, isFalse);
  });

  test(
    'unexpected transport loss ends the call and closes local media',
    () async {
      await start('a');
      backend.allow('a');
      await settle();
      transports.single.failedConnection = true;
      transports.single.notifyListeners();
      await settle();
      expect(controller.metadata!['state'], 'disconnected');
      expect(transports.single.closed, isTrue);
      expect(device.active, isNull);
    },
  );

  test('late accept response cannot reconnect after local end', () async {
    await controller.observe('a');
    backend.emit('a', 'ringing');
    backend.transitionPending = Completer();
    final accepting = controller.accept();
    final ending = controller.end();
    backend.transitionPending!.complete();
    await Future.wait([accepting, ending]);
    await settle();
    expect(backend.grants, isEmpty);
    expect(transports, isEmpty);
  });

  test(
    'failed control operation retains the last successful microphone state',
    () async {
      await start('a');
      backend.allow('a');
      await settle();
      expect(transports.single.operations, [
        'connect',
        'mic:true',
        'camera:true',
        'speaker:false',
      ]);
      transports.single.failMic = true;
      await expectLater(controller.toggleMic(), throwsStateError);
      expect(controller.mic, isTrue);
    },
  );

  test(
    'server terminal state cancels connection before it can publish',
    () async {
      await start('a');
      backend.emit('a', 'cancelled');
      backend.allow('a');
      await settle();
      expect(transports, isEmpty);
    },
  );

  test(
    'dispose while awaiting a token has no late capture or notification',
    () async {
      await start('a');
      // Use a separate controller because tearDown owns the original one.
      final otherBackend = TestBackend();
      final other = CallController.withDependencies(otherBackend, device, () {
        fail('Disposed controller created media');
      });
      await other.observe('disposed');
      otherBackend.emit('disposed', 'accepted');
      other.dispose();
      otherBackend.allow('disposed');
      await settle();
      await otherBackend.close();
      backend.allow('a');
      await settle();
    },
  );
  test(
    'failed call end retries after navigation without reopening media',
    () async {
      await controller.observe('a');
      backend.emit('a', 'ringing');
      backend.failTransition = true;
      await expectLater(controller.end(), throwsStateError);
      expect(controller.hasPendingEnd, isTrue);
      expect(controller.metadata!['state'], 'ended');
      await controller.reset();
      backend.failTransition = false;
      await controller.syncPendingEnds();
      expect(backend.transitions, ['a:end', 'a:end']);
      expect(controller.hasPendingEnd, isFalse);
      expect(transports, isEmpty);
    },
  );

  test('queued call end is discarded after an account change', () async {
    await controller.observe('a');
    backend.emit('a', 'ringing');
    backend.failTransition = true;
    await expectLater(controller.end(), throwsStateError);
    backend.owner = 'other';
    await controller.syncPendingEnds();
    expect(backend.transitions, ['a:end']);
    expect(controller.hasPendingEnd, isFalse);
  });
}
