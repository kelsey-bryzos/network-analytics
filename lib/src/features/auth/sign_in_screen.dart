import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design/theme.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

/// Open self-serve sign-up is disabled in v1 — Optics is invite-only per
/// /spec/ACCESS_RULES.md R1.1. Flip to `true` only for local dev/testing
/// where you need to create accounts without going through an invite link.
const bool kAllowSelfSignup = false;

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _magicLink = false;
  bool _magicSent = false;
  bool _signUp = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
      _magicSent = false;
    });
    try {
      final client = Supabase.instance.client;
      if (_magicLink) {
        await client.auth.signInWithOtp(email: _email.text.trim());
        setState(() => _magicSent = true);
      } else if (_signUp) {
        await client.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
        );
        // If email confirmation is off, this signs them in immediately.
        // Either way, also try to promote any pending invites.
        try {
          await client.rpc('accept_pending_invites');
        } catch (_) {}
      } else {
        await client.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
        try {
          await client.rpc('accept_pending_invites');
        } catch (_) {}
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OpticsColors.canvas,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(OpticsRadii.sm),
                      child: Image.asset(
                        'assets/logos/network_analytics_icon.png',
                        width: 32,
                        height: 32,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('NETWORK ANALYTICS', style: OpticsTextStyles.headingMd),
                  ],
                ),
                const SizedBox(height: 28),
                Text(_signUp ? 'CREATE ACCOUNT' : 'SIGN IN',
                    style: OpticsTextStyles.headingXl),
                const SizedBox(height: 6),
                const Text(
                  'Multi-tenant analytics for distributors.',
                  style: OpticsTextStyles.bodySm,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(hintText: 'Email address'),
                ),
                if (!_magicLink) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(hintText: 'Password'),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: OpticsColors.danger,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_magicSent) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Check your email for a sign-in link.',
                    style: TextStyle(
                      color: OpticsColors.success,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : Text(_magicLink
                          ? 'Send magic link'
                          : (_signUp ? 'Create account' : 'Sign in')),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() => _magicLink = !_magicLink),
                  child: Text(
                    _magicLink ? 'Use password instead' : 'Use magic link',
                  ),
                ),
                if (kAllowSelfSignup)
                  TextButton(
                    onPressed: () => setState(() {
                      _signUp = !_signUp;
                      _magicLink = false;
                    }),
                    child: Text(
                      _signUp
                          ? 'Have an account? Sign in'
                          : 'New here? Create an account',
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Network Analytics is invite-only. Ask your administrator for an invite link.',
                      textAlign: TextAlign.center,
                      style: OpticsTextStyles.bodySm
                          .copyWith(color: OpticsColors.textMuted),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
