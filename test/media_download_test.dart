import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:calculator_messenger/features/media/media_service.dart';


void main() {
  test('visual media fetch uses private Edge route with bearer and exact path', () async {
    final progress = <double>[];
    final transport = MockClient((request) async {
      expect(request.url.toString(),
          'https://project.supabase.co/functions/v1/download-chat-media');
      expect(request.headers['Authorization'] ?? request.headers['authorization'], 'Bearer fixture-user-token');
      expect(request.headers['apikey'], 'fixture-public-anon');
      expect(request.followRedirects, isFalse);
      expect(request.method, 'POST');
      expect(jsonDecode(request.body)['path'], 'conversation/user/image one.jpg');
      return http.Response.bytes([255, 216, 255, 1], 200,
          headers: {'content-type': 'image/jpeg'});
    });
    final result = await downloadAuthenticatedVisualBytes(
      transport: transport,
      projectUrl: 'https://project.supabase.co',
      anonKey: 'fixture-public-anon',
      accessToken: 'fixture-user-token',
      path: 'conversation/user/image one.jpg',
      expected: 4,
      onProgress: progress.add,
    );
    expect(result, [255, 216, 255, 1]);
    expect(progress.last, 1);
    transport.close();
  });

  test('visual media refuses non-200 responses and oversized streams', () async {
    final failure = MockClient((_) async => http.Response('private', 403));
    await expectLater(downloadAuthenticatedVisualBytes(
      transport: failure, projectUrl: 'https://project.supabase.co',
      anonKey: 'public', accessToken: 'token',
      path: 'conversation/user/test.jpg', expected: 3,
    ), throwsStateError);
    failure.close();
    final oversized = MockClient((_) async => http.Response.bytes([1, 2, 3, 4], 200));
    await expectLater(downloadAuthenticatedVisualBytes(
      transport: oversized, projectUrl: 'https://project.supabase.co',
      anonKey: 'public', accessToken: 'token',
      path: 'conversation/user/test.jpg', expected: 3,
    ), throwsStateError);
    oversized.close();
  });

  test('visual media rejects invalid object paths before network access', () async {
    final client = MockClient((_) async => throw StateError('network must not be used'));
    for (final path in ['../bad', 'folder//file.jpg', '']) {
      await expectLater(downloadAuthenticatedVisualBytes(
        transport: client, projectUrl: 'https://project.supabase.co',
        anonKey: 'public', accessToken: 'token',
        path: path, expected: 2,
      ), throwsFormatException);
    }
    client.close();
  });

  test('bounded attachment reader reports progress and exact bytes', () async {
    final progress = <double>[];
    expect(
      await readAttachmentBytes(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        expected: 4,
        onProgress: progress.add,
      ),
      [1, 2, 3, 4],
    );
    expect(progress, [.5, 1]);
  });
  test('truncated and oversized attachments are rejected', () async {
    await expectLater(
      readAttachmentBytes(Stream.value([1, 2]), expected: 3),
      throwsStateError,
    );
    await expectLater(
      readAttachmentBytes(Stream.value([1, 2, 3, 4]), expected: 3),
      throwsStateError,
    );
    await expectLater(
      readAttachmentBytes(const Stream.empty(), expected: 0),
      throwsFormatException,
    );
    await expectLater(
      readAttachmentBytes(
        const Stream.empty(),
        expected: MediaService.maxBytes + 1,
      ),
      throwsFormatException,
    );
  });
  test(
    'oversized stream is cancelled before further chunks are read',
    () async {
      bool cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final read = readAttachmentBytes(stream.stream, expected: 2);
      stream.add([1, 2, 3]);
      await expectLater(read, throwsStateError);
      expect(cancelled, isTrue);
      await stream.close();
    },
  );

  test('non-transient errors like invalid size or expired media fail immediately', () async {
    final client = SupabaseClient('https://project.supabase.co', 'fixture-anon');
    final service = MediaService(client);
    await expectLater(
      () => service.download({'size_bytes': -1, 'mime_type': 'image/jpeg'}),
      throwsFormatException,
    );
    await expectLater(
      () => service.download({
        'size_bytes': 100,
        'mime_type': 'image/jpeg',
        'media_expires_at': DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
      }),
      throwsStateError,
    );
    await client.dispose();
  });
}

