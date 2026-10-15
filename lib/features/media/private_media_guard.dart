import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/app_providers.dart';

/// Full-screen media routes can outlive the chat beneath them. Destroy their
/// renderer on expiry/relock/background, including retained navigator routes.
class PrivateMediaGuard extends ConsumerStatefulWidget {
  const PrivateMediaGuard({super.key, required this.builder, this.expiresAt});
  final WidgetBuilder builder;
  final DateTime? expiresAt;
  @override
  ConsumerState<PrivateMediaGuard> createState() => _PrivateMediaGuardState();
}

class _PrivateMediaGuardState extends ConsumerState<PrivateMediaGuard>
    with WidgetsBindingObserver {
  late final lock = ref.read(lockProvider);
  bool closed = false;
  Timer? expiry;
  @override
  void initState() {
    super.initState();
    closed =
        !lock.unlocked ||
        (widget.expiresAt != null &&
            !widget.expiresAt!.isAfter(DateTime.now()));
    lock.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    if (!closed && widget.expiresAt != null) {
      expiry = Timer(widget.expiresAt!.difference(DateTime.now()), close);
    }
  }

  void changed() {
    if (!lock.unlocked) close();
  }

  void close() {
    if (!closed && mounted) {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      setState(() => closed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) close();
  }

  @override
  void dispose() {
    expiry?.cancel();
    lock.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => closed
      ? Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Media closed or expired')),
        )
      : widget.builder(context);
}
