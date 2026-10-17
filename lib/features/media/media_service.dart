import '../../core/security/local_retention.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../core/config/app_config.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/private_media_access.dart';

class MediaUpload {
  const MediaUpload(this.attachment, this.kind);
  final Map<String, dynamic> attachment;
  final String kind;
}

class MediaService {
  MediaService(this.client, {this.onProgress, this.access});
  final PrivateMediaAccess? access;
  final void Function(double)? onProgress;
  final SupabaseClient client;
  static const maxBytes = 25 * 1024 * 1024;
  static const types = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'mp4': 'video/mp4',
    'm4a': 'audio/mp4',
    'mp3': 'audio/mpeg',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'zip': 'application/zip',
    'vcf': 'text/vcard',
  };
  Future<MediaUpload?> pick(String cid, String source, {bool groupIcon = false}) async {
    final guard = access;
    if (guard == null) throw StateError('Approved media handoff required');
    final path = await guard.pick<String>(
      ['image', 'camera', 'video'].contains(source) ? source : 'document', () async {
    if (source == 'image') {
      return (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;
    } else if (source == 'camera') {
      return (await ImagePicker().pickImage(source: ImageSource.camera))?.path;
    } else if (source == 'video') {
      return (await ImagePicker().pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      ))?.path;
    } else {
      return (await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: types.keys.toList(),
      )).firstOrNull?.path;
    }
    });
    if (path == null) return null;
    guard.check();
    return upload(cid, File(path), groupIcon: groupIcon);
  }

  Future<MediaUpload> upload(
    String cid,
    File file, {
    String? forcedKind,
    bool preserveBytes = false,
    bool groupIcon = false,
    String? displayFilename,
  }) async {
    access?.check();
    final size = await file.length();
    access?.check();
    if (size < 1 || size > maxBytes) {
      throw const FormatException('Files must be between 1 byte and 25 MB');
    }
    final ext = file.path.split('.').last.toLowerCase();
    final mime = types[ext];
    if (mime == null) throw const FormatException('Unsupported file type');
    Uint8List bytes = await file.readAsBytes();
    access?.check();
    var name = displayFilename ?? file.uri.pathSegments.last;
    var outputMime = mime;
    if (!preserveBytes && ['jpg', 'jpeg', 'png', 'webp'].contains(ext)) {
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 1920,
        minHeight: 1920,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      access?.check();
      if (compressed.length < bytes.length) {
        bytes = compressed;
        outputMime = 'image/jpeg';
        name = '${name.split('.').first}.jpg';
      }
    }
    final path =
        '$cid/${client.auth.currentUser!.id}/${groupIcon ? 'icons/' : ''}${const Uuid().v4()}-$name';
    final token = client.auth.currentSession?.accessToken;
    if (token == null) throw StateError('Sign in before uploading');
    final transport = http.Client();
    try {
      final uri = Uri.parse(
        '${AppConfig.supabaseUrl}/storage/v1/object/chat-media/${path.split('/').map(Uri.encodeComponent).join('/')}',
      );
      final request = _UploadRequest(uri, bytes, onProgress);
      request.headers.addAll({
        'Authorization': 'Bearer $token',
        'apikey': AppConfig.supabaseKey,
        'Content-Type': outputMime,
        'x-upsert': 'false',
      });
      final response = await transport.send(request);
      await response.stream.drain<void>();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Upload rejected. Check membership and file limits.');
      }
    } finally {
      transport.close();
    }
    access?.check();
    final check = await client.functions.invoke(
      'validate-media',
      body: {'bucket': 'chat-media', 'path': path},
    );
    access?.check();
    if (check.status != 200) {
      throw StateError('Media validation failed');
    }
    return MediaUpload(
      {
        'object_path': path,
        if (check.data is Map && check.data['media_expires_at'] != null)
          'media_expires_at': check.data['media_expires_at'],
        'filename': name,
        'mime_type': outputMime,
        'size_bytes': bytes.length,
      },
      forcedKind ??
          (mime.startsWith('image/')
              ? 'image'
              : mime.startsWith('video/')
              ? 'video'
              : mime.startsWith('audio/')
              ? 'audio'
              : 'file'),
    );
  }

  Future<Uint8List> download(
    Map<String, dynamic> attachment, {
    void Function(double)? onProgress,
  }) async {
    final expected = attachment['size_bytes'];
    if (expected is! int || expected < 1 || expected > maxBytes) {
      throw const FormatException('Invalid attachment size');
    }
    final mime = attachment['mime_type']?.toString() ?? '';
    if (mime.startsWith('image/') || mime.startsWith('video/')) {
      if (visualAttachmentExpired(attachment, DateTime.now())) throw StateError('Media expired');
      final owner = client.auth.currentUser?.id;
      final session = client.auth.currentSession?.accessToken;
      final trusted = await client.rpc('chat_media_deadline', params: {'path': attachment['object_path']});
      final trustedExpiry = trusted is Map ? DateTime.tryParse(trusted['expires_at']?.toString() ?? '') : null;
      if (trustedExpiry == null) throw StateError('Media unavailable');
      final previous = attachmentDeadline(attachment);
      if (previous == null || trustedExpiry.isBefore(previous)) {
        attachment['media_expires_at'] = trustedExpiry.toUtc().toIso8601String();
      }
      if (session == null) throw StateError('Media unavailable');
      final transport = http.Client();
      late final Uint8List bytes;
      try {
        // The private Edge gateway authorizes the approved device and enforces
        // current chat membership/expiry before privileged Storage reading.
        bytes = await downloadAuthenticatedVisualBytes(
          transport: transport,
          projectUrl: AppConfig.supabaseUrl,
          anonKey: AppConfig.supabaseKey,
          accessToken: session,
          path: attachment['object_path'] as String,
          expected: expected,
          onProgress: onProgress,
        );
      } finally {
        transport.close();
      }
      if (owner == null || owner != client.auth.currentUser?.id || session != client.auth.currentSession?.accessToken ||
          visualAttachmentExpired(attachment, DateTime.now()) || bytes.length != expected) {
        bytes.fillRange(0, bytes.length, 0);
        throw StateError('Media unavailable');
      }
      onProgress?.call(1);
      return bytes;
    }
    final url = await signedUrl(attachment);
    final transport = http.Client();
    try {
      final response = await transport
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw StateError('Download unavailable');
      if (response.contentLength != null &&
          response.contentLength != expected) {
        throw StateError('Attachment size changed');
      }
      return await readAttachmentBytes(
        response.stream.timeout(const Duration(seconds: 30)),
        expected: expected,
        onProgress: onProgress,
      );
    } finally {
      transport.close();
    }
  }

  Future<String> signedUrl(Map<String, dynamic> attachment) {
    final mime = attachment['mime_type']?.toString() ?? '';
    if (mime.startsWith('image/') || mime.startsWith('video/')) {
      throw StateError('Visual media requires an authenticated download');
    }
    var lifetime = 120;
    if (attachment['expires_at'] != null) {
      final expiry = DateTime.tryParse(attachment['expires_at']);
      if (expiry == null) throw StateError('Media unavailable');
      lifetime = expiry.difference(DateTime.now()).inSeconds.clamp(0, 120);
      if (lifetime == 0) throw StateError('Media expired');
    }
    return client.storage
        .from('chat-media')
        .createSignedUrl(attachment['object_path'], lifetime);
  }
}

