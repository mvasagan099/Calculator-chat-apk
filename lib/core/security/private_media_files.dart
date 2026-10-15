import 'dart:io';
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

  Future<File> video(Uint8List bytes) async {
    final directory = await _directory();
    final file = File('${directory.path}/${const Uuid().v4()}.mp4');
    return file.writeAsBytes(bytes, flush: true);
  }

  Future<void> clear() async {
    final directory = await _directory();
    await for (final child in directory.list(followLinks: false)) {
      await child.delete(recursive: true);
    }
  }
}
