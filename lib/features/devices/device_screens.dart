import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/services/auth_service.dart';
import '../../core/widgets/actions.dart';

class DeviceApprovalScreen extends StatelessWidget {
  const DeviceApprovalScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: auth,
    builder: (context, _) {
      final request = auth.deviceStatus?['device'] as Map<String, dynamic>?;
      return Scaffold(
        appBar: AppBar(title: const Text('Device approval')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              auth.deviceAuthorized
                  ? 'Device approved'
                  : 'This sign-in needs approval',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            const Text(
              'On an approved device, open Settings → Devices and approve this sign-in using the code below. No conversations are available here.',
            ),
            if (request?['revoked_at'] != null)
              const Text(
                'This session was revoked. Sign out before requesting a new sign-in.',
              )
            else if (request?['link_code'] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: SelectableText(
                  request!['link_code'],
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            if (request == null)
              const Text('Connect to the service to obtain a device request.'),
            FilledButton(
              onPressed: () => act(context, () async {
                await auth.refreshDeviceAccess(initial: true);
                if (context.mounted && auth.deviceAuthorized) context.go('/');
              }),
              child: const Text('Check approval'),
            ),
            TextButton(
              onPressed: () => act(context, auth.signOut),
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: () {
                auth.lock.lock();
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
  Future<Map<String, dynamic>> load() async => {
    'status': await widget.auth.deviceAccess.status(),
    'devices': await widget.auth.client!
        .from('account_devices')
        .select(
          'id,session_id,name,last_seen_at,approved_at,revoked_at,request_expires_at',
        )
        .eq('user_id', widget.auth.client!.auth.currentUser!.id)
        .order('requested_at', ascending: false),
  };
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
    appBar: AppBar(title: const Text('Devices and sessions')),
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
        return ListView(
          children: [
            const ListTile(
              title: Text('Account access approval'),
              subtitle: Text(
                'Device approval controls account access. Chats are not end-to-end encrypted.',
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
                title: const Text('Revoke all other sessions'),
                onTap: () => act(context, () => manage('revoke_others')),
              ),
            for (final device in snapshot.data!['devices'] as List)
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(
                  '${device['name']}${device['session_id'] == status['session_id'] ? ' · current' : ''}',
                ),
                subtitle: Text(
                  '${device['revoked_at'] != null
                      ? 'Revoked'
                      : device['approved_at'] != null
                      ? 'Approved'
                      : 'Pending'} · ${DateFormat.MMMd().add_Hm().format(DateTime.parse(device['last_seen_at']).toLocal())}',
                ),
                trailing:
                    device['session_id'] == status['session_id'] ||
                        device['revoked_at'] != null ||
                        status['enforced'] != true
                    ? null
                    : PopupMenuButton<String>(
                        onSelected: (action) => act(
                          context,
                          () => manage(action, target: device['id']),
                        ),
                        itemBuilder: (_) => [
                          if (device['approved_at'] == null)
                            const PopupMenuItem(
                              value: 'approve',
                              child: Text('Approve with code'),
                            ),
                          const PopupMenuItem(
                            value: 'revoke',
                            child: Text('Revoke'),
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
