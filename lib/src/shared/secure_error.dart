// Shared secure error display utilities.
// - Bryzos users (@bryzos.com) see full technical detail.
// - External users see only a sanitised, friendly message.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/supabase_repo.dart';
import '../design/theme.dart';

/// Returns true if the current user has a @bryzos.com email.
bool isBryzosUser(WidgetRef ref) {
  final email = ref.read(supabaseProvider).auth.currentUser?.email ?? '';
  return email.toLowerCase().endsWith('@bryzos.com');
}

/// Same check but using a plain SupabaseClient (for non-widget contexts).
bool isBryzosEmail(String? email) {
  return (email ?? '').toLowerCase().endsWith('@bryzos.com');
}

/// Shows a SnackBar with error info.
/// - Bryzos users see full detail.
/// - External users see a sanitised generic message + "Report Error" button.
void showSecureErrorSnackBar(
  BuildContext context,
  WidgetRef ref,
  String generic,
  Object error,
) {
  final bryzos = isBryzosUser(ref);
  if (bryzos) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$generic $error',
          style: const TextStyle(color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        backgroundColor: OpticsColors.danger,
      ),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(generic, style: const TextStyle(color: Colors.white)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        backgroundColor: OpticsColors.danger,
        action: SnackBarAction(
          label: 'Report Error',
          textColor: Colors.white,
          onPressed: () {
            // Fire-and-forget error report
            try {
              final client = ref.read(supabaseProvider);
              final userEmail = client.auth.currentUser?.email ?? 'unknown';
              client.functions.invoke(
                'send-error-report',
                body: {
                  'user_email': userEmail,
                  'error_detail':
                      sanitizeErrorDetailForExternal(error.toString()),
                  'context': generic,
                },
              );
            } catch (_) {}
          },
        ),
      ),
    );
  }
}

/// Sanitises an error for non-Bryzos display. Strips URLs, stack traces,
/// and internal implementation details.
String sanitiseError(Object error) {
  final raw = error.toString();
  return raw
      .replaceAll(RegExp(r'https?://[^\s,]+'), '[redacted]')
      .replaceAll(RegExp(r'ClientException:\s*'), '')
      .replaceAll(RegExp(r'Exception:\s*'), '')
      .trim();
}

/// Sanitises an error detail string before it is sent to the
/// `send-error-report` Edge Function from a non-Bryzos user's browser.
///
/// Per Objective v4 §1(d): no Supabase project URLs, function names, query
/// strings, or other internal identifiers may be visible in the UI or in
/// browser inspection tools for non-Bryzos users. The error-report request
/// body is visible in DevTools → Network, so we strip identifiers here.
///
/// Bryzos users (the only ones whose browsers would carry `is_bryzos`) keep
/// the full detail — the server-side function records both for triage.
String sanitizeErrorDetailForExternal(String raw) {
  return raw
      // Supabase project URLs (any subdomain).
      .replaceAll(
          RegExp(r'https?://[a-z0-9-]+\.supabase\.(co|net)[^\s,)\]]*'),
          '[redacted-url]')
      // Any other absolute URL with query strings or paths.
      .replaceAll(RegExp(r'https?://[^\s,)\]]+'), '[redacted-url]')
      // PostgREST endpoint paths (e.g. /rest/v1/dashboards?select=...).
      .replaceAll(RegExp(r'/rest/v1/[A-Za-z0-9_./?=&%,*-]+'),
          '[redacted-endpoint]')
      // Edge function paths.
      .replaceAll(RegExp(r'/functions/v1/[A-Za-z0-9_./?=&%,*-]+'),
          '[redacted-endpoint]')
      // Auth endpoint paths.
      .replaceAll(RegExp(r'/auth/v1/[A-Za-z0-9_./?=&%,*-]+'),
          '[redacted-endpoint]')
      .trim();
}

/// Inline error text widget with Bryzos/external split.
/// Bryzos users see full detail; external users see generic message + Report button.
class SecureErrorText extends ConsumerStatefulWidget {
  final String genericMessage;
  final Object error;

  const SecureErrorText({
    super.key,
    required this.genericMessage,
    required this.error,
  });

  @override
  ConsumerState<SecureErrorText> createState() => _SecureErrorTextState();
}

class _SecureErrorTextState extends ConsumerState<SecureErrorText> {
  bool _reported = false;
  bool _reporting = false;

  Future<void> _reportError() async {
    setState(() => _reporting = true);
    try {
      final client = ref.read(supabaseProvider);
      final userEmail = client.auth.currentUser?.email ?? 'unknown';
      await client.functions.invoke(
        'send-error-report',
        body: {
          'user_email': userEmail,
          'error_detail':
              sanitizeErrorDetailForExternal(widget.error.toString()),
          'context': widget.genericMessage,
        },
      );
      if (mounted) setState(() { _reported = true; _reporting = false; });
    } catch (_) {
      if (mounted) setState(() => _reporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bryzos = isBryzosUser(ref);

    if (bryzos) {
      return Text(
        '${widget.genericMessage}\n${widget.error}',
        style: const TextStyle(color: OpticsColors.danger, fontSize: 12),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.genericMessage,
          style: const TextStyle(color: OpticsColors.danger, fontSize: 12),
        ),
        const SizedBox(height: 4),
        if (_reported)
          Text(
            'Error reported — thank you!',
            style: TextStyle(
              color: OpticsColors.accentGreen.withValues(alpha: 0.8),
              fontSize: 11,
            ),
          )
        else
          TextButton.icon(
            onPressed: _reporting ? null : _reportError,
            icon: _reporting
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bug_report, size: 14),
            label: Text(
              _reporting ? 'Reporting…' : 'Report Error',
              style: const TextStyle(fontSize: 11),
            ),
          ),
      ],
    );
  }
}
