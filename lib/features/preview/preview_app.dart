import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/security/lock_controller.dart';
import '../../core/services/device_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/privacy_gate.dart';
import '../../core/widgets/privacy_mask.dart';
import '../calculator/calculator_screen.dart';
import 'local_pin_setup_screen.dart';
import 'preview_fixtures.dart';
import 'preview_conversation_screen.dart';
import 'preview_lists_screen.dart';
import 'preview_settings_screen.dart';

/// Isolated Phase 1 UI. There is deliberately no Supabase/Auth client here.
class PreviewApp extends StatefulWidget {
  const PreviewApp({super.key, required this.lock, required this.device});
  final LockController lock;
  final DeviceSettings device;
  @override
  State<PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<PreviewApp> {
  String? pending;
  late final router = GoRouter(
    initialLocation: widget.lock.hasPin ? '/' : '/setup',
    overridePlatformDefaultLocation: true,
    refreshListenable: widget.lock,
    redirect: (context, state) {
      final path = state.uri.path;
      if (!widget.lock.hasPin) return path == '/setup' ? null : '/setup';
      if (path == '/setup' || path == '/auth') return '/';
      if (path == '/' || path == '/recover') return null;
      if (!widget.lock.unlocked) {
        // Route IDs are retained in memory; no fixture content is rendered
        // until the PIN gate is open. A cold launch always starts at calculator.
        pending = state.uri.toString();
        return '/';
      }
      if (path == '/chats' && pending != null) {
        final destination = pending!;
        pending = null;
        return destination == '/chats' ? null : destination;
      }
      return null;
    },
    errorBuilder: (_, _) => CalculatorScreen(lock: widget.lock),
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => CalculatorScreen(lock: widget.lock),
      ),
      GoRoute(
        path: '/setup',
        builder: (_, _) => LocalPinSetupScreen(lock: widget.lock),
      ),
      GoRoute(
        path: '/recover',
        builder: (_, _) => const Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This local preview has no recovery bypass. If you forget its PIN, clear the app’s data in Android settings. This removes app-local settings, sessions and caches. Connected accounts use their own authenticated recovery flow.',
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/chats',
        builder: (_, _) => guard(const PreviewChatsScreen()),
      ),
      GoRoute(
        path: '/contacts',
        builder: (_, _) => guard(const PreviewChatsScreen(selecting: true)),
      ),
      GoRoute(
        path: '/updates',
        builder: (_, _) => guard(const PreviewUpdatesScreen()),
      ),
      GoRoute(
        path: '/calls',
        builder: (_, _) => guard(const PreviewCallsScreen()),
      ),
      GoRoute(
        path: '/groups',
        builder: (_, _) => guard(const PreviewChatsScreen(groups: true)),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => guard(
          PreviewSettingsScreen(lock: widget.lock, device: widget.device),
        ),
      ),
      GoRoute(
        path: '/profile',
        builder: (_, _) => guard(const PreviewProfileScreen()),
      ),
      GoRoute(
        path: '/change-pin',
        builder: (_, _) =>
            guard(LocalPinSetupScreen(lock: widget.lock, changing: true)),
      ),
      GoRoute(
        path: '/chat/:id',
        builder: (_, state) {
          final conversation = previewConversation(state.pathParameters['id']!);
          return guard(
            conversation == null
                ? const Scaffold(
                    body: Center(
                      child: Text('Preview conversation unavailable'),
                    ),
                  )
                : PreviewConversationScreen(conversation: conversation),
          );
        },
      ),
      GoRoute(
        path: '/person/:id',
        builder: (_, state) => guard(
          PreviewProfileScreen(
            person: previewConversation(state.pathParameters['id']!),
          ),
        ),
      ),
      GoRoute(
        path: '/status/:id',
        builder: (_, state) {
          final conversation = previewConversation(state.pathParameters['id']!);
          return guard(
            conversation == null
                ? const Scaffold(
                    body: Center(child: Text('Preview status unavailable')),
                  )
                : PreviewStatusScreen(conversation: conversation),
          );
        },
      ),
    ],
  );

  Widget guard(Widget child) => PrivacyGate(
    lock: widget.lock,
    authenticated: () => true,
    authChanges: widget.lock,
    child: child,
  );
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.lock, widget.device]),
    builder: (context, _) => MaterialApp.router(
      title: 'Calculator',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark),
      themeMode: widget.device.theme,
      routerConfig: router,
      builder: (context, child) => Listener(
        onPointerDown: (_) => widget.lock.touch(),
        onPointerMove: (_) => widget.lock.touch(),
        child: ListenableBuilder(
          listenable: router.routeInformationProvider,
          builder: (context, _) {
            final setup = !widget.lock.hasPin;
            final recovering =
                router.routeInformationProvider.value.uri.path == '/recover';
            final publicSurface = setup
                ? LocalPinSetupScreen(lock: widget.lock)
                : recovering
                ? const Scaffold(
                    body: SafeArea(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No local PIN recovery bypass is provided. Clear app data in Android settings to reset this preview. This also removes any locally stored connected session and cache.',
                        ),
                      ),
                    ),
                  )
                : CalculatorScreen(lock: widget.lock);
            return PrivacyMask(
              locked: !widget.lock.unlocked || setup,
              publicSurface: InheritedGoRouter(
                goRouter: router,
                child: Navigator(
                  key: ValueKey('public.$setup.$recovering'),
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => publicSurface),
                ),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
        ),
      ),
    ),
  );
}
