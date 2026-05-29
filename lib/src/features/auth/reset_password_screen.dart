import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design/theme.dart';

/// Handles the password-reset deep link:
///   https://analytics.bryzos.com/reset-password#access_token=...&type=recovery
///
/// Supabase delivers the recovery token as a URL fragment. The Flutter web
/// bootstrap picks it up automatically via `onAuthStateChange` (event:
/// `AuthChangeEvent.passwordRecovery`). We listen for that event and show
/// a "choose new password" form when it fires.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _password    = TextEditingController();
  final _confirm     = TextEditingController();
  bool   _loading    = false;
  bool   _ready      = false; // true once recovery session is established
  bool   _done       = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // If the user already has a recovery session (the page was loaded via
    // the reset link), mark ready immediately.
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      _ready = true;
    }
    // Listen for the passwordRecovery event in case it hasn't fired yet.
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (data.event == AuthChangeEvent.passwordRecovery && mounted) {
        setState(() => _ready = true);
      }
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _password.text.trim();
    final cf = _confirm.text.trim();
    if (pw.isEmpty) {
      setState(() => _error = 'Please enter a new password.');
      return;
    }
    if (pw != cf) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (pw.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: pw),
      );
      setState(() { _done = true; _loading = false; });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) context.go('/dashboards');
    } on AuthException catch (e) {
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
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
                const Text('SET NEW PASSWORD', style: OpticsTextStyles.headingXl),
                const SizedBox(height: 6),
                const Text(
                  'Choose a new password for your account.',
                  style: OpticsTextStyles.bodySm,
                ),
                const SizedBox(height: 24),
                if (!_ready) ...[
                  const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Verifying reset link…',
                    textAlign: TextAlign.center,
                    style: OpticsTextStyles.bodySm,
                  ),
                ] else if (_done) ...[
                  const Text(
                    'Password updated! Redirecting…',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: OpticsColors.success, fontSize: 14),
                  ),
                ] else ...[
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(hintText: 'New password'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _confirm,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(hintText: 'Confirm new password'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: const TextStyle(color: OpticsColors.danger, fontSize: 12),
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
                        : const Text('UPDATE PASSWORD'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/sign-in'),
                    child: const Text('BACK TO SIGN IN'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
