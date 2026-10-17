import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

/// SDK continuations can retain the fake zone they were started in. Alternate
/// small frame pumps with real I/O turns; never fast-forward the app lock timer
/// with an indeterminate progress indicator through pumpAndSettle.
Future<void> pumpAsyncUntil(WidgetTester tester, bool Function() finished) async {
  for (var attempt = 0; attempt < 500 && !finished(); attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  }
  expect(finished(), isTrue, reason: 'Mock SDK operation did not settle within 500 I/O/frame turns');
}

Future<void> pumpAsyncOperation(WidgetTester tester, Future<dynamic> operation) async {
  var done = false;
  Object? failure;
  StackTrace? trace;
  unawaited(operation.then<void>((_) { done = true; }, onError: (Object error, StackTrace stack) {
    failure = error; trace = stack; done = true;
  }));
  await pumpAsyncUntil(tester, () => done);
  final error = failure;
  if (error != null) Error.throwWithStackTrace(error, trace!);
}
