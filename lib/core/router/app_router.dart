import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../../features/devices/device_screens.dart';
import '../widgets/privacy_gate.dart';
import '../services/device_settings.dart';
import '../../features/calculator/calculator_screen.dart';
import '../../features/authentication/auth_screen.dart';
import '../../features/chats/chat_list_screen.dart';
import '../../features/messaging/chat_screen.dart';
import '../../features/contacts/contacts_screen.dart';
import '../../features/calls/call_screen.dart';
import '../../features/calls/call_history_screen.dart';
import '../../features/groups/groups_screen.dart';
import '../../features/groups/conversation_details_screen.dart';
import '../../features/status/status_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/notifications/notification_service.dart';

class AppRouter {
  AppRouter(this.auth, this.device, this.notifications) {
    router = GoRouter(
      initialLocation: '/',
      overridePlatformDefaultLocation: true,
      refreshListenable: Listenable.merge([auth, auth.lock]),
      redirect: (context, state) {
        final path = state.uri.path;
        if (path == '/' || path == '/auth' || path == '/recover' || path == '/password') return null;
        if (path == '/devices') return auth.signedIn ? null : '/auth';
        if (auth.signedIn && !auth.deviceAuthorized) return '/devices';
        if (path == '/recovery-codes') {
          return auth.signedIn && auth.recoveryCodes.isNotEmpty ? null : '/auth';
        }
        if (path == '/pin') {
          return auth.recentlyAuthenticated ? null : '/recover';
        }
        if (!auth.signedIn) return '/auth';
        if (!auth.ownerMatches) return '/recover';
        if (!auth.lock.hasPin) {
          return auth.recentlyAuthenticated ? '/pin' : '/recover';
        }
        if (!auth.lock.unlocked) return '/';
        return null;
      },
      errorBuilder: (context, state) => Theme(
        data: AppTheme.build(switch (device.theme) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => MediaQuery.platformBrightnessOf(context),
        }),
        child: CalculatorScreen(lock: auth.lock),
      ),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Theme(data: AppTheme.build(Theme.of(context).brightness), child: CalculatorScreen(lock: auth.lock)),
        ),
        GoRoute(
          path: '/auth',
          builder: (_, _) => AuthScreen(auth: auth),
        ),
        GoRoute(
          path: '/recover',
          builder: (_, _) => AuthScreen(auth: auth, recoverPin: true),
        ),
        GoRoute(
          path: '/devices',
          builder: (_, _) => DeviceApprovalScreen(auth: auth),
        ),
        GoRoute(
          path: '/device-sessions',
          builder: (_, _) => guard(DeviceSessionsScreen(auth: auth)),
        ),
        GoRoute(
          path: '/pin',
          builder: (_, _) => PinSetupScreen(auth: auth),
        ),
        GoRoute(
          path: '/password',
          builder: (_, _) => PasswordResetScreen(auth: auth),
        ),
        GoRoute(
          path: '/recovery-codes',
          builder: (_, _) => RecoveryCodesScreen(auth: auth),
        ),
        GoRoute(
          path: '/chats',
          pageBuilder: (_, state) => privatePage(state, const ChatListScreen()),
        ),
        GoRoute(
          path: '/chat/:id',
          builder: (_, s) => guard(ChatScreen(id: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/contacts',
          builder: (_, s) => guard(
            ContactsScreen(
              selectOnly: s.uri.queryParameters['select'] == 'true',
            ),
          ),
        ),
        GoRoute(
          path: '/calls',
          pageBuilder: (_, state) => privatePage(state, const CallHistoryScreen()),
        ),
        GoRoute(
          path: '/call/:id',
          builder: (_, s) => guard(CallScreen(id: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/groups',
          pageBuilder: (_, state) => privatePage(state, const GroupsScreen()),
        ),
        GoRoute(
          path: '/details/:id',
          builder: (_, s) =>
              guard(ConversationDetailsScreen(id: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/updates',
          pageBuilder: (_, state) => privatePage(state, const StatusScreen()),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (_, state) => privatePage(state,
            SettingsScreen(auth: auth, device: device, notifications: notifications),
          ),
        ),
      ],
    );
    auth.lock.addListener(openPending);
    auth.addListener(openPending);
    notifications.addListener(openPending);
  }
  final AuthService auth;
  final DeviceSettings device;
  final NotificationService notifications;
  late final GoRouter router;
  // Private pages transition only while unlocked; the public calculator is
  // never included in a private crossfade or a back-swipe screenshot.
  Page<void> privatePage(GoRouterState state, Widget screen) => CustomTransitionPage<void>(
    key: state.pageKey,
    child: guard(screen),
    transitionDuration: const Duration(milliseconds: 190),
    reverseTransitionDuration: const Duration(milliseconds: 130),
    transitionsBuilder: (context, animation, secondary, child) {
      final easing = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: easing,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, .025), end: Offset.zero).animate(easing),
          child: child,
        ),
      );
    },
  );
  Widget guard(Widget child) => Builder(builder: (context) => PrivacyGate(
    calculatorTheme: AppTheme.build(switch (device.theme) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    }),
    lock: auth.lock,
    authenticated: () =>
        auth.signedIn && auth.ownerMatches && auth.deviceAuthorized,
    authChanges: auth,
    child: child,
  ));
  bool resolving = false;
  bool _disposed = false;
  Future<void> openPending() async {
    if (_disposed || auth.lock.mediaPickerActive || !auth.lock.unlocked ||
        !auth.lock.hasPin ||
        !auth.ownerMatches ||
        !auth.deviceAuthorized ||
        !auth.signedIn ||
        notifications.pending == null ||
        resolving) {
      return;
    }
    resolving = true;
    final activity = notifications.pending!;
    notifications.pending = null;
    final owner = auth.client!.auth.currentUser!.id;
    final session = AuthService.tokenSession(auth.client!.auth.currentSession);
    final epoch = auth.lock.securityEpoch;
    bool current() => !_disposed && auth.signedIn && auth.ownerMatches && auth.deviceAuthorized &&
        auth.lock.privateActionValid(epoch) && auth.client!.auth.currentUser?.id == owner &&
        session != null && AuthService.tokenSession(auth.client!.auth.currentSession) == session;
    try {
      if (activity['recipient_id'] != null && activity['recipient_id'] != owner) return;
      // Let Calculator/PIN setup finish its normal post-unlock navigation first.
      // Otherwise a fast lookup can be overwritten by context.go('/chats').
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return;
      final id = activity['resource_id'];
      if (id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) return;
      String? path;
      if (activity['kind'] == 'call') {
        final call = await auth.client!
            .from('calls')
            .select('id')
            .eq('id', id)
            .maybeSingle();
        if (call != null && current()) {
          if (activity['action'] == 'reject') {
            await auth.client!.functions.invoke(
              'call-control',
              body: {'call_id': id, 'action': 'reject'},
            );
            path = '/calls';
          } else {
            path = '/call/$id';
          }
        }
      } else if (activity['kind'] == 'message') {
        final m = await auth.client!.rpc('notification_message_target', params: {'mid': id});
        if (m is Map && m['conversation_id'] is String) path = '/chat/${m['conversation_id']}';
      }
      if (activity['kind'] == 'missed_call') {
        final history = await auth.client!.from('call_history').select('call_id')
            .eq('call_id', id).eq('user_id', owner).maybeSingle();
        if (history != null) path = '/calls';
      }
      if (activity['kind'] == 'app_update') {
        final release = await notifications.verifyAppUpdate();
        if (release?.id == id) path = '/settings';
      }
      if (path != null && current()) {
        router.go(path);
      }
    } catch (_) {
      /* Stale/unauthorized activity remains private. */
    } finally {
      resolving = false;
      if (!_disposed && notifications.pending != null) Future.microtask(openPending);
    }
  }

  void dispose() {
    _disposed = true;
    auth.removeListener(openPending);
    auth.lock.removeListener(openPending);
    notifications.removeListener(openPending);
    router.dispose();
  }
}
