import 'package:flutter/material.dart';

enum MessengerTheme {
  defaultTheme,
  instagramLike,
  telegramLike,
  emerald,
  oceanBlue,
  royalPurple,
}

extension MessengerThemeLabel on MessengerTheme {
  String get label => switch (this) {
    MessengerTheme.defaultTheme => 'Default (Teal)',
    MessengerTheme.instagramLike => 'Instagram-like',
    MessengerTheme.telegramLike => 'Telegram-like',
    MessengerTheme.emerald => 'Emerald Green',
    MessengerTheme.oceanBlue => 'Ocean Blue',
    MessengerTheme.royalPurple => 'Royal Purple',
  };
}

class MessengerStyle extends ThemeExtension<MessengerStyle> {
  const MessengerStyle(
    this.variant, {
    this.bubbleRadius = 18.0,
    this.isAmoled = false,
  });

  final MessengerTheme variant;
  final double bubbleRadius;
  final bool isAmoled;

  bool get compact => variant == MessengerTheme.telegramLike;
  double get radius => variant == MessengerTheme.instagramLike
      ? 22
      : compact
      ? 14
      : bubbleRadius;

  LinearGradient? get accent => variant == MessengerTheme.instagramLike
      ? const LinearGradient(colors: [Color(0xff7338bd), Color(0xffaa246e)])
      : null;

  @override
  MessengerStyle copyWith({
    MessengerTheme? variant,
    double? bubbleRadius,
    bool? isAmoled,
  }) => MessengerStyle(
    variant ?? this.variant,
    bubbleRadius: bubbleRadius ?? this.bubbleRadius,
    isAmoled: isAmoled ?? this.isAmoled,
  );

  @override
  MessengerStyle lerp(covariant MessengerStyle? other, double t) =>
      t < .5 ? this : other ?? this;

  static MessengerStyle of(BuildContext context) =>
      Theme.of(context).extension<MessengerStyle>() ??
      const MessengerStyle(MessengerTheme.defaultTheme);
}

class AppTheme {
  static ThemeData messenger(
    Brightness brightness,
    MessengerTheme variant, {
    bool amoled = false,
  }) {
    final base = build(brightness, amoled: amoled && variant == MessengerTheme.defaultTheme);
    if (variant == MessengerTheme.defaultTheme && !amoled) return base;

    final Color seed = switch (variant) {
      MessengerTheme.defaultTheme => const Color(0xff287d73),
      MessengerTheme.instagramLike => const Color(0xff8b3cc4),
      MessengerTheme.telegramLike => const Color(0xff1684bd),
      MessengerTheme.emerald => const Color(0xff00a884),
      MessengerTheme.oceanBlue => const Color(0xff0288d1),
      MessengerTheme.royalPurple => const Color(0xff673ab7),
    };

    var colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );

    if (amoled && brightness == Brightness.dark) {
      colors = colors.copyWith(
        surface: const Color(0xFF000000),
        surfaceDim: const Color(0xFF000000),
        surfaceBright: const Color(0xFF141414),
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF0A0A0A),
        surfaceContainer: const Color(0xFF121212),
        surfaceContainerHigh: const Color(0xFF1A1A1A),
        surfaceContainerHighest: const Color(0xFF242424),
        outlineVariant: const Color(0xFF2C2C2C),
      );
    }

    final effectiveRadius = variant == MessengerTheme.instagramLike ? 22.0 : 16.0;

    return base.copyWith(
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      extensions: [MessengerStyle(variant, isAmoled: amoled)],
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: colors.surface,
        surfaceTintColor: colors.surfaceTint.withValues(alpha: 0.05),
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surfaceContainerLow,
        indicatorColor: colors.primaryContainer,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(effectiveRadius),
          borderSide: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(effectiveRadius),
          borderSide: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.25)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(effectiveRadius),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.3)),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
    );
  }

  static ThemeData build(Brightness brightness, {bool amoled = false}) {
    var colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff287d73),
      brightness: brightness,
    );

    if (amoled && brightness == Brightness.dark) {
      colors = colors.copyWith(
        surface: const Color(0xFF000000),
        surfaceDim: const Color(0xFF000000),
        surfaceBright: const Color(0xFF141414),
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF0A0A0A),
        surfaceContainer: const Color(0xFF121212),
        surfaceContainerHigh: const Color(0xFF1A1A1A),
        surfaceContainerHighest: const Color(0xFF242424),
        outlineVariant: const Color(0xFF2C2C2C),
      );
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: colors.surface,
        surfaceTintColor: colors.surfaceTint.withValues(alpha: 0.05),
        elevation: 0,
        titleTextStyle: TextStyle(
          color: colors.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.25)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colors.surfaceContainerLow,
        indicatorColor: colors.primaryContainer,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.3)),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceContainerLow,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: colors.surfaceTint.withValues(alpha: 0.04),
        elevation: 4,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: 0.35),
        space: 20,
        thickness: 0.8,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(56, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        backgroundColor: colors.inverseSurface,
        contentTextStyle: TextStyle(color: colors.onInverseSurface, fontWeight: FontWeight.w500),
      ),
    );
  }
}
