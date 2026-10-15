/// Recursive descent arithmetic parser. Percent means division by 100.
class CalculatorEngine {
  String evaluate(String input) {
    final parser = _Parser(
      input.replaceAll('×', '*').replaceAll('÷', '/').replaceAll('−', '-'),
    );
    final value = parser.expression();
    parser.space();
    if (parser.index != parser.source.length || !value.isFinite) {
      throw const FormatException('Invalid calculation');
    }
    if (value == value.truncateToDouble()) return value.toInt().toString();
    return double.parse(value.toStringAsPrecision(12)).toString();
  }
}

class _Parser {
  _Parser(this.source);
  final String source;
  int index = 0;
  void space() {
    while (index < source.length && source[index] == ' ') {
      index++;
    }
  }

  bool take(String token) {
    space();
    if (source.startsWith(token, index)) {
      index += token.length;
      return true;
    }
    return false;
  }

  double expression() {
    var n = term();
    while (true) {
      if (take('+')) {
        n += term();
      } else if (take('-')) {
        n -= term();
      } else {
        return n;
      }
    }
  }

  double term() {
    var n = factor();
    while (true) {
      if (take('*')) {
        n *= factor();
      } else if (take('/')) {
        final d = factor();
        if (d == 0) throw const FormatException('Division by zero');
        n /= d;
      } else {
        return n;
      }
    }
  }

  double factor() {
    if (take('+')) return factor();
    if (take('-')) return -factor();
    double value;
    if (take('(')) {
      value = expression();
      if (!take(')')) throw const FormatException('Missing parenthesis');
    } else {
      space();
      final start = index;
      while (index < source.length && '0123456789.'.contains(source[index])) {
        index++;
      }
      value =
          double.tryParse(source.substring(start, index)) ??
          (throw const FormatException('Invalid number'));
    }
    while (take('%')) {
      value /= 100;
    }
    return value;
  }
}
