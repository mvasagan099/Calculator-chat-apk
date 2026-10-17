import '../../core/theme/app_theme.dart';
import 'package:flutter/material.dart';

/// Static, lightweight decoration; no image decoding or background animation.
class ChatBackdrop extends StatelessWidget {
  const ChatBackdrop({super.key, required this.style, required this.child});
  final String style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
      gradient: style == 'plain' && MessengerStyle.of(context).accent != null
          ? LinearGradient(colors: MessengerStyle.of(context).accent!.colors.map((color) => Color.alphaBlend(color.withValues(alpha: .10), colors.surface)).toList()) : null,
      color: style == 'dusk'
          ? (dark ? const Color(0xff242339) : const Color(0xffeeebf7))
          : colors.surface,
      ),
      child: CustomPaint(
        painter: style == 'linen'
            ? _LinenPainter(colors.primary.withValues(alpha: dark ? .12 : .07))
            : null,
        child: child,
      ),
    );
  }
}

class _LinenPainter extends CustomPainter {
  const _LinenPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double y = 12; y < size.height; y += 28) {
      for (double x = 12; x < size.width; x += 28) {
        canvas.drawCircle(Offset(x, y), 1.2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_LinenPainter oldDelegate) => color != oldDelegate.color;
}
