import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/auth_service.dart';
import '../../core/widgets/actions.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.auth, this.recoverPin = false});
  final AuthService auth;
  final bool recoverPin;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final email = TextEditingController(),
      password = TextEditingController(),
      name = TextEditingController();
  bool signup = false, busy = false;
  Future<void> submit() async {
    if (busy) return;
    setState(() => busy = true);
    await act(context, () async {
      if (signup) {
        if (password.text.length < 12) {
          throw const FormatException('Use at least 12 characters');
        }
        await widget.auth.client!.auth.signUp(
          email: email.text.trim(),
          password: password.text,
          data: {'display_name': name.text.trim()},
          emailRedirectTo: 'app.calculatorspace.calculator://auth-callback',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Check your email to verify your account, then sign in.',
              ),
            ),
          );
          setState(() => signup = false);
        }
      } else {
        await widget.auth.signIn(email.text, password.text);
        if (mounted) {
          context.go(
            widget.recoverPin || !widget.auth.lock.hasPin ? '/pin' : '/',
          );
        }
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.recoverPin ? 'Recover device PIN' : 'Your private space',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: ListView(
          padding: const EdgeInsets.all(24),
          shrinkWrap: true,
          children: [
            const Icon(Icons.calculate_outlined, size: 56),
            const SizedBox(height: 20),
            Text(
              widget.recoverPin
                  ? 'Reauthenticate to replace this device’s PIN.'
                  : 'Connect with people. Keep your space private.',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            if (widget.auth.client == null)
              const SelectableText(
                'Backend not configured. Follow docs/DEPLOYMENT.md and build with SUPABASE_URL and SUPABASE_ANON_KEY. Calculator functions remain available.',
              ),
            if (signup)
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy || widget.auth.client == null ? null : submit,
              child: Text(
                busy
                    ? 'Please wait…'
                    : signup
                    ? 'Create account'
                    : 'Sign in',
              ),
            ),
            if (!widget.recoverPin)
              TextButton(
                onPressed: () => setState(() => signup = !signup),
                child: Text(
                  signup
                      ? 'Already have an account? Sign in'
                      : 'Create an account',
                ),
              ),
            TextButton(
              onPressed: widget.auth.client == null
                  ? null
                  : () => act(context, () async {
                      await widget.auth.client!.auth.resetPasswordForEmail(
                        email.text.trim(),
                        redirectTo:
                            'app.calculatorspace.calculator://auth-callback',
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'If registered, a recovery email is on its way.',
                            ),
                          ),
                        );
                      }
                    }),
              child: const Text('Forgot password?'),
            ),
            TextButton(
              onPressed: () => context.go('/'),
              child: const Text('Return to Calculator'),
            ),
          ],
        ),
      ),
    ),
  );
}

class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final pin = TextEditingController(), confirm = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    pin.dispose();
    confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Set device PIN')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Choose 4–8 digits. Enter these digits in the calculator and press = to unlock. This PIN is separate from your account password.',
        ),
        TextField(
          controller: pin,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'New PIN'),
        ),
        TextField(
          controller: confirm,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Confirm PIN'),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  await act(context, () async {
                    if (pin.text != confirm.text) {
                      throw const FormatException('PINs do not match');
                    }
                    await widget.auth.configurePin(pin.text);
                    if (context.mounted) context.go('/');
                  });
                  if (mounted) setState(() => busy = false);
                },
          child: const Text('Save PIN and lock'),
        ),
      ],
    ),
  );
}

class PasswordResetScreen extends StatelessWidget {
  const PasswordResetScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reset account password')),
    body: Center(
      child: FilledButton(
        onPressed: () => act(context, () async {
          final password = await askText(context, 'New password', secret: true);
          if (password == null) return;
          if (password.length < 12) {
            throw const FormatException('Use at least 12 characters');
          }
          await auth.client!.auth.updateUser(
            UserAttributes(password: password),
          );
          auth.recovery = false;
          await auth.signOut();
          if (context.mounted) context.go('/auth');
        }),
        child: const Text('Choose a new password'),
      ),
    ),
  );
}
