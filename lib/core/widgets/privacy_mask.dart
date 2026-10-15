import 'package:flutter/material.dart';

/// Masks the entire private navigator, including dialogs and imperative media
/// routes. Offstage content is excluded from focus, painting and semantics.
class PrivacyMask extends StatelessWidget {
  const PrivacyMask({
    super.key,
    required this.locked,
    required this.publicSurface,
    required this.child,
  });
  final bool locked;
  final Widget publicSurface, child;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeFocus(
        excluding: locked,
        child: Offstage(offstage: locked, child: child),
      ),
      if (locked) Positioned.fill(child: publicSurface),
    ],
  );
}
