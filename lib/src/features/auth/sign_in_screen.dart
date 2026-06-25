import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/env.dart';
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
  bool _signUp = false;
  bool _forgotPassword = false;
  bool _resetSent = false;

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
      _resetSent = false;
    });
    try {
      final client = Supabase.instance.client;
      if (_forgotPassword) {
        await client.auth.resetPasswordForEmail(
          _email.text.trim(),
          redirectTo: '${OpticsEnv.appBaseUrl}/reset-password',
        );
        setState(() => _resetSent = true);
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
        // Sign-in goes through our auth-login Edge Function which gates
        // GoTrue with per-account lockout (5 attempts / 15-min window /
        // 15-min lockout). On success it returns a GoTrue session payload;
        // we hydrate the local session with the refresh_token.
        final r = await client.functions.invoke(
          'auth-login',
          body: {
            'email': _email.text.trim(),
            'password': _password.text,
          },
        );
        if (r.status >= 400) {
          final data = r.data;
          String msg = 'Sign-in failed.';
          if (data is Map && data['error'] is String) {
            msg = data['error'] as String;
          }
          setState(() => _error = msg);
        } else {
          final data = (r.data is Map) ? Map<String, dynamic>.from(r.data as Map) : <String, dynamic>{};
          final refreshToken = data['refresh_token']?.toString() ?? '';
          if (refreshToken.isEmpty) {
            setState(() => _error = 'Sign-in succeeded but session was empty. Please try again.');
          } else {
            await client.auth.setSession(refreshToken);
            try {
              await client.rpc('accept_pending_invites');
            } catch (_) {}
          }
        }
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
                Text(
                  _forgotPassword ? 'RESET PASSWORD' : (_signUp ? 'CREATE ACCOUNT' : 'SIGN IN'),
                  style: OpticsTextStyles.headingXl,
                ),
                const SizedBox(height: 6),
                Text(
                  _forgotPassword
                      ? 'Enter your email and we\'ll send you a reset link.'
                      : 'Multi-tenant analytics for distributors.',
                  style: OpticsTextStyles.bodySm,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(hintText: 'Email address'),
                ),
                if (!_forgotPassword) ...[
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
                if (_resetSent) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Password reset email sent — check your inbox.',
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
                      : Text(_forgotPassword
                          ? 'SEND RESET LINK'
                          : (_signUp ? 'CREATE ACCOUNT' : 'SIGN IN')),
                ),
                const SizedBox(height: 12),
                if (_forgotPassword)
                  TextButton(
                    onPressed: () => setState(() {
                      _forgotPassword = false;
                      _resetSent = false;
                      _error = null;
                    }),
                    child: const Text('BACK TO SIGN IN'),
                  )
                else ...[
                  TextButton(
                    onPressed: () => setState(() {
                      _forgotPassword = true;
                      _signUp = false;
                      _error = null;
                    }),
                    child: const Text('FORGOT PASSWORD?'),
                  ),
                ],
                if (!_forgotPassword)
                  if (kAllowSelfSignup)
                    TextButton(
                      onPressed: () => setState(() {
                        _signUp = !_signUp;
                      }),
                      child: Text(
                        _signUp
                            ? 'HAVE AN ACCOUNT? SIGN IN'
                            : 'NEW HERE? CREATE AN ACCOUNT',
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
