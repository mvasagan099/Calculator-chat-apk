import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/app_providers.dart';

class PrivateScaffold extends ConsumerWidget {
  const PrivateScaffold({
    super.key,
    required this.title,
    required this.index,
    required this.body,
    this.actions = const [],
    this.floatingActionButton,
  });

  final String title;
  final int index;
  final Widget body;
  final List<Widget> actions;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.read(lockProvider);
    final colors = Theme.of(context).colorScheme;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: colors.surfaceContainerLow,
        systemNavigationBarIconBrightness: Theme.of(context).brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): lock.quickLock,
          const SingleActivator(LogicalKeyboardKey.keyL, control: true, alt: true): lock.quickLock,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.2),
              ),
              actions: [
                ...actions,
                IconButton(
                  tooltip: 'Quick Lock (Return to Calculator)',
                  onPressed: lock.quickLock,
                  icon: const Icon(Icons.calculate_outlined),
                ),
              ],
            ),
            body: body,
            floatingActionButton: floatingActionButton,
            bottomNavigationBar: NavigationBar(
              height: 68,
              animationDuration: const Duration(milliseconds: 200),
              selectedIndex: index,
              elevation: 0,
              backgroundColor: colors.surfaceContainerLow,
              indicatorColor: colors.primaryContainer,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              onDestinationSelected: (i) => context.go(
                ['/chats', '/updates', '/calls', '/groups', '/settings'][i],
              ),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline_rounded),
                  selectedIcon: Icon(Icons.chat_bubble_rounded),
                  label: 'Chats',
                ),
                NavigationDestination(
                  icon: Icon(Icons.auto_awesome_outlined),
                  selectedIcon: Icon(Icons.auto_awesome),
                  label: 'Updates',
                ),
                NavigationDestination(
                  icon: Icon(Icons.call_outlined),
                  selectedIcon: Icon(Icons.call),
                  label: 'Calls',
                ),
                NavigationDestination(
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups),
                  label: 'Groups',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune),
                  label: 'Settings',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AvatarCacheEntry {
  const _AvatarCacheEntry(this.url, this.expiresAt);
  final String url;
  final DateTime expiresAt;
}

/// In-memory cache for Supabase Storage signed URLs.
/// Eliminates redundant network requests when scrolling lists or rebuilding avatars.
class AvatarCache {
  static final Map<String, _AvatarCacheEntry> _cache = {};

  static String? get(String key) {
    final entry = _cache[key];
    if (entry != null && DateTime.now().isBefore(entry.expiresAt)) {
      return entry.url;
    }
    return null;
  }

  static void set(String key, String url, {Duration ttl = const Duration(minutes: 9)}) {
    _cache[key] = _AvatarCacheEntry(url, DateTime.now().add(ttl));
  }

  static void clear() => _cache.clear();
}

class PersonAvatar extends ConsumerWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.path,
    this.bucket = 'avatars',
    this.radius = 22.0,
    this.showOnline = false,
    this.isOnline = false,
  });

  final String name, bucket;
  final String? path;
  final double radius;
  final bool showOnline;
  final bool isOnline;

  static const _avatarPalette = [
    Color(0xFFE57373), Color(0xFFF06292), Color(0xFFBA68C8), Color(0xFF9575CD),
    Color(0xFF7986CB), Color(0xFF64B5F6), Color(0xFF4FC3F7), Color(0xFF4DD0E1),
    Color(0xFF4DB6AC), Color(0xFF81C784), Color(0xFFAED581), Color(0xFFFFB74D),
    Color(0xFFFF8A65), Color(0xFFA1887F), Color(0xFF90A4AE),
  ];

  Color _colorForName(String str) {
    if (str.isEmpty) return _avatarPalette.first;
    final hash = str.codeUnits.fold<int>(0, (prev, elem) => prev + elem);
    return _avatarPalette[hash % _avatarPalette.length];
  }

  Widget _buildFallback(BuildContext context) {
    final bg = _colorForName(name);
    final char = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.22),
        shape: BoxShape.circle,
        border: Border.all(color: bg.withValues(alpha: 0.35), width: 1.2),
      ),
      alignment: Alignment.center,
      child: Text(
        char,
        style: TextStyle(
          color: bg,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.9,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget avatarWidget;

    if (path == null || path!.trim().isEmpty) {
      avatarWidget = _buildFallback(context);
    } else {
      final cacheKey = '$bucket:$path';
      final cachedUrl = AvatarCache.get(cacheKey);

      if (cachedUrl != null) {
        avatarWidget = ClipOval(
          child: Image.network(
            cachedUrl,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            cacheWidth: (radius * 2.5).toInt(),
            cacheHeight: (radius * 2.5).toInt(),
            errorBuilder: (_, _, _) => _buildFallback(context),
          ),
        );
      } else {
        avatarWidget = FutureBuilder<String>(
          future: ref
              .read(supabaseProvider)
              .storage
              .from(bucket)
              .createSignedUrl(path!, 600)
              .then((url) {
            AvatarCache.set(cacheKey, url);
            return url;
          }),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return ClipOval(
                child: Image.network(
                  snapshot.data!,
                  width: radius * 2,
                  height: radius * 2,
                  fit: BoxFit.cover,
                  cacheWidth: (radius * 2.5).toInt(),
                  cacheHeight: (radius * 2.5).toInt(),
                  errorBuilder: (_, _, _) => _buildFallback(context),
                ),
              );
            }
            return _buildFallback(context);
          },
        );
      }
    }

    if (!showOnline) return avatarWidget;

    return Stack(
      children: [
        avatarWidget,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: radius * 0.65,
            height: radius * 0.65,
            decoration: BoxDecoration(
              color: isOnline ? const Color(0xFF4CAF50) : const Color(0xFF9E9E9E),
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
