import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:calculator_messenger/features/calculator/calculator_screen.dart';
import 'package:integration_test/integration_test.dart';
import 'package:calculator_messenger/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('cold Android launch is a working calculator', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    if (find.text('A little space of your own').evaluate().isNotEmpty) {
      await tester.enterText(
        find.widgetWithText(TextFormField, 'New PIN'),
        '4862',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm PIN'),
        '4862',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save PIN and open calculator'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save PIN and open calculator'));
      for (
        var attempt = 0;
        attempt < 200 && find.byType(CalculatorScreen).evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
    }
    expect(find.text('Calculator'), findsWidgets);
    expect(find.text('Your space'), findsNothing);
    for (final key in ['AC', '8', '×', '7', '=']) {
      await tester.tap(find.text(key).last);
      await tester.pumpAndSettle();
    }
    expect(find.text('56'), findsOneWidget);
  });
}
