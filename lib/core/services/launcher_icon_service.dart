import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CalculatorLauncherIcon {
  const CalculatorLauncherIcon(this.id, this.label, this.description, this.background, this.foreground, {this.assetPath});
  final String id, label, description;
  final Color background, foreground;
  final String? assetPath;
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
    CalculatorLauncherIcon('notebook', 'Notebook', 'Hand-drawn notebook calculator', Color(0xfffff9dc), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_notebook.webp'),
    CalculatorLauncherIcon('blue_gloss', 'Blue Gloss', 'Glossy blue calculator', Color(0xff0079fc), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_blue_gloss.webp'),
    CalculatorLauncherIcon('mono_tiles', 'Mono Tiles', 'Bold black and white', Color(0xffffffff), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_mono_tiles.webp'),
    CalculatorLauncherIcon('kawaii', 'Kawaii', 'Smiling pastel calculator', Color(0xffffe1ef), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_kawaii.webp'),
    CalculatorLauncherIcon('retro', 'Retro', 'Vintage pocket calculator', Color(0xffdbd1c5), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_retro.webp'),
    CalculatorLauncherIcon('cyberpunk', 'Cyberpunk', 'Vibrant cyber neon', Color(0xff51077e), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_cyberpunk.webp'),
    CalculatorLauncherIcon('neon', 'Neon', 'Electric black neon', Color(0xff09090d), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_neon.webp'),
    CalculatorLauncherIcon('pastel', 'Pastel', 'Soft colorful calculator', Color(0xffffdefb), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_pastel.webp'),
    CalculatorLauncherIcon('dark_orange', 'Dark Orange', 'Dark circles and amber equals', Color(0xff29292d), Color(0xffffffff), assetPath: 'assets/launcher_icons/ic_launcher_dark_orange.webp'),
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
      clipBehavior: Clip.antiAlias,
      child: option.assetPath == null
          ? Icon(Icons.calculate_rounded, color: option.foreground, size: size * .67)
          : Image.asset(
              option.assetPath!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (context, error, stack) =>
                  Icon(Icons.calculate_rounded, color: option.foreground, size: size * .67),
            ),
    ),
  );
}
