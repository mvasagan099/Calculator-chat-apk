import 'package:flutter_test/flutter_test.dart';
import 'package:calculator_messenger/features/calculator/calculator_engine.dart';

void main() {
  final engine = CalculatorEngine();
  test('operator precedence and parentheses', () {
    expect(engine.evaluate('2+3×4'), '14');
    expect(engine.evaluate('(2+3)×4'), '20');
    expect(engine.evaluate('10−3−2'), '5');
  });
  test('decimals, signs and percentages', () {
    expect(engine.evaluate('0.1+0.2'), '0.3');
    expect(engine.evaluate('-5×-2'), '10');
    expect(engine.evaluate('200×10%'), '20');
    expect(engine.evaluate('50%'), '0.5');
  });
  test('invalid input and division by zero never succeed', () {
    for (final input in ['', '1/0', '1..2', '(1+2', '2+', '1e99', '1 2']) {
      expect(
        () => engine.evaluate(input),
        throwsFormatException,
        reason: input,
      );
    }
  });
}
