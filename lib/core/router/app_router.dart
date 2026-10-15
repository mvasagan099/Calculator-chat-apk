import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';
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
        if (auth.recovery) return path == '/password' ? null : '/password';
        if (path == '/' || path == '/auth' || path == '/recover') return null;
        if (path == '/password') return '/';
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
      errorBuilder: (context, state) => CalculatorScreen(lock: auth.lock),
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => CalculatorScreen(lock: auth.lock),
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
          path: '/pin',
          builder: (_, _) => PinSetupScreen(auth: auth),
        ),
        GoRoute(
          path: '/password',
          builder: (_, _) => PasswordResetScreen(auth: auth),
        ),
        GoRoute(
          path: '/chats',
          builder: (_, _) => guard(const ChatListScreen()),
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
          builder: (_, _) => guard(const CallHistoryScreen()),
        ),
        GoRoute(
          path: '/call/:id',
          builder: (_, s) => guard(CallScreen(id: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/groups',
          builder: (_, _) => guard(const GroupsScreen()),
        ),
        GoRoute(
          path: '/details/:id',
          builder: (_, s) =>
              guard(ConversationDetailsScreen(id: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/updates',
          builder: (_, _) => guard(const StatusScreen()),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => guard(
            SettingsScreen(
              auth: auth,
              device: device,
              notifications: notifications,
            ),
          ),
        ),
      ],
    );
    auth.lock.addListener(openPending);
    notifications.addListener(openPending);
  }
  final AuthService auth;
  final DeviceSettings device;
  final NotificationService notifications;
  late final GoRouter router;
  Widget guard(Widget child) => PrivacyGate(
    lock: auth.lock,
    authenticated: () => auth.signedIn && auth.ownerMatches,
    authChanges: auth,
    child: child,
  );
  bool resolving = false;
  Future<void> openPending() async {
    if (!auth.lock.unlocked ||
        !auth.lock.hasPin ||
        !auth.ownerMatches ||
        !auth.signedIn ||
        notifications.pending == null ||
        resolving) {
      return;
    }
    resolving = true;
    final activity = notifications.pending!;
    notifications.pending = null;
    try {
      final id = activity['resource_id'];
      if (id is! String || !RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) return;
      String? path;
      if (activity['kind'] == 'call') {
        final call = await auth.client!
            .from('calls')
            .select('id')
            .eq('id', id)
            .maybeSingle();
        if (call != null) path = '/call/$id';
      } else if (activity['kind'] == 'message') {
        final m = await auth.client!
            .from('messages')
            .select('conversation_id')
            .eq('id', id)
            .maybeSingle();
        if (m != null) path = '/chat/${m['conversation_id']}';
      }
      if (activity['kind'] == 'missed_call') path = '/calls';
      if (path != null &&
          auth.lock.unlocked &&
          auth.lock.hasPin &&
          auth.ownerMatches &&
          auth.signedIn) {
        router.go(path);
      }
    } catch (_) {
      /* Stale/unauthorized activity remains private. */
    } finally {
      resolving = false;
    }
  }

  void dispose() {
    auth.lock.removeListener(openPending);
    notifications.removeListener(openPending);
    router.dispose();
  }
}
