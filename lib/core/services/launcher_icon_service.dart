import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CalculatorLauncherIcon {
  const CalculatorLauncherIcon(this.id, this.label, this.description, this.background, this.foreground);
  final String id, label, description;
  final Color background, foreground;
}

class LauncherIconService {
  LauncherIconService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('calculator_messenger/launcher_icon');
  final MethodChannel _channel;

  static const options = [
    CalculatorLauncherIcon('classic', 'Classic', 'Original calculator', Color(0xff376f69), Color(0xffe5f2ec)),
    CalculatorLauncherIcon('midnight', 'Midnight', 'Deep navy blue', Color(0xff152b47), Color(0xffdceafa)),
    CalculatorLauncherIcon('graphite', 'Graphite', 'Minimal dark gray', Color(0xff30343d), Color(0xffeff1f5)),
    CalculatorLauncherIcon('sunrise', 'Sunrise', 'Warm amber', Color(0xffa85b31), Color(0xffffe7c3)),
  ];
  static CalculatorLauncherIcon find(String id) =>
      options.firstWhere((icon) => icon.id == id, orElse: () => options.first);

  Future<String> current() async {
    if (defaultTargetPlatform != TargetPlatform.android) return 'classic';
    final id = await _channel.invokeMethod<String>('current');
    return find(id ?? 'classic').id;
  }
  Future<void> set(String id) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError('Android launcher icons only');
    }
    if (!options.any((option) => option.id == id)) throw ArgumentError.value(id, 'id');
    final updated = await _channel.invokeMethod<String>('set', {'id': id});
    if (updated != id) throw StateError('Android launcher did not confirm icon change');
  }
}

class CalculatorIconPreview extends StatelessWidget {
  const CalculatorIconPreview({super.key, required this.option, this.size = 44});
  final CalculatorLauncherIcon option;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${option.label} calculator icon',
    child: Container(
      width: size, height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .25),
        color: option.background,
      ),
      child: Icon(Icons.calculate_rounded, color: option.foreground, size: size * .67),
    ),
  );
}
