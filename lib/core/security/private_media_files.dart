import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// App-internal, unexported temporary files. Deletion is not a promise of
/// forensic erasure on flash storage, nor of cleanup outside this directory.
class PrivateMediaFiles {
  PrivateMediaFiles({this.root});
  final Directory? root;
  Future<Directory> _directory() async {
    final directory =
        root ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/private-media-v1',
        );
    return directory.create(recursive: true);
  }

  Future<File> video(Uint8List bytes, {DateTime? expiresAt}) =>
      save(bytes, extension: 'mp4', expiresAt: expiresAt);

  Future<File> save(Uint8List bytes, {String extension = 'bin', DateTime? expiresAt}) async {
    final directory = await _directory();
    final safe = RegExp(r'^[a-zA-Z0-9]{1,10}$').hasMatch(extension) ? extension : 'bin';
    final file = File('${directory.path}/${const Uuid().v4()}.$safe');
    await file.writeAsBytes(bytes, flush: true);
    if (expiresAt != null) {
      final remaining = expiresAt.difference(DateTime.now());
      Timer(remaining.isNegative ? Duration.zero : remaining, () async {
        try { if (await file.exists()) await file.delete(); } on FileSystemException { /* Concurrent viewer/startup cleanup is safe. */ }
      });
    }
    return file;
  }

  Future<void> clear() async {
    final directory = await _directory();
    await for (final child in directory.list(followLinks: false)) {
      await child.delete(recursive: true);
    }
  }
}
