import '../../core/theme/app_theme.dart';
import 'package:flutter/material.dart';
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
  late Future<Map<String, dynamic>> future = load();
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
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final profile = s.data!['profile'], settings = s.data!['settings'];
        final device = widget.device, lock = device.lock;
        return ListView(
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
            ListTile(
              leading: PersonAvatar(
                name: profile['display_name'],
                path: profile['avatar_path'],
              ),
              title: Text(profile['display_name']),
              subtitle: Text('@${profile['username']}'),
              trailing: IconButton(
                tooltip: 'Change profile picture',
                onPressed: () => act(context, avatar),
                icon: const Icon(Icons.camera_alt_outlined),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SelectableText('Public ID: ${profile['public_id']}'),
            ),
            for (final key in ['display_name', 'about'])
              ListTile(
                title: Text(key.replaceAll('_', ' ')),
                subtitle: Text(profile[key]),
                onTap: () => act(context, () => edit(key, profile[key])),
              ),
            const Divider(),
            const ListTile(title: Text('Device privacy')),
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
            ListTile(
              title: const Text('Chat appearance'),
              subtitle: const Text('Light and dark appearance'),
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
              title: const Text('Messenger style'),
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
            const Divider(),
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
