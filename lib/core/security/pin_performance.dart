import 'dart:convert';
import 'dart:developer';
import 'package:flutter/foundation.dart';

enum PinStage {
  storageRead,
  derivation,
  isolateStartup,
  nativeQueue,
  transport,
  storageWrite,
  navigation,
}

/// Opt-in developer timings only. Never accepts PINs, records, account IDs,
/// routes, verification outcomes or backend data. No production telemetry.
class PinTrace {
  PinTrace({this.onFinish}) : _clock = Stopwatch()..start();
  static const enabled =
      !kReleaseMode && bool.fromEnvironment('PIN_UNLOCK_PROFILING');
  static PinTrace? begin() => enabled ? PinTrace() : null;
  final void Function(Map<String, int>)? onFinish;
  final Stopwatch _clock;
  final _stages = <PinStage, int>{};
  bool _finished = false;

  Future<T> measure<T>(PinStage stage, Future<T> Function() operation) async {
    final timer = Stopwatch()..start();
    final task = enabled
        ? (TimelineTask()..start('calculator.${stage.name}'))
        : null;
    try {
      return await operation();
    } finally {
      record(stage, timer.elapsedMicroseconds);
      task?.finish();
    }
  }

  void record(PinStage stage, int microseconds) {
    if (!_finished) _stages[stage] = (_stages[stage] ?? 0) + microseconds;
  }

  void finish() {
    if (_finished) return;
    _finished = true;
    final timings = {
      for (final stage in PinStage.values)
        '${stage.name}_us': _stages[stage] ?? 0,
      'total_us': _clock.elapsedMicroseconds,
    };
    onFinish?.call(Map.unmodifiable(timings));
    if (enabled) debugPrint('CALCULATOR_TIMING_US ${jsonEncode(timings)}');
  }
}
