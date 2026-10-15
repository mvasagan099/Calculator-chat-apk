import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/security/lock_controller.dart';

class LocalPinSetupScreen extends StatefulWidget {
  const LocalPinSetupScreen({
    super.key,
    required this.lock,
    this.changing = false,
  });
  final LockController lock;
  final bool changing;
  @override
  State<LocalPinSetupScreen> createState() => _LocalPinSetupScreenState();
}

class _LocalPinSetupScreenState extends State<LocalPinSetupScreen> {
  final form = GlobalKey<FormState>();
  final current = TextEditingController(),
      pin = TextEditingController(),
      confirm = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    current.dispose();
    pin.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.changing) {
        if (!widget.lock.unlocked ||
            !await widget.lock.vault.verify(current.text)) {
          throw StateError(
            'Current PIN was not verified. Try again later if attempts are limited.',
          );
        }
        if (!widget.lock.unlocked) return;
      } else if (widget.lock.hasPin) {
        throw StateError('A PIN already exists. Unlock before changing it.');
      }
      await widget.lock.vault.configure(pin.text);
      await widget.lock.initialize();
      widget.lock.lock();
      if (mounted) context.go('/');
    } catch (_) {
      if (mounted) {
        setState(
          () => error = widget.changing
              ? 'PIN change failed. Check your current PIN or try again later.'
              : 'PIN could not be saved securely. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool confirmation = false,
    bool existing = false,
  }) => TextFormField(
    controller: controller,
    enabled: !busy,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    keyboardType: TextInputType.number,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(existing ? 12 : 8),
    ],
    decoration: InputDecoration(labelText: label, counterText: ''),
    validator: (value) {
      if (confirmation) return value == pin.text ? null : 'PINs do not match';
      return RegExp(
            existing ? r'^\d{4,12}$' : r'^\d{4,8}$',
          ).hasMatch(value ?? '')
          ? null
          : 'Use 4–8 digits';
    },
    onFieldSubmitted: (_) {
      if (confirmation) save();
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.changing ? 'Change local PIN' : 'Welcome'),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                widget.changing
                    ? 'Choose a new PIN'
                    : 'A little space of your own',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Create and confirm a 4–8 digit PIN. Enter it in the calculator, then press = to open your space. Choose a longer PIN for better protection.',
              ),
              const SizedBox(height: 16),
              const Text(
                'PHASE 1 · LOCAL PREVIEW',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Only sample conversations are included. No account or network connection is used. This PIN is separate from your future account password.',
              ),
              const SizedBox(height: 24),
              if (widget.changing) ...[
                field(current, 'Current PIN', existing: true),
                const SizedBox(height: 16),
              ],
              field(pin, 'New PIN'),
              const SizedBox(height: 16),
              field(confirm, 'Confirm PIN', confirmation: true),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy ? null : save,
                child: Text(
                  busy ? 'Saving securely…' : 'Save PIN and open calculator',
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'The app relocks in the background by default. If you forget this local preview PIN, clearing Android app data resets this preview. No in-app recovery bypass is provided.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
