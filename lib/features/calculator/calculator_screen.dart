import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/security/lock_controller.dart';
import '../../core/security/pin_performance.dart';
import 'calculator_engine.dart';

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key, required this.lock});
  final LockController lock;
  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  String expression = '';
  String result = '0';
  bool busy = false;
  int _operation = 0;
  final _displayRevision = ValueNotifier(0);

  @override
  void dispose() {
    ++_operation;
    if (busy) widget.lock.cancelPendingUnlock();
    _displayRevision.dispose();
    super.dispose();
  }

  final engine = CalculatorEngine();
  Future<void> press(String key) async {
    if (busy) {
      if (key == '=') return;
      ++_operation;
      busy = false;
      // Continuing a calculation cancels the pending unlock, not its persisted
      // attempt accounting. No calculator key needs to wait for the KDF.
      widget.lock.cancelPendingUnlock();
    }
    HapticFeedback.selectionClick();
    if (key == '=') {
      final trace = PinTrace.begin();
      final operation = ++_operation;
      final input = expression;
      busy = true;
      // Show ordinary arithmetic output immediately for every '=' operation.
      // No spinner, unlock label or outcome is exposed by the calculator.
      try {
        result = engine.evaluate(input);
      } on FormatException {
        result = 'Error';
      }
      expression = '';
      _displayRevision.value++;
      var navigating = false;
      try {
        if (RegExp(r'^\d{4,12}$').hasMatch(input) &&
            await widget.lock.unlock(input, trace: trace) &&
            mounted &&
            operation == _operation &&
            widget.lock.unlocked) {
          final navigation = Stopwatch()..start();
          context.go('/chats');
          navigating = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            trace?.record(PinStage.navigation, navigation.elapsedMicroseconds);
            trace?.finish();
          });
        }
      } finally {
        if (operation == _operation) busy = false;
        if (!navigating) trace?.finish();
      }
      return;
    }
    if (key == 'AC') {
      expression = '';
      result = '0';
    } else if (key == '⌫') {
      if (expression.isNotEmpty) {
        expression = expression.substring(0, expression.length - 1);
      }
    } else if (key == '±') {
      if (expression.isEmpty && double.tryParse(result) != null) {
        expression = result;
      }
      final number = RegExp(r'(\d*\.?\d+%*)$').firstMatch(expression);
      if (number != null) {
        final start = number.start;
        final unary =
            start > 0 &&
            expression[start - 1] == '-' &&
            (start == 1 || '+−×÷*/-'.contains(expression[start - 2]));
        expression = unary
            ? expression.substring(0, start - 1) + expression.substring(start)
            : '${expression.substring(0, start)}-${expression.substring(start)}';
      }
    } else if (expression.length < 100) {
      if (expression.isEmpty &&
          '+−×÷'.contains(key) &&
          double.tryParse(result) != null) {
        expression = result;
      }
      expression += key;
    }
    _displayRevision.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: () => context.push('/recover'),
          child: const Text('Calculator'),
        ),
        actions: [
          if (!widget.lock.hasPin)
            TextButton(
              onPressed: () => context.go('/auth'),
              child: const Text('Set up'),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, size) {
            final landscape = size.maxWidth > size.maxHeight;
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: landscape ? 840 : 520),
                child: LayoutBuilder(
                  builder: (context, available) {
                    if (landscape) {
                      return Row(
                        children: [
                          Expanded(child: _reactiveDisplay()),
                          SizedBox(
                            width: available.maxWidth * .66,
                            height: available.maxHeight,
                            child: _keypad(true),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Expanded(child: _reactiveDisplay()),
                        SizedBox(
                          height: (available.maxHeight * .72).clamp(0, 520),
                          child: _keypad(false),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _reactiveDisplay() => ValueListenableBuilder<int>(
    valueListenable: _displayRevision,
    builder: (_, _, _) => _display(),
  );

  Widget _display() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.bottomRight,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              expression.isEmpty ? ' ' : expression,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 30,
                color: colors.onSurfaceVariant,
                letterSpacing: 0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 140),
                style: TextStyle(
                  fontSize: 68,
                  fontWeight: FontWeight.w300,
                  color: colors.onSurface,
                  letterSpacing: -1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                child: Text(result),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keypad(bool landscape) => LayoutBuilder(
    builder: (context, size) {
      final colors = Theme.of(context).colorScheme;
      const keys = [
        'AC',
        '⌫',
        '%',
        '÷',
        '7',
        '8',
        '9',
        '×',
        '4',
        '5',
        '6',
        '−',
        '1',
        '2',
        '3',
        '+',
        '±',
        '0',
        '.',
        '=',
      ];
      final padding = landscape ? 8.0 : 16.0, spacing = landscape ? 4.0 : 12.0;
      final width = (size.maxWidth - 2 * padding - 3 * spacing) / 4;
      final height = (size.maxHeight - 2 * padding - 4 * spacing) / 5;
      return GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.all(padding),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: width / (height > 1 ? height : 1),
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
        ),
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final key = keys[index],
              operator = ['÷', '×', '−', '+'].contains(key),
              isEqual = key == '=';
          return _CalculatorKey(
            label: key,
            onPressed: () => press(key),
            background: isEqual
                ? colors.primary
                : operator
                ? colors.primaryContainer
                : ['AC', '⌫', '%'].contains(key)
                ? colors.surfaceContainerHigh
                : colors.surfaceContainerHighest,
            foreground: isEqual
                ? colors.onPrimary
                : operator
                ? colors.onPrimaryContainer
                : colors.onSurface,
            isEqual: isEqual,
          );
        },
      );
    },
  );
}

class _CalculatorKey extends StatefulWidget {
  const _CalculatorKey({
    required this.label,
    required this.onPressed,
    required this.background,
    required this.foreground,
    this.isEqual = false,
  });

  final String label;
  final VoidCallback onPressed;
  final Color background, foreground;
  final bool isEqual;

  @override
  State<_CalculatorKey> createState() => _CalculatorKeyState();
}

class _CalculatorKeyState extends State<_CalculatorKey> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: pressed ? 0.92 : 1.0,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOutCubic,
      child: Material(
        color: widget.background,
        borderRadius: BorderRadius.circular(26),
        clipBehavior: Clip.antiAlias,
        elevation: widget.isEqual ? 2 : 0,
        child: InkWell(
          onTap: widget.onPressed,
          splashColor: widget.foreground.withValues(alpha: 0.12),
          highlightColor: widget.foreground.withValues(alpha: 0.08),
          onHighlightChanged: (value) => setState(() => pressed = value),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: FittedBox(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: widget.label == '⌫' ? 24 : 28,
                    color: widget.foreground,
                    fontWeight: widget.isEqual ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
