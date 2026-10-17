import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
  final username = TextEditingController(),
      password = TextEditingController(),
      displayName = TextEditingController(),
      mobile = TextEditingController(),
      confirmPassword = TextEditingController();
  bool signup = false, busy = false;
  Future<void> submit() async {
    if (busy) return;
    setState(() => busy = true);
    await act(context, () async {
      if (signup) {
        await widget.auth.signUp(username.text, displayName.text, mobile.text,
            password.text, confirmPassword.text);
      } else if (widget.recoverPin && widget.auth.signedIn && widget.auth.deviceAuthorized) {
        await widget.auth.reauthenticate(password.text);
      } else {
        await widget.auth.signIn(username.text, password.text);
      }
      password.clear();
      confirmPassword.clear();
      if (mounted) {
        context.go(widget.recoverPin && widget.auth.deviceAuthorized
            ? '/pin' : widget.auth.nextSecurityRoute);
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    username.dispose();
    confirmPassword.dispose();
    password.dispose();
    displayName.dispose();
    mobile.dispose();
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
                controller: displayName,
                decoration: const InputDecoration(labelText: 'Display Name'),
              ),
            if (!(widget.recoverPin && widget.auth.signedIn && widget.auth.deviceAuthorized))
              TextField(
                controller: username,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Username',
                  helperText: '3–30 lowercase letters, numbers or underscores. Used to sign in.',
                ),
              ),
            if (signup)
              TextField(
                controller: mobile,
                keyboardType: TextInputType.phone,
                autofillHints: const [AutofillHints.telephoneNumber],
                decoration: const InputDecoration(
                  labelText: 'Mobile number (optional)',
                  helperText: 'For future verified recovery; SMS recovery is not active. Use +91…',
                ),
              ),
            TextField(
              controller: password,
              obscureText: true,
              autofillHints: signup ? const [AutofillHints.newPassword] : const [AutofillHints.password],
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => submit(),
            ),
            if (signup)
              TextField(
                controller: confirmPassword,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.newPassword],
                decoration: const InputDecoration(labelText: 'Retype password'),
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
                onPressed: busy ? null : () => setState(() {
                  signup = !signup; password.clear(); confirmPassword.clear();
                }),
                child: Text(
                  signup
                      ? 'Already have an account? Sign in'
                      : 'Create an account',
                ),
              ),
            TextButton(
              onPressed: busy ? null : () => context.go('/password'),
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
                    await widget.auth.configurePin(pin.text, openMessenger: true);
                    if (context.mounted) context.go(widget.auth.lock.unlocked ? '/chats' : '/');
                  });
                  if (mounted) setState(() => busy = false);
                },
          child: const Text('Save PIN and open messenger'),
        ),
      ],
    ),
  );
}

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final userId = TextEditingController(), code = TextEditingController(),
      password = TextEditingController(), confirmation = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    userId.dispose(); code.dispose(); password.dispose(); confirmation.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Recover account')),
    body: ListView(padding: const EdgeInsets.all(24), children: [
      const Text('Use one unused recovery code. Recovery signs out old sessions and authorizes this device. There is no email or support bypass. If a reset is interrupted, use another unused code.'),
      TextField(controller: userId, autocorrect: false, decoration: const InputDecoration(labelText: 'Username')),
      TextField(controller: code, obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'One-time recovery code')),
      TextField(controller: password, obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'New password (minimum 12 characters)')),
      TextField(controller: confirmation, obscureText: true, autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'Retype password')),
      FilledButton(onPressed: busy ? null : () async {
        setState(() => busy = true);
        await act(context, () async {
          await widget.auth.recoverAccount(userId.text, code.text, password.text, confirmation.text);
          code.clear(); password.clear(); confirmation.clear();
          if (context.mounted) context.go(widget.auth.nextSecurityRoute);
        });
        if (mounted) setState(() => busy = false);
      }, child: Text(busy ? 'Please wait…' : 'Recover account')),
      TextButton(onPressed: busy ? null : () => context.go('/auth'), child: const Text('Return to sign in')),
    ]),
  );
}

class RecoveryCodesScreen extends StatefulWidget {
  const RecoveryCodesScreen({super.key, required this.auth});
  final AuthService auth;
  @override
  State<RecoveryCodesScreen> createState() => _RecoveryCodesScreenState();
}
class _RecoveryCodesScreenState extends State<RecoveryCodesScreen> {
  bool saved = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Save your recovery codes')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const Text('Write these codes down and keep them somewhere private, separate from this phone. Each works once and can reset your password and approve a replacement device. Recovery leaves other unused codes valid; generating codes in Settings replaces all old codes. These are shown only now and are not saved on this phone.'),
        const SizedBox(height: 16),
        for (var index = 0; index < widget.auth.recoveryCodes.length; index++)
          Padding(padding: const EdgeInsets.only(bottom: 12),
            child: SelectableText('${index + 1}. ${widget.auth.recoveryCodes[index]}')),
        CheckboxListTile(value: saved, onChanged: (value) => setState(() => saved = value ?? false),
          title: const Text('I have saved these codes securely')),
        FilledButton(onPressed: !saved ? null : () {
          widget.auth.acknowledgeRecoveryCodes();
          context.go(widget.auth.lock.unlocked ? '/chats' : widget.auth.nextSecurityRoute);
        }, child: const Text('Continue')),
      ]),
    ),
  );
}