class _UploadRequest extends http.BaseRequest {
  _UploadRequest(Uri uri, this.bytes, this.progress) : super('POST', uri) {
    contentLength = bytes.length;
  }
  final Uint8List bytes;
  final void Function(double)? progress;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    for (var offset = 0; offset < bytes.length; offset += 65536) {
      final end = (offset + 65536).clamp(0, bytes.length);
      yield bytes.sublist(offset, end);
      progress?.call(end / bytes.length);
    }
  }
}

/// Uses a private JWT-and-device-verified Edge route, never bearer signed URLs.
/// The caller checks the server media deadline and session before and after.
Future<Uint8List> downloadAuthenticatedVisualBytes({
  required http.Client transport,
  required String projectUrl,
  required String anonKey,
  required String accessToken,
  required String path,
  required int expected,
  void Function(double)? onProgress,
}) async {
  if (expected < 1 || expected > MediaService.maxBytes ||
      path.isEmpty || path.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const FormatException('Invalid media reference');
  }
  final request = http.Request(
    'POST',
    Uri.parse('$projectUrl/functions/v1/download-chat-media'),
  )..followRedirects = false;
  request.headers['content-type'] = 'application/json';
  request.body = jsonEncode({'path': path});
  request.headers.addAll({
    'Authorization': 'Bearer $accessToken',
    'apikey': anonKey,
  });
  final response = await transport.send(request).timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    await response.stream.drain<void>();
    throw StateError('Authenticated media download unavailable');
  }
  if (response.contentLength != null && response.contentLength != expected) {
    await response.stream.drain<void>();
    throw StateError('Attachment size changed');
  }
  return readAttachmentBytes(
    response.stream.timeout(const Duration(seconds: 30)),
    expected: expected,
    onProgress: onProgress,
  );
}

/// Enforces trusted metadata before retaining bytes, including chunked responses.
Future<Uint8List> readAttachmentBytes(
  Stream<List<int>> stream, {
  required int expected,
  void Function(double)? onProgress,
}) async {
  if (expected < 1 || expected > MediaService.maxBytes) {
    throw const FormatException('Invalid attachment size');
  }
  final output = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in stream) {
    received += chunk.length;
    if (received > expected) {
      throw StateError('Attachment exceeds declared size');
    }
    output.add(chunk);
    onProgress?.call(received / expected);
  }
  if (received != expected) throw StateError('Incomplete download');
  return output.takeBytes();
}
