import 'dart:convert';

import 'package:calculator_messenger/features/status/status_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Updates load uses the exact profiles FK and filters muted users', () async {
    final requests = <Uri>[];
    final client = SupabaseClient(
      'https://fixture.invalid',
      'public-fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request.url);
        final rows = switch (request.url.path) {
          '/rest/v1/status_mutes' => [
              {'user_id': 'muted'},
            ],
          '/rest/v1/status_updates' => [
              {
                'id': 'status-1',
                'user_id': 'muted',
                'profiles': {'display_name': 'Muted', 'avatar_path': null},
              },
              {
                'id': 'status-2',
                'user_id': 'visible',
                'profiles': {'display_name': 'Visible', 'avatar_path': null},
              },
            ],
          _ => throw StateError('Unexpected request: ${request.url.path}'),
        };
        return http.Response(
          jsonEncode(rows),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    addTearDown(client.dispose);

    final results = await fetchVisibleStatusUpdates(client);
    expect(results.map((s) => s['id']), ['status-2']);
    expect(requests.map((uri) => uri.path), [
      '/rest/v1/status_mutes',
      '/rest/v1/status_updates',
    ]);
    final select = requests.last.queryParameters['select'];
    expect(
      select,
      '*,profiles!status_updates_user_id_fkey(display_name,avatar_path)',
    );
  });
}
