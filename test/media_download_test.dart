import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/features/media/media_service.dart';

void main() {
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
}
