// Synthetic desktop benchmark, not Android Keystore/navigation evidence.
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

Future<void> main() async {
  List<int>? reference;
  for (final baseline in [true, false]) {
    final derive = <int>[], startup = <int>[], total = <int>[];
    for (var run = 0; run < 3; run++) {
      final submitted = Timeline.now;
      final clock = Stopwatch()..start();
      final result = await Isolate.run(() async {
        final entered = Timeline.now;
        final work = Stopwatch()..start();
        final key =
            await DartPbkdf2(
              macAlgorithm: Hmac.sha256(),
              iterations: 600000,
              bits: 256,
              pauseFrequency: baseline ? 2000 : 0,
            ).deriveKey(
              secretKey: SecretKey(utf8.encode('benchmark-only')),
              nonce: List<int>.generate(32, (i) => i),
            );
        return (await key.extractBytes(), work.elapsedMicroseconds, entered);
      });
      total.add(clock.elapsedMicroseconds);
      derive.add(result.$2);
      startup.add(result.$3 - submitted);
      reference ??= result.$1;
      if (base64Encode(result.$1) != base64Encode(reference)) {
        throw StateError('Inconsistent derivation');
      }
    }
    stdout.writeln(
      jsonEncode({
        'scope': 'desktop Dart JIT synthetic isolate',
        'implementation': baseline ? 'old-default-pauses' : 'dart-no-pauses',
        'iterations': 600000,
        'derive_us': derive,
        'isolate_startup_us': startup,
        'total_us': total,
      }),
    );
  }
}
