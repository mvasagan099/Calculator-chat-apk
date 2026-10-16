import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter/services.dart';
import 'pin_performance.dart';

/// Same PBKDF2-HMAC-SHA256/256-bit output as the v1 verifier. Android's
/// maintained JCA provider executes on a dedicated native worker. Other hosts
/// use the existing Dart library in an isolate, without main-isolate yield waits.
class PinDerivation {
  static const implementation = String.fromEnvironment(
    'PIN_KDF_IMPLEMENTATION',
    defaultValue: 'native',
  );
  static const _channel = MethodChannel('calculator_messenger/pin');

  static Future<List<int>> derive(
    String pin,
    List<int> salt,
    int iterations, {
    PinTrace? trace,
  }) async {
    final total = Stopwatch()..start();
    // Keep arbitrary wrong-input accounting and nonstandard legacy salt
    // compatibility on the original Dart path. Known v1 numeric records use JCA.
    if (Platform.isAndroid &&
        implementation == 'native' &&
        RegExp(r'^[0-9]{4,12}$').hasMatch(pin) &&
        salt.length == 32) {
      // Platform failures fail closed in PinVault. Do not silently substitute
      // lower parameters or reset a verifier when a provider is unavailable.
      final result = await _channel.invokeMapMethod<String, dynamic>('derive', {
        'pin': pin,
        'salt': Uint8List.fromList(salt),
        'iterations': iterations,
      });
      final bytes = result?['bytes'];
      if (bytes is! Uint8List || bytes.length != 32) {
        throw StateError('PIN derivation unavailable');
      }
      final work = result!['derive_us'] as int;
      final queue = result['queue_us'] as int;
      trace?.record(PinStage.derivation, work);
      trace?.record(PinStage.nativeQueue, queue);
      trace?.record(
        PinStage.transport,
        (total.elapsedMicroseconds - work - queue).clamp(0, 1 << 62),
      );
      return bytes;
    }
    final submitted = Timeline.now;
    final baseline = implementation == 'dart-baseline';
    final result = await Isolate.run(() async {
      final started = Timeline.now;
      final timer = Stopwatch()..start();
      final key = await DartPbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
        pauseFrequency: baseline ? 2000 : 0,
      ).deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
      return (await key.extractBytes(), timer.elapsedMicroseconds, started);
    });
    final startup = result.$3 - submitted;
    trace?.record(PinStage.derivation, result.$2);
    trace?.record(PinStage.isolateStartup, startup);
    trace?.record(
      PinStage.transport,
      (total.elapsedMicroseconds - startup - result.$2).clamp(0, 1 << 62),
    );
    return result.$1;
  }
}
