import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/security/lock_controller.dart';
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
  final engine = CalculatorEngine();
  Future<void> press(String key) async {
    if (busy) return;
    HapticFeedback.selectionClick();
    if (key == '=') {
      setState(() => busy = true);
      final input = expression;
      if (RegExp(r'^\d{4,12}$').hasMatch(input) &&
          await widget.lock.unlock(input)) {
        expression = '';
        result = '0';
        if (mounted) context.go('/chats');
      } else {
        try {
          result = engine.evaluate(input);
        } on FormatException {
          result = 'Error';
        }
        expression = '';
      }
      if (mounted) setState(() => busy = false);
      return;
    }
    setState(() {
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
    });
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
          if (widget.lock.hasPin && widget.lock.biometricsEnabled)
            IconButton(
              tooltip: 'Device authentication',
              onPressed: () async {
                if (await widget.lock.biometricUnlock() && context.mounted) {
                  context.go('/chats');
                }
              },
              icon: const Icon(Icons.fingerprint),
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
                          Expanded(child: _display()),
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
                        Expanded(child: _display()),
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

  Widget _display() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      alignment: Alignment.bottomRight,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              expression.isEmpty ? ' ' : expression,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 28, color: colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                result,
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w300,
                ),
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
      final padding = landscape ? 8.0 : 16.0, spacing = landscape ? 4.0 : 10.0;
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
              operator = ['÷', '×', '−', '+', '='].contains(keys[index]);
          return _CalculatorKey(
            label: key,
            onPressed: () => press(key),
            background: key == '='
                ? colors.primary
                : operator
                ? colors.primaryContainer
                : colors.surfaceContainerHighest,
            foreground: key == '=' ? colors.onPrimary : colors.onSurface,
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
  });
  final String label;
  final VoidCallback onPressed;
  final Color background, foreground;
  @override
  State<_CalculatorKey> createState() => _CalculatorKeyState();
}

class _CalculatorKeyState extends State<_CalculatorKey> {
  bool pressed = false;
  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: pressed ? .93 : 1,
    duration: const Duration(milliseconds: 110),
    curve: Curves.easeOutCubic,
    child: Material(
      color: widget.background,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onPressed,
        onHighlightChanged: (value) => setState(() => pressed = value),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: FittedBox(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 27,
                  color: widget.foreground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
