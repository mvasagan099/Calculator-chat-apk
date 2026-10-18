import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/core/services/launcher_icon_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('calculator_messenger/launcher_icon');
  final messages = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messages.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (method) async {
        messages.add(method);
        if (method.method == 'current') return 'graphite';
        if (method.method == 'set') return method.arguments['id'];
        throw PlatformException(code: 'unknown');
      });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  test('all launcher choices are distinct, named calculator icons', () {
    expect(LauncherIconService.options.map((e) => e.id).toSet().length, 4);
    expect(LauncherIconService.find('missing').id, 'classic');
  });
  test('Android icon choice switches launcher component without changing chat settings', () async {
    final switcher = LauncherIconService(channel: channel);
    expect(await switcher.current(), 'graphite');
    await switcher.set('sunrise');
    expect(messages.map((e) => e.method).toList(), ['current', 'set']);
    expect(messages.last.arguments, {'id': 'sunrise'});
    await expectLater(switcher.set('untrusted'), throwsArgumentError);
    expect(messages.length, 2);
  });
  testWidgets('launcher preview reflects selection', (tester) async {
    // TestWidgetsFlutterBinding asserts platform overrides are cleared before
    // the widget test finishes, rather than after tearDown.
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr,
      child: CalculatorIconPreview(option: CalculatorLauncherIcon('midnight',
          'Midnight', 'Deep navy', Color(0xff152b47), Color(0xffdceafa)))));
    expect(find.byIcon(Icons.calculate_rounded), findsOneWidget);
  });
}
