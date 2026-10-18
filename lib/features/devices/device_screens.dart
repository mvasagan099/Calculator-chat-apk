import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/services/auth_service.dart';
import '../../core/widgets/actions.dart';

class DeviceApprovalScreen extends StatefulWidget {
  const DeviceApprovalScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<DeviceApprovalScreen> createState() => _DeviceApprovalScreenState();
}

class _DeviceApprovalScreenState extends State<DeviceApprovalScreen> {
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    // Poll every 3 seconds as a robust fallback for realtime approval notifications
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      await widget.auth.refreshDeviceAccess();
      if (mounted && widget.auth.deviceAuthorized) {
        context.go(widget.auth.nextSecurityRoute);
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) {
      final request = widget.auth.deviceStatus?['device'] as Map<String, dynamic>?;
      return Scaffold(
        appBar: AppBar(title: const Text('Device approval')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              widget.auth.deviceAuthorized
                  ? 'Device approved'
                  : 'This sign-in needs approval',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            const Text(
              'On an approved device, open Settings → Devices and approve this sign-in using the code below. No conversations are available here.',
            ),
            if (request?['revoked_at'] != null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'This session was revoked. Sign out before requesting a new sign-in.',
                  style: TextStyle(color: Colors.redAccent),
                ),
              )
            else if (request?['link_code'] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: SelectableText(
                  request!['link_code'],
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),
            if (request == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('Connect to the service to obtain a device request.'),
              ),
            FilledButton(
              onPressed: () => act(context, () async {
                await widget.auth.refreshDeviceAccess(initial: true);
                if (context.mounted && widget.auth.deviceAuthorized) {
                  context.go(widget.auth.nextSecurityRoute);
                }
              }),
              child: const Text('Check approval'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => act(context, widget.auth.signOut),
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: () {
                widget.auth.lock.lock();
                context.go('/');
              },
              child: const Text('Return to Calculator'),
            ),
          ],
        ),
      );
    },
  );
}

class DeviceSessionsScreen extends StatefulWidget {
  const DeviceSessionsScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<DeviceSessionsScreen> createState() => _DeviceSessionsScreenState();
}

class _DeviceSessionsScreenState extends State<DeviceSessionsScreen> {
  late Future<Map<String, dynamic>> future = load();
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) setState(() => future = load());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> load() async => {
    'status': await widget.auth.deviceAccess.status(),
    'devices': await widget.auth.deviceAccess.fetchDevices(),
  };

  Future<void> rename(String targetId, String currentName) async {
    final newName = await askText(
      context,
      'Rename device',
      initial: currentName,
    );
    if (newName == null || newName.trim().isEmpty || !mounted) return;
    await widget.auth.deviceAccess.renameDevice(targetId, newName.trim());
    if (mounted) setState(() => future = load());
  }

  Future<void> manage(String action, {String? target}) async {
    String? code, name;
    if (action == 'approve') {
      code = await askText(context, 'Code shown on the new device');
      if (code == null || !mounted) return;
    }
    if (action == 'enable') {
      name = await askText(
        context,
        'Name this device',
        initial: 'Android device',
      );
      if (name == null || !mounted) return;
    }
    final password = await askText(
      context,
      'Confirm account password',
      secret: true,
    );
    if (password == null || !mounted) return;
    await widget.auth.deviceAccess.manage(
      action,
      password,
      target: target,
      code: code?.trim(),
      name: name?.trim(),
    );
    await widget.auth.refreshDeviceAccess(initial: true);
    if (mounted) setState(() => future = load());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Devices and sessions'),
      actions: [
        IconButton(
          tooltip: 'Refresh devices',
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() => future = load()),
        ),
      ],
    ),
    body: FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadError(retry: () => setState(() => future = load()));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final status = snapshot.data!['status'] as Map<String, dynamic>;
        final devices = (snapshot.data!['devices'] as List).cast<Map<String, dynamic>>();
        return ListView(
          children: [
            const ListTile(
              title: Text('Account access approval'),
              subtitle: Text(
                'Device approval controls account access. Real-time sync keeps unread counts and conversations synchronized.',
              ),
            ),
            if (status['enforced'] != true)
              ListTile(
                title: const Text('Enable device approval'),
                subtitle: const Text(
                  'New sign-ins will need approval. Keep an approved device available.',
                ),
                trailing: const Icon(Icons.security),
                onTap: () => act(context, () => manage('enable')),
              ),
            if (status['enforced'] == true)
              ListTile(
                leading: const Icon(Icons.phonelink_erase, color: Colors.redAccent),
                title: const Text('Revoke all other sessions'),
                subtitle: const Text('Disconnect all other phones and desktops'),
                onTap: () => act(context, () => manage('revoke_others')),
              ),
            const Divider(),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                'Connected Devices',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            if (devices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No devices registered yet.'),
              ),
            for (final device in devices)
              ListTile(
                leading: Icon(
                  device['session_id'] == status['session_id']
                      ? Icons.phone_android
                      : Icons.devices,
                  color: device['revoked_at'] != null
                      ? Colors.grey
                      : device['approved_at'] != null
                      ? Colors.green
                      : Colors.orange,
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        device['name'] ?? 'Device',
                        style: TextStyle(
                          decoration: device['revoked_at'] != null
                              ? TextDecoration.lineThrough
                              : null,
                          fontWeight: device['session_id'] == status['session_id']
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (device['session_id'] == status['session_id'])
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'Current',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                  ],
                ),
                subtitle: Text(
                  '${device['revoked_at'] != null ? 'Revoked' : device['approved_at'] != null ? 'Approved' : 'Pending approval'}'
                  '${device['last_seen_at'] != null ? ' · Last active ${DateFormat.MMMd().add_Hm().format(DateTime.parse(device['last_seen_at']).toLocal())}' : ''}',
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'rename') {
                      act(context, () => rename(device['id'], device['name'] ?? 'Device'));
                    } else {
                      act(context, () => manage(action, target: device['id']));
                    }
                  },
                  itemBuilder: (_) => [
                    if (device['revoked_at'] == null)
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                    if (device['approved_at'] == null && device['revoked_at'] == null)
                      const PopupMenuItem(
                        value: 'approve',
                        child: Text('Approve with code'),
                      ),
                    if (device['session_id'] != status['session_id'] &&
                        device['revoked_at'] == null &&
                        status['enforced'] == true)
                      const PopupMenuItem(
                        value: 'revoke',
                        child: Text('Revoke access', style: TextStyle(color: Colors.redAccent)),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
