import 'dart:io';
import '../../core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/services/launcher_icon_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/services/private_media_access.dart';
import 'package:local_auth/local_auth.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/device_settings.dart';
import '../../core/widgets/actions.dart';
import '../../core/widgets/private_scaffold.dart';
import '../../providers/app_providers.dart';
import '../calls/call_screen.dart';
import '../notifications/notification_service.dart';
import '../messaging/starred_messages_screen.dart';
import '../vault/vault_screen.dart';
import 'storage_manager_screen.dart';
import 'diagnostics_screen.dart';
import '../notifications/app_update_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.device,
    required this.notifications,
  });
  final AuthService auth;
  final DeviceSettings device;
  final NotificationService notifications;
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final LauncherIconService _launcher = LauncherIconService();
  late Future<String> _launcherIcon = _launcher.current().catchError((Object _) => 'classic');
  late Future<Map<String, dynamic>> future = load();

  Future<void> selectCalculatorIcon() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Choose calculator icon',
                        style: Theme.of(sheetContext).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text('${LauncherIconService.options.length} icons available',
                        style: Theme.of(sheetContext).textTheme.bodyMedium),
                    const SizedBox(height: 4),
                    const Text('Changes the Android home-screen icon only. Your calculator PIN and private chats are unchanged.'),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<String>(
                  future: _launcherIcon,
                  builder: (context, current) => GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: MediaQuery.sizeOf(sheetContext).width >= 600 ? 4 : 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      childAspectRatio: .85,
                    ),
                    itemCount: LauncherIconService.options.length,
                    itemBuilder: (_, index) {
                      final option = LauncherIconService.options[index];
                      final active = current.data == option.id;
                      return Card(
                        margin: EdgeInsets.zero,
                        color: active ? Theme.of(sheetContext).colorScheme.primaryContainer : null,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => Navigator.of(sheetContext).pop(option.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                            child: Column(
                              children: [
                                Expanded(child: Center(
                                  child: CalculatorIconPreview(option: option, size: 66),
                                )),
                                const SizedBox(height: 5),
                                Text(option.label, maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(sheetContext).textTheme.labelMedium),
                                if (active)
                                  Icon(Icons.check_circle_rounded,
                                      size: 16,
                                      color: Theme.of(sheetContext).colorScheme.primary)
                                else
                                  const SizedBox(height: 16),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await act(context, () async {
      if (!widget.auth.signedIn || !widget.auth.deviceAuthorized || !widget.auth.lock.unlocked) {
        throw StateError('Unlock the private space before changing its icon');
      }
      await _launcher.set(selected);
      if (mounted) setState(() => _launcherIcon = Future.value(selected));
    });
  }

  Future<Map<String, dynamic>> load() async {
    final c = ref.read(supabaseProvider), id = ref.read(messengerProvider).uid;
    return {
      'profile': await c.from('profiles').select().eq('id', id).single(),
      'settings': await c
          .from('user_settings')
          .select()
          .eq('user_id', id)
          .single(),
      'blocks': await c
          .from('user_blocks')
          .select('*,profiles!user_blocks_blocked_id_fkey(*)')
          .eq('blocker_id', id),
    };
  }

  Future<void> preference(String key, Object value) async {
    await ref
        .read(supabaseProvider)
        .from('user_settings')
        .update({key: value})
        .eq('user_id', ref.read(messengerProvider).uid);
    if (mounted) setState(() => future = load());
  }

  Future<void> edit(String key, String value) async {
    final result = await askText(
      context,
      'Edit ${key.replaceAll('_', ' ')}',
      initial: value,
    );
    if (result == null) return;
    await ref
        .read(supabaseProvider)
        .from('profiles')
        .update({
          key: result,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', ref.read(messengerProvider).uid);
    if (mounted) setState(() => future = load());
  }

  Future<void> avatar() async {
    final access = PrivateMediaAccess(ref.read(lockProvider),
        ref.read(authServiceProvider), ref.read(supabaseProvider), isCurrent: () => mounted);
    final photo = await access.pick('image', () => ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 800,
    ));
    if (photo == null) return;
    if (!mounted) return;
    access.check();
    final bytes = await photo.readAsBytes();
    if (!mounted) return;
    access.check();
    if (bytes.length > 5 * 1024 * 1024) {
      throw const FormatException('Avatar must be under 5 MB');
    }
    final c = ref.read(supabaseProvider);
    final path = '${c.auth.currentUser!.id}/${const Uuid().v4()}.jpg';
    await c.storage
        .from('avatars')
        .uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(contentType: 'image/jpeg'),
        );
    if (!mounted) return;
    access.check();
    final check = await c.functions.invoke(
      'validate-media',
      body: {'bucket': 'avatars', 'path': path},
    );
    if (!mounted) return;
    access.check();
    if (check.status != 200) throw StateError('Image rejected');
    await c
        .from('profiles')
        .update({'avatar_path': path})
        .eq('id', c.auth.currentUser!.id);
    if (mounted) setState(() => future = load());
  }

  Future<void> logout() async {
    final call = ref.read(callProvider),
        repository = ref.read(messengerProvider),
        client = ref.read(supabaseProvider);
    final auth = widget.auth, notifications = widget.notifications;
    // Capture dependencies before locking: the private route is disposed by
    // the gate immediately. Remove the account session before network cleanup.
    final endingCall = call.end().catchError((Object _) {});
    final signingOut = auth.signOut().catchError((Object _) {});
    await endingCall;
    await call.reset();
    try {
      await notifications.unregister(client);
    } catch (_) {
      /* Offline token revocation retries at provider level. */
    }
    await repository.clearLocal();
    try {
      await signingOut;
    } catch (_) {
      /* Auth removes the local session before attempting remote revocation. */
    }
  }

  Widget _buildSkeletonLoading(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? Colors.white12 : Colors.black12;

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          height: 140,
          decoration: BoxDecoration(
            color: baseColor,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          height: 160,
          decoration: BoxDecoration(
            color: baseColor,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: baseColor,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PrivateScaffold(
    title: 'Settings',
    index: 4,
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, s) {
        if (s.hasError) {
          return LoadError(retry: () => setState(() => future = load()));
        }
        if (!s.hasData) return _buildSkeletonLoading(context);
        final profile = s.data!['profile'], settings = s.data!['settings'];
        final device = widget.device, lock = device.lock;
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            ListenableBuilder(listenable: widget.notifications, builder: (context, _) {
              final release = widget.notifications.availableUpdate;
              return release == null ? const SizedBox.shrink() : ListTile(
                title: const Text('Update to the latest version'),
                subtitle: Text('Android build ${release.build}'),
                onTap: () => act(context, () async {
                  final current = await widget.notifications.verifyAppUpdate();
                  if (current?.id != release.id || !mounted || !widget.auth.lock.unlocked ||
                      !widget.auth.deviceAuthorized || !widget.auth.ownerMatches || !widget.auth.signedIn) {
                    return;
                  }
                  if (!await launchUrl(Uri.parse(current!.url), mode: LaunchMode.externalApplication)) {
                    throw StateError('Unable to open the verified release');
                  }
                }),
              );
            }),
            Card(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        PersonAvatar(
                          name: profile['display_name'],
                          path: profile['avatar_path'],
                          radius: 30,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile['display_name'] ?? 'User',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '@${profile['username']}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'ID: ${profile['public_id']}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton.filledTonal(
                          tooltip: 'Change profile picture',
                          onPressed: () => act(context, avatar),
                          icon: const Icon(Icons.camera_alt_outlined, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Display name'),
                      subtitle: Text(profile['display_name'] ?? ''),
                      trailing: const Icon(Icons.edit_outlined, size: 18),
                      onTap: () => act(context, () => edit('display_name', profile['display_name'])),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bio / About'),
                      subtitle: Text(profile['about'] ?? 'Hey there! I am using Calculator Messenger'),
                      trailing: const Icon(Icons.edit_outlined, size: 18),
                      onTap: () => act(context, () => edit('about', profile['about'] ?? '')),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Security & device', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              title: const Text('Generate new recovery codes'),
              subtitle: const Text('Requires your password; replaces all old codes'),
              onTap: () => act(context, () async {
                final password = await askText(context, 'Confirm account password', secret: true);
                if (password == null) return;
                await widget.auth.rotateRecoveryCodes(password);
                if (context.mounted) context.push('/recovery-codes');
              }),
            ),
            ListTile(
              leading: const Icon(Icons.calculate_outlined),
              title: const Text('Return to Calculator'),
              onTap: lock.lock,
            ),
            ListTile(
              title: const Text('Change or recover PIN'),
              subtitle: const Text('Requires account password again'),
              onTap: () => context.push('/recover'),
            ),
            SwitchListTile(
              title: const Text('Relock on background'),
              value: lock.relockOnBackground,
              onChanged: (v) => act(context, () async {
                await device.setRelock(v);
                if (mounted) setState(() {});
              }),
            ),
            ListTile(
              title: const Text('Relock after inactivity'),
              trailing: DropdownButton<int>(
                value: lock.timeout.inSeconds,
                items: [
                  for (final seconds in [30, 60, 120, 300, 900])
                    DropdownMenuItem(
                      value: seconds,
                      child: Text(
                        seconds < 60
                            ? '$seconds seconds'
                            : '${seconds ~/ 60} minutes',
                      ),
                    ),
                ],
                onChanged: (s) => act(context, () async {
                  if (s != null) await device.setTimeout(s);
                  if (mounted) setState(() {});
                }),
              ),
            ),
            SwitchListTile(
              title: const Text('Require biometrics after PIN'),
              value: lock.biometricsEnabled,
              onChanged: (v) => act(context, () async {
                if (v) {
                  final pin = await askText(
                    context,
                    'Confirm calculator PIN',
                    secret: true,
                  );
                  if (pin == null || !await lock.vault.verify(pin)) {
                    throw StateError('PIN not verified');
                  }
                  final available = await LocalAuthentication()
                      .getAvailableBiometrics();
                  if (available.isEmpty) {
                    throw StateError(
                      'Enroll biometrics in Android settings first',
                    );
                  }
                  if (!lock.unlocked) return;
                }
                await device.setBiometrics(v);
                if (mounted) setState(() {});
              }),
            ),
            SwitchListTile(
              title: const Text('Shake to lock'),
              subtitle: const Text('Instantly return to calculator when shaken'),
              value: device.shakeToLock,
              onChanged: (v) => act(context, () async {
                await device.setShakeToLock(v);
                if (mounted) setState(() {});
              }),
            ),
            SwitchListTile(
              title: const Text('Quick lock shortcut'),
              subtitle: const Text('Escape or Ctrl+Alt+L immediately returns to calculator'),
              value: device.quickLockShortcut,
              onChanged: (v) => act(context, () async {
                await device.setQuickLockShortcut(v);
                if (mounted) setState(() {});
              }),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text('Personalization & Themes', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.apps_rounded),
                    title: const Text('Calculator app icon'),
                    subtitle: const Text('Choose from 13 calculator styles'),
                    trailing: FutureBuilder<String>(future: _launcherIcon, builder: (context, state) {
                      final selected = LauncherIconService.find(state.data ?? 'classic');
                      return CalculatorIconPreview(option: selected, size: 38);
                    }),
                    onTap: selectCalculatorIcon,
                  ),
                  ListTile(
                    leading: const Icon(Icons.brightness_4_outlined),
                    title: const Text('Chat appearance'),
                    subtitle: const Text('Light, dark, or follow system theme'),
                    trailing: DropdownButton<ThemeMode>(
                      value: device.messengerAppearance,
                      items: [
                        for (final mode in ThemeMode.values)
                          DropdownMenuItem(value: mode, child: Text(mode.name)),
                      ],
                      onChanged: (mode) => act(context, () async {
                        if (mode != null) await device.setMessengerAppearance(mode);
                        if (mounted) setState(() {});
                      }),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Messenger style'),
                    subtitle: Text(device.messengerTheme.label),
                    trailing: DropdownButton<MessengerTheme>(
                      value: device.messengerTheme,
                      items: [for (final style in MessengerTheme.values)
                        DropdownMenuItem(value: style, child: Text(style.label))],
                      onChanged: (style) => act(context, () async {
                        if (style != null) await device.setMessengerTheme(style);
                        if (mounted) setState(() {});
                      }),
                    ),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.dark_mode_outlined),
                    title: const Text('AMOLED pure black'),
                    subtitle: const Text('Pitch black surfaces for OLED screens and battery savings'),
                    value: device.amoledMode,
                    onChanged: (v) => act(context, () async {
                      await device.setAmoledMode(v);
                      if (mounted) setState(() {});
                    }),
                  ),
                ],
              ),
            ),
            ListTile(
              title: const Text('Devices and sessions'),
              leading: const Icon(Icons.devices),
              onTap: () => context.push('/device-sessions'),
            ),
            const ListTile(
              title: Text('End-to-end encryption'),
              subtitle: Text(
                'Not enabled. Private chats and media are accessible to the server.',
              ),
            ),
            const ListTile(title: Text('Account privacy')),
            SwitchListTile(
              title: const Text('Read receipts'),
              value: settings['read_receipts'],
              onChanged: (v) =>
                  act(context, () => preference('read_receipts', v)),
            ),
            SwitchListTile(
              title: const Text('Share last seen'),
              value: settings['last_seen_visible'],
              onChanged: (v) =>
                  act(context, () => preference('last_seen_visible', v)),
            ),
            SwitchListTile(
              title: const Text('Share online status'),
              value: settings['online_visible'],
              onChanged: (value) =>
                  act(context, () => preference('online_visible', value)),
            ),
            for (final entry in {
              'photo_privacy': 'Profile photo visibility',
              'invitation_privacy': 'Group invitations',
            }.entries)
              ListTile(
                title: Text(entry.value),
                trailing: DropdownButton<String>(
                  value: settings[entry.key],
                  items: [
                    for (final value in ['everyone', 'contacts', 'nobody'])
                      DropdownMenuItem(value: value, child: Text(value)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      act(context, () => preference(entry.key, value));
                    }
                  },
                ),
              ),
            SwitchListTile(
              title: const Text('Share updates with contacts'),
              value: settings['status_privacy'] == 'contacts',
              onChanged: (v) => act(
                context,
                () => preference('status_privacy', v ? 'contacts' : 'nobody'),
              ),
            ),
            SwitchListTile(
              title: const Text('Notifications'),
              subtitle: Text(
                widget.notifications.available
                    ? 'Always generic: “New activity”'
                    : 'Firebase is not configured in this build',
              ),
              value: settings['notifications'],
              onChanged: !widget.notifications.available
                  ? null
                  : (v) => act(context, () async {
                      if (v) {
                        await widget.notifications.register(
                          ref.read(supabaseProvider),
                          request: true,
                        );
                      } else {
                        await widget.notifications.unregister(
                          ref.read(supabaseProvider),
                        );
                      }
                      await preference('notifications', v);
                    }),
            ),
            ListTile(
              title: const Text('Notification privacy'),
              subtitle: Text(device.notificationPrivacy.label),
              trailing: DropdownButton<NotificationPrivacy>(
                value: device.notificationPrivacy,
                items: [
                  for (final p in NotificationPrivacy.values)
                    DropdownMenuItem(value: p, child: Text(p.label)),
                ],
                onChanged: (p) => act(context, () async {
                  if (p != null) await device.setNotificationPrivacy(p);
                  if (mounted) setState(() {});
                }),
              ),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Messages & Folders', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.star_outline),
              title: const Text('Starred messages'),
              subtitle: const Text('View and manage all saved messages across chats'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StarredMessagesScreen()),
              ),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Private File Vault', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: const Text('Private file vault'),
              subtitle: const Text('Encrypted local storage for photos, videos, and documents'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const VaultScreen()),
              ),
            ),
            SwitchListTile(
              title: const Text('Biometric lock for vault'),
              subtitle: const Text('Require fingerprint / face scan to open private vault'),
              value: device.vaultBiometricsEnabled,
              onChanged: (val) => act(context, () async {
                await device.setVaultBiometrics(val);
                if (mounted) setState(() {});
              }),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Storage & Media', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.pie_chart_outline),
              title: const Text('Storage manager'),
              subtitle: const Text('Review space breakdown, clean cache and large files'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const StorageManagerScreen()),
              ),
            ),
            // Keep recovery details off the chat list. Never discard the
            // encrypted database or promise offline sends in online-only mode.
            if (ref.read(messengerProvider).onlineOnly)
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('Local storage recovery'),
                subtitle: const Text(
                  'Encrypted drafts preserved · Offline messaging unavailable',
                ),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Local storage needs recovery'),
                    content: Text(
                      'Recovery stage: ${ref.read(messengerProvider).cacheRecoveryStage ?? 'unknown'}. '
                      'The encrypted cache could not be opened. Your existing '
                      'encrypted drafts have been preserved. Chats can use '
                      'server data, but new sends need a working connection. '
                      'Do not clear app data or uninstall if you need to '
                      'recover unsent messages.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.high_quality_outlined),
              title: const Text('Media upload compression'),
              subtitle: Text(
                device.mediaQuality == 'original'
                    ? 'Original (no compression)'
                    : device.mediaQuality == 'medium'
                    ? 'Standard (720p / 65% quality)'
                    : 'Optimized (1080p / 80% quality)',
              ),
              onTap: () async {
                final chosen = await showDialog<String>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('Outgoing media quality'),
                    children: [
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, 'optimized'),
                        child: const Text('Optimized (1080p / 80% quality - Recommended)'),
                      ),
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, 'medium'),
                        child: const Text('Standard (720p / 65% quality - Faster)'),
                      ),
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, 'original'),
                        child: const Text('Original (No compression - Full file size)'),
                      ),
                    ],
                  ),
                );
                if (chosen != null && mounted) {
                  await device.setMediaQuality(chosen);
                  setState(() {});
                }
              },
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Diagnostics & App Version', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: const Text('Connection diagnostics'),
              subtitle: const Text('Test connectivity to auth, database, realtime, and media storage'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ConnectionDiagnosticsScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('App version & updates'),
              subtitle: const Text('Version 1.0.0 (Build 1) · Tap to check updates'),
              onTap: () => act(context, () async {
                final update = await widget.notifications.verifyAppUpdate();
                if (!context.mounted) return;
                if (update != null) {
                  await showDialog<void>(
                    context: context,
                    barrierDismissible: !update.isUnsupported,
                    builder: (_) => AppUpdateDialog(update: update),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('You are on the latest verified release')),
                  );
                }
              }),
            ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text('Chat backup & restore', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('Create encrypted backup'),
              subtitle: const Text('Password-protected AES-256 backup of chat history'),
              onTap: () => act(context, () async {
                final password = await askText(context, 'Set backup password', secret: true);
                if (password == null || password.trim().isEmpty) return;
                if (!context.mounted) return;
                final confirm = await askText(context, 'Confirm backup password', secret: true);
                if (confirm != password) throw StateError('Passwords do not match');
                final backupJson = await ref.read(messengerProvider).exportBackup(password);
                final dir = await getTemporaryDirectory();
                final dateStr = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
                final file = File('${dir.path}/chat_backup_$dateStr.enc');
                await file.writeAsString(backupJson);
                await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'Calculator Messenger encrypted backup'));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Encrypted chat backup created successfully')),
                  );
                }
              }),
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('Restore from backup'),
              subtitle: const Text('Merge encrypted backup without overwriting pending unsent data'),
              onTap: () => act(context, () async {
                final result = await FilePicker.pickFiles(type: FileType.any);
                if (result.isEmpty || result.first.path == null) return;
                final file = File(result.first.path!);
                final backupJson = await file.readAsString();
                if (!context.mounted) return;
                final password = await askText(context, 'Enter backup password', secret: true);
                if (password == null || password.trim().isEmpty) return;
                final restored = await ref.read(messengerProvider).importBackup(password, backupJson);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Restored ${restored.conversationCount} conversations and ${restored.messageCount} messages. Offline queue preserved.')),
                  );
                  setState(() => future = load());
                }
              }),
            ),
            const Divider(),
            const ListTile(title: Text('Blocked users')),
            for (final block in s.data!['blocks'])
              ListTile(
                title: Text(block['profiles']['display_name']),
                trailing: TextButton(
                  onPressed: () => act(context, () async {
                    await ref
                        .read(supabaseProvider)
                        .from('user_blocks')
                        .delete()
                        .eq('blocker_id', ref.read(messengerProvider).uid)
                        .eq('blocked_id', block['blocked_id']);
                    if (mounted) setState(() => future = load());
                  }),
                  child: const Text('Unblock'),
                ),
              ),
            ListTile(
              title: const Text('Clear local cache and unsent messages'),
              subtitle: const Text('Server messages remain in your account'),
              onTap: () => act(context, () async {
                final confirmation = await askText(
                  context,
                  'Type CLEAR to discard local cache and unsent messages',
                );
                if (confirmation == 'CLEAR') {
                  await ref.read(messengerProvider).clearLocal();
                  if (context.mounted) context.go('/chats');
                }
              }),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Log out'),
              onTap: () => act(context, logout),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever),
              title: const Text('Delete account'),
              subtitle: const Text(
                'Permanently removes your profile, owned media and message contents',
              ),
              onTap: () => act(context, () async {
                final confirmation = await askText(
                  context,
                  'Type DELETE to permanently delete your account',
                );
                if (confirmation != 'DELETE' || !context.mounted) return;
                final password = await askText(
                  context,
                  'Confirm account password',
                  secret: true,
                );
                if (password == null || !context.mounted) return;
                final account = widget.auth.client!.auth.currentUser!.id;
                final repository = ref.read(messengerProvider);
                await ref.read(callProvider).end();
                final result = await ref
                    .read(supabaseProvider)
                    .functions
                    .invoke('delete-account', body: {'password': password});
                if (result.status != 200) {
                  throw StateError('Account could not be deleted');
                }
                await repository.clearLocal();
                await widget.auth.store.delete('device.id.$account');
                await widget.auth.lock.vault.clear();
                await widget.auth.store.delete('pin.owner');
                widget.auth.lock.hasPin = false;
                widget.auth.lock.lock();
                await widget.auth.client!.auth.signOut(
                  scope: SignOutScope.local,
                );
                if (context.mounted) context.go('/');
              }),
            ),
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Messages use authenticated access and transport encryption. End-to-end encryption is not implemented. Android can show this app in settings and system interfaces.',
              ),
            ),
          ],
        );
      },
    ),
  );
}
