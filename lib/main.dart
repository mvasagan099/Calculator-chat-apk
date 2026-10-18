import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'core/widgets/privacy_mask.dart';
import 'core/theme/app_theme.dart';
import 'features/preview/preview_app.dart';
import 'features/calculator/calculator_screen.dart';
import 'features/authentication/auth_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/config/app_config.dart';
import 'core/router/app_router.dart';
import 'core/security/pin_vault.dart';
import 'core/security/lock_controller.dart';
import 'core/security/session_storage.dart';
import 'core/security/private_media_files.dart';
import 'core/services/auth_service.dart';
import 'core/services/device_settings.dart';
import 'core/services/private_session.dart';
import 'features/notifications/notification_service.dart';
import 'features/devices/device_screens.dart';
import 'providers/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );
  const store = DeviceSecretStore();
  final lock = LockController(
    PinVault(
      store,
      storageKey: AppConfig.localPreview
          ? PinVault.previewKey
          : PinVault.recordKey,
    ),
  );
  await lock.secureWindow();
  try {
    await PrivateMediaFiles().clear();
    await lock.initialize();
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'Secure storage is unavailable. Unlock this Android device and restart the app.',
            ),
          ),
        ),
      ),
    );
    return;
  }
  final device = DeviceSettings(
    await SharedPreferences.getInstance(),
    lock,
    keyPrefix: AppConfig.localPreview ? 'preview.' : '',
  );
  await device.initialize();
  if (AppConfig.localPreview) {
    runApp(
      ProviderScope(
        overrides: [lockProvider.overrideWithValue(lock)],
        child: PreviewApp(lock: lock, device: device),
      ),
    );
    return;
  }
  SupabaseClient? client;
  if (AppConfig.configured) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: SecureSessionStorage(store),
        authFlowType: AuthFlowType.pkce,
      ),
    );
    client = Supabase.instance.client;
  }
  final auth = AuthService(client, lock, store);
  await auth.initialize();
  final notifications = NotificationService(settings: device);
  if (client != null) notifications.bindClient(client);
  await notifications.initialize();
  runApp(
    ProviderScope(
      overrides: [
        lockProvider.overrideWithValue(lock),
        authServiceProvider.overrideWithValue(auth),
        deviceSettingsProvider.overrideWithValue(device),
        if (client != null) supabaseProvider.overrideWithValue(client),
      ],
      child: MessengerApp(
        auth: auth,
        device: device,
        notifications: notifications,
      ),
    ),
  );
}

class MessengerApp extends StatefulWidget {
  const MessengerApp({
    super.key,
    required this.auth,
    required this.device,
    required this.notifications,
  });
  final AuthService auth;
  final DeviceSettings device;
  final NotificationService notifications;
  @override
  State<MessengerApp> createState() => _MessengerAppState();
}

class _MessengerAppState extends State<MessengerApp> {
  late final routing = AppRouter(
    widget.auth,
    widget.device,
    widget.notifications,
  );
  @override
  void dispose() {
    routing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.device,
      widget.auth.lock,
      widget.auth,
    ]),
    builder: (context, _) => MaterialApp.router(
      title: 'Calculator',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark, amoled: widget.device.amoledMode),
      themeMode: widget.device.theme,
      routerConfig: routing.router,
      builder: (context, child) {
        final auth = widget.auth;
        Widget content;
        content = ListenableBuilder(
          listenable: routing.router.routeInformationProvider,
          builder: (context, _) {
            final path = routing.router.routeInformationProvider.value.uri.path;
            final locked =
                auth.lock.mediaPickerActive ||
                !auth.lock.unlocked ||
                !auth.lock.hasPin ||
                !auth.signedIn ||
                !auth.ownerMatches ||
                !auth.deviceAuthorized;
            final Widget surface = switch (path) {
              '/auth' => AuthScreen(auth: auth),
              '/devices' => DeviceApprovalScreen(auth: auth),
              '/recover' => AuthScreen(auth: auth, recoverPin: true),
              '/pin' =>
                auth.recentlyAuthenticated
                    ? PinSetupScreen(auth: auth)
                    : AuthScreen(auth: auth, recoverPin: true),
              '/password' => PasswordResetScreen(auth: auth),
              '/recovery-codes' =>
                auth.signedIn && auth.deviceAuthorized && auth.recoveryCodes.isNotEmpty
                    ? RecoveryCodesScreen(auth: auth)
                    : CalculatorScreen(lock: auth.lock),
              _ => CalculatorScreen(lock: auth.lock),
            };
            return PrivacyMask(
              locked: locked,
              publicSurface: auth.lock.mediaPickerActive
                  ? const ColoredBox(color: Color(0xFF101010))
                  : InheritedGoRouter(
                goRouter: routing.router,
                child: Navigator(
                  key: ValueKey('locked.$path'),
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => surface),
                ),
              ),
              child: Theme(
                data: ['/', '/auth', '/recover', '/password', '/pin', '/devices', '/recovery-codes'].contains(path)
                    ? Theme.of(context)
                    : AppTheme.messenger(switch (widget.device.messengerAppearance) {
                  ThemeMode.light => Brightness.light,
                  ThemeMode.dark => Brightness.dark,
                  ThemeMode.system => MediaQuery.platformBrightnessOf(context),
                }, widget.device.messengerTheme, amoled: widget.device.amoledMode),
                child: child ?? const SizedBox.shrink(),
              ),
            );
          },
        );
        if (auth.signedIn &&
            auth.lock.unlocked &&
            auth.lock.hasPin &&
            auth.ownerMatches &&
            auth.deviceAuthorized) {
          content = PrivateSession(
            key: ValueKey(auth.client!.auth.currentUser!.id),
            router: routing.router,
            notifications: widget.notifications,
            auth: auth,
            child: content,
          );
        }
        return Listener(
          onPointerDown: (_) => auth.lock.touch(),
          onPointerMove: (_) => auth.lock.touch(),
          child: content,
        );
      },
    ),
  );
}
