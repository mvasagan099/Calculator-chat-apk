import 'package:flutter/material.dart';

enum MessengerTheme { defaultTheme, instagramLike, telegramLike }

extension MessengerThemeLabel on MessengerTheme {
  String get label => switch (this) {
    MessengerTheme.defaultTheme => 'Default',
    MessengerTheme.instagramLike => 'Instagram-like',
    MessengerTheme.telegramLike => 'Telegram-like',
  };
}

class MessengerStyle extends ThemeExtension<MessengerStyle> {
  const MessengerStyle(this.variant);
  final MessengerTheme variant;
  bool get compact => variant == MessengerTheme.telegramLike;
  double get radius => variant == MessengerTheme.instagramLike ? 24 : compact ? 12 : 18;
  LinearGradient? get accent => variant == MessengerTheme.instagramLike
      ? const LinearGradient(colors: [Color(0xff7338bd), Color(0xffaa246e)]) : null;
  @override
  MessengerStyle copyWith({MessengerTheme? variant}) => MessengerStyle(variant ?? this.variant);
  @override
  MessengerStyle lerp(covariant MessengerStyle? other, double t) => t < .5 ? this : other ?? this;
  static MessengerStyle of(BuildContext context) => Theme.of(context).extension<MessengerStyle>() ?? const MessengerStyle(MessengerTheme.defaultTheme);
}

class AppTheme {
  static ThemeData messenger(Brightness brightness, MessengerTheme variant) {
    final base = build(brightness);
    if (variant == MessengerTheme.defaultTheme) return base;
    final colors = ColorScheme.fromSeed(
      seedColor: variant == MessengerTheme.instagramLike ? const Color(0xff8b3cc4) : const Color(0xff1684bd),
      brightness: brightness,
    );
    return base.copyWith(
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      extensions: [MessengerStyle(variant)],
      appBarTheme: base.appBarTheme.copyWith(backgroundColor: colors.surface,
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(color: colors.onSurface)),
      navigationBarTheme: NavigationBarThemeData(backgroundColor: colors.surfaceContainerLow, indicatorColor: colors.primaryContainer),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(variant == MessengerTheme.instagramLike ? 24 : 14))),
      listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4)),
    );
  }

  static ThemeData build(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff287d73),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: colors.surface,
        titleTextStyle: TextStyle(
          color: colors.onSurface,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.all(16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surfaceContainerLow,
        indicatorColor: colors.primaryContainer,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      dividerTheme: DividerThemeData(color: colors.outlineVariant.withValues(alpha: .6), space: 28),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        minimumSize: const Size(56, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      )),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface),
      ),
    );
  }
}
