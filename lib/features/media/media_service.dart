import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../core/config/app_config.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class MediaUpload {
  const MediaUpload(this.attachment, this.kind);
  final Map<String, dynamic> attachment;
  final String kind;
}

class MediaService {
  MediaService(this.client, {this.onProgress});
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
  Future<MediaUpload?> pick(String cid, String source) async {
    String? path;
    if (source == 'image') {
      path = (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;
    } else if (source == 'camera') {
      path = (await ImagePicker().pickImage(source: ImageSource.camera))?.path;
    } else if (source == 'video') {
      path = (await ImagePicker().pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      ))?.path;
    } else {
      path = (await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: types.keys.toList(),
      )).firstOrNull?.path;
    }
    if (path == null) return null;
    return upload(cid, File(path));
  }

  Future<MediaUpload> upload(
    String cid,
    File file, {
    String? forcedKind,
  }) async {
    final size = await file.length();
    if (size < 1 || size > maxBytes) {
      throw const FormatException('Files must be between 1 byte and 25 MB');
    }
    final ext = file.path.split('.').last.toLowerCase();
    final mime = types[ext];
    if (mime == null) throw const FormatException('Unsupported file type');
    Uint8List bytes = await file.readAsBytes();
    var name = file.uri.pathSegments.last;
    var outputMime = mime;
    if (['jpg', 'jpeg', 'png', 'webp'].contains(ext)) {
      final compressed = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 1920,
        minHeight: 1920,
        quality: 85,
        format: CompressFormat.jpeg,
      );
      if (compressed.length < bytes.length) {
        bytes = compressed;
        outputMime = 'image/jpeg';
        name = '${name.split('.').first}.jpg';
      }
    }
    final path =
        '$cid/${client.auth.currentUser!.id}/${const Uuid().v4()}-$name';
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
    final check = await client.functions.invoke(
      'validate-media',
      body: {'bucket': 'chat-media', 'path': path},
    );
    if (check.status != 200) {
      throw StateError('Media validation failed');
    }
    return MediaUpload(
      {
        'object_path': path,
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
