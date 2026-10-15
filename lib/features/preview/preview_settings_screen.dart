import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/security/lock_controller.dart';
import '../../core/services/device_settings.dart';
import '../../core/widgets/actions.dart';
import 'preview_shell.dart';

class PreviewSettingsScreen extends StatelessWidget {
  const PreviewSettingsScreen({
    super.key,
    required this.lock,
    required this.device,
  });
  final LockController lock;
  final DeviceSettings device;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: device,
    builder: (context, _) => PreviewShell(
      title: 'Settings',
      index: 4,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: const PreviewAvatar(
                name: 'Preview Owner',
                color: 0xff287d73,
              ),
              title: const Text('Preview Owner'),
              subtitle: const Text('View your local profile'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/profile'),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Appearance'),
            trailing: DropdownButton<ThemeMode>(
              value: device.theme,
              onChanged: (value) {
                if (value != null) act(context, () => device.setTheme(value));
              },
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('System'),
                ),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.pin_outlined),
            title: const Text('Change PIN'),
            subtitle: const Text('Current PIN required'),
            onTap: () => context.push('/change-pin'),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Biometric unlock'),
            value: lock.biometricsEnabled,
            onChanged: (enabled) => act(context, () async {
              if (enabled) {
                final pin = await askText(
                  context,
                  'Confirm calculator PIN',
                  secret: true,
                );
                if (pin == null) return;
                if (!await lock.vault.verify(pin)) {
                  throw StateError(
                    'PIN not verified. Try again later if attempts are limited.',
                  );
                }
                if (!lock.unlocked) return;
                final local = LocalAuthentication();
                if (!(await local.canCheckBiometrics) ||
                    (await local.getAvailableBiometrics()).isEmpty) {
                  throw StateError(
                    'Enroll a biometric in Android settings first.',
                  );
                }
                if (!lock.unlocked) return;
              }
              await device.setBiometrics(enabled);
            }),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.lock_outline),
            title: const Text('Relock in background'),
            subtitle: const Text('Enabled by default'),
            value: lock.relockOnBackground,
            onChanged: (value) => act(context, () => device.setRelock(value)),
          ),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Auto-lock'),
            trailing: DropdownButton<int>(
              value: lock.timeout.inSeconds,
              items: const [
                DropdownMenuItem(value: 30, child: Text('30 sec')),
                DropdownMenuItem(value: 120, child: Text('2 min')),
                DropdownMenuItem(value: 300, child: Text('5 min')),
              ],
              onChanged: (value) {
                if (value != null) act(context, () => device.setTimeout(value));
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.calculate_outlined),
            title: const Text('Return to Calculator'),
            onTap: lock.lock,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Phase 1 local preview\n\nNo Supabase, Firebase or LiveKit requests run in this mode. PIN and display settings stay on this device. Real account management and messaging belong to the connected mode.',
            ),
          ),
        ],
      ),
    ),
  );
}
