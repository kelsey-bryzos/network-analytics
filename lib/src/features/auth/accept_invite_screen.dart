import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/supabase_repo.dart' show activeTenantProvider;
import '../../design/theme.dart';

/// Accept-Invite screen — `/accept-invite?token=...`
///
/// Three paths depending on who is clicking:
///
///   A. Already signed in as the invited email
///      → One-click "Add [Org] to my account" confirmation screen.
///        No password. Instantly shows success. Perfect for multi-tenant.
///
///   B. Existing user (has an account), not currently signed in
///      → "Sign in to accept" form. user_exists=true from Edge Function
///        means we start in sign-in mode immediately — never show signup.
///
///   C. Brand new user (no account yet)
///      → "Create account & join" form with password creation.
///        Requires T&C acceptance — shown inline before submit is active.
///
///   D. Signed in as wrong account → prompt to sign out first.
///
/// T&C rule: only new users (Path C) must accept. Existing users joining
/// an additional tenant (Paths A & B) already accepted on first join.
class AcceptInviteScreen extends ConsumerStatefulWidget {
  final String? token;
  const AcceptInviteScreen({super.key, required this.token});

  @override
  ConsumerState<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends ConsumerState<AcceptInviteScreen> {
  bool _previewLoading = true;
  String? _previewError;
  Map<String, dynamic>? _preview;

  final _firstNameCtl = TextEditingController();
  final _lastNameCtl  = TextEditingController();
  final _passwordCtl  = TextEditingController();
  bool _showPassword = false;
  bool _submitting = false;
  String? _submitError;

  // T&C state — only relevant for Path C (new users)
  bool _termsAccepted = false;
  bool _showTerms = false;          // toggle inline T&C panel
  bool _termsScrolledToBottom = false;

  // Success state
  bool _accepted = false;
  String _acceptedTenantName = '';

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void dispose() {
    _firstNameCtl.dispose();
    _lastNameCtl.dispose();
    _passwordCtl.dispose();
    super.dispose();
  }

  // ── Preview load ─────────────────────────────────────────────────────────

  Future<void> _loadPreview() async {
    final tok = (widget.token ?? '').trim();
    if (tok.isEmpty) {
      setState(() {
        _previewLoading = false;
        _previewError = 'No invite token in the URL.';
      });
      return;
    }
    try {
      final r = await Supabase.instance.client.functions.invoke(
        'accept-invite',
        method: HttpMethod.get,
        queryParameters: {'token': tok},
      );
      if (r.status >= 400) {
        final msg = (r.data is Map && r.data['error'] != null)
            ? r.data['error'].toString()
            : 'Invite preview failed (${r.status}).';
        setState(() {
          _previewLoading = false;
          _previewError = msg;
        });
        return;
      }
      setState(() {
        _previewLoading = false;
        _preview = Map<String, dynamic>.from(r.data as Map);
      });
    } catch (e) {
      setState(() {
        _previewLoading = false;
        _previewError = e.toString();
      });
    }
  }

  // ── Path A: Already signed in as right account → one-click accept ────────

  Future<void> _acceptAuthenticated() async {
    final tok = (widget.token ?? '').trim();
    if (tok.isEmpty) return;
    setState(() { _submitting = true; _submitError = null; });
    try {
      final r = await Supabase.instance.client.functions.invoke(
        'accept-invite',
        body: {'token': tok},
      );
      if (r.status >= 400) {
        final msg = (r.data is Map && r.data['error'] != null)
            ? r.data['error'].toString()
            : 'Accept failed (${r.status}).';
        setState(() { _submitting = false; _submitError = msg; });
        return;
      }
      final data = Map<String, dynamic>.from(r.data as Map);
      await _finalise(data, showConfirmScreen: true);
    } catch (e) {
      setState(() { _submitting = false; _submitError = e.toString(); });
    }
  }

  // ── Path B: Existing user, no session → sign in then accept ─────────────

  Future<void> _signInAndAccept() async {
    final tok = (widget.token ?? '').trim();
    if (tok.isEmpty) return;
    final password = _passwordCtl.text;
    if (password.isEmpty) {
      setState(() => _submitError = 'Please enter your password.');
      return;
    }
    setState(() { _submitting = true; _submitError = null; });
    try {
      final r = await Supabase.instance.client.functions.invoke(
        'accept-invite',
        body: {'token': tok, 'password': password, 'mode': 'signin'},
      );
      if (r.status >= 400) {
        final msg = (r.data is Map && r.data['error'] != null)
            ? r.data['error'].toString()
            : 'Sign in failed (${r.status}).';
        setState(() { _submitting = false; _submitError = msg; });
        return;
      }
      final data = Map<String, dynamic>.from(r.data as Map);
      await _applySession(data);
      await _finalise(data, showConfirmScreen: true);
    } catch (e) {
      setState(() { _submitting = false; _submitError = e.toString(); });
    }
  }

  // ── Path C: Brand new user → create account then accept ─────────────────

  Future<void> _signUpAndAccept() async {
    final tok = (widget.token ?? '').trim();
    if (tok.isEmpty) return;
    final firstName = _firstNameCtl.text.trim();
    final lastName  = _lastNameCtl.text.trim();
    final password  = _passwordCtl.text;
    if (firstName.isEmpty) {
      setState(() => _submitError = 'Please enter your first name.');
      return;
    }
    if (lastName.isEmpty) {
      setState(() => _submitError = 'Please enter your last name.');
      return;
    }
    if (password.length < 8) {
      setState(() => _submitError = 'Password must be at least 8 characters.');
      return;
    }
    if (!_termsAccepted) {
      setState(() => _submitError = 'You must accept the Terms and Conditions to continue.');
      return;
    }
    setState(() { _submitting = true; _submitError = null; });
    try {
      final r = await Supabase.instance.client.functions.invoke(
        'accept-invite',
        body: {
          'token': tok,
          'password': password,
          'mode': 'signup',
          'terms_accepted': true,
          'first_name': firstName,
          'last_name': lastName,
        },
      );
      if (r.status >= 400) {
        final rawMsg = (r.data is Map && r.data['error'] != null)
            ? r.data['error'].toString()
            : 'Failed (${r.status}).';
        final lower = rawMsg.toLowerCase();
        if (lower.contains('already') || lower.contains('exists') || lower.contains('registered')) {
          setState(() {
            _submitting = false;
            _submitError = 'An account already exists for this email. Use "Sign in" instead.';
          });
          return;
        }
        setState(() { _submitting = false; _submitError = rawMsg; });
        return;
      }
      final data = Map<String, dynamic>.from(r.data as Map);
      await _applySession(data);
      await _finalise(data, showConfirmScreen: false);
    } catch (e) {
      setState(() { _submitting = false; _submitError = e.toString(); });
    }
  }

  // ── Session helpers ──────────────────────────────────────────────────────

  Future<void> _applySession(Map<String, dynamic> data) async {
    final sessionMap = data['session'] as Map<String, dynamic>?;
    if (sessionMap != null) {
      final accessToken = sessionMap['access_token']?.toString() ?? '';
      final refreshToken = sessionMap['refresh_token']?.toString() ?? '';
      if (accessToken.isNotEmpty && refreshToken.isNotEmpty) {
        await Supabase.instance.client.auth.setSession(accessToken, refreshToken);
      }
    }
  }

  Future<void> _finalise(Map<String, dynamic> data, {required bool showConfirmScreen}) async {
    try { await Supabase.instance.client.auth.refreshSession(); } catch (_) {}

    final acceptedTenantId = (data['tenant_id'] ?? '').toString();
    if (acceptedTenantId.isNotEmpty) {
      ref.read(activeTenantProvider.notifier).state = acceptedTenantId;
    }

    final tenantName = (data['tenant_name'] ?? '').toString();

    if (!mounted) return;

    if (showConfirmScreen) {
      setState(() {
        _submitting = false;
        _accepted = true;
        _acceptedTenantName = tenantName;
      });
    } else {
      // New user (Path C) — go straight to dashboards.
      context.go('/dashboards');
    }
  }

  Future<void> _signOut() async {
    await Supabase.instance.client.auth.signOut();
    if (mounted) setState(() {});
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OpticsColors.canvas,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _buildContent(context),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_previewLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_previewError != null) {
      return _errorBlock(
        title: 'INVITE LINK UNAVAILABLE',
        body: _previewError!,
      );
    }

    final p = _preview!;

    if (p['accepted'] == true) {
      return _errorBlock(
        title: 'INVITE ALREADY USED',
        body: 'This invite has already been accepted. Sign in normally to access ${p['tenant_name'] ?? 'your organization'}.',
        actionLabel: 'GO TO SIGN-IN',
        onAction: () => context.go('/sign-in'),
      );
    }

    if (p['expired'] == true) {
      return _errorBlock(
        title: 'INVITE EXPIRED',
        body: 'This invite has expired. Ask whoever invited you to send a new one.',
      );
    }

    if (_accepted) {
      return _successConfirmation();
    }

    final invitedEmail = (p['email'] ?? '').toString().toLowerCase();
    final tenantName = (p['tenant_name'] ?? '').toString();
    final role = (p['role'] ?? '').toString();
    final userExists = p['user_exists'] == true;
    // T&Cs are always required for brand-new account creation (Path C).
    // We intentionally do NOT gate this on the backend `needs_terms` flag — a
    // legal requirement must never silently disappear due to a server-side
    // signal regression. Path C is reached only when userExists == false, which
    // by definition means a new account is being created and must accept terms.
    final needsTerms = !userExists;

    final session = Supabase.instance.client.auth.currentSession;
    final signedInEmail = (session?.user.email ?? '').toLowerCase();

    // ── Path A: Signed in as the right account → one-click ──────────────────
    if (session != null && signedInEmail == invitedEmail) {
      return _layout(
        title: 'ADD ORGANIZATION',
        subtitle: '${tenantName.isEmpty ? "This organization" : tenantName} has invited you as ${_humanRole(role)}. Tap below to add it to your account.',
        children: [
          _inviteSummary(p),
          const SizedBox(height: 20),
          if (_submitError != null) ...[
            Text(_submitError!, style: const TextStyle(color: OpticsColors.danger, fontSize: 12)),
            const SizedBox(height: 10),
          ],
          ElevatedButton(
            onPressed: _submitting ? null : _acceptAuthenticated,
            child: _submitting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : Text('ADD ${tenantName.isEmpty ? "ORGANIZATION" : tenantName.toUpperCase()} TO MY ACCOUNT'),
          ),
        ],
      );
    }

    // ── Path D: Signed in as wrong account → sign out first ─────────────────
    if (session != null && signedInEmail != invitedEmail) {
      return _layout(
        title: 'WRONG ACCOUNT',
        subtitle: 'You are signed in as $signedInEmail, but this invite was sent to $invitedEmail. Sign out and then reopen this link.',
        children: [
          _inviteSummary(p),
          const SizedBox(height: 20),
          OutlinedButton(onPressed: _signOut, child: const Text('SIGN OUT')),
        ],
      );
    }

    // ── Path B: Existing user, no session → sign in ──────────────────────────
    if (userExists) {
      return _layout(
        title: '',
        subtitle: 'Sign in to add ${tenantName.isEmpty ? "this organization" : tenantName} to your account.',
        children: [
          _inviteSummary(p),
          const SizedBox(height: 16),
          TextField(
            enabled: false,
            decoration: const InputDecoration(labelText: 'EMAIL'),
            controller: TextEditingController(text: invitedEmail),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passwordCtl,
            obscureText: !_showPassword,
            onSubmitted: (_) => _signInAndAccept(),
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'PASSWORD',
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
          ),
          if (_submitError != null) ...[
            const SizedBox(height: 10),
            Text(_submitError!, style: const TextStyle(color: OpticsColors.danger, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _submitting ? null : _signInAndAccept,
            child: _submitting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('SIGN IN & ACCEPT'),
          ),
        ],
      );
    }

    // ── Path C: Brand new user → create account + T&C ────────────────────────
    return _layout(
      title: '',
      subtitle: 'Create your account to join ${tenantName.isEmpty ? "your organization" : tenantName} on Network Analytics.',
      children: [
        _inviteSummary(p),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _firstNameCtl,
                autofillHints: const [AutofillHints.givenName],
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'FIRST NAME'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _lastNameCtl,
                autofillHints: const [AutofillHints.familyName],
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'LAST NAME'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          enabled: false,
          decoration: const InputDecoration(labelText: 'EMAIL'),
          controller: TextEditingController(text: invitedEmail),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passwordCtl,
          obscureText: !_showPassword,
          onSubmitted: needsTerms
              ? (_) { if (_termsAccepted) _signUpAndAccept(); }
              : (_) => _signUpAndAccept(),
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(
            labelText: 'SET A PASSWORD (8+ CHARS)',
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
        if (needsTerms) ...[
          const SizedBox(height: 20),
          _termsSection(),
        ],
        if (_submitError != null) ...[
          const SizedBox(height: 10),
          Text(_submitError!, style: const TextStyle(color: OpticsColors.danger, fontSize: 12)),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: (_submitting || (needsTerms && !_termsAccepted)) ? null : _signUpAndAccept,
          child: _submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
              : const Text('CREATE ACCOUNT & JOIN'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _submitting ? null : () => setState(() {
            _preview!['user_exists'] = true;
            _submitError = null;
            _passwordCtl.clear();
          }),
          child: const Text('ALREADY HAVE AN ACCOUNT? SIGN IN'),
        ),
      ],
    );
  }

  // ── T&C section (Path C only) ────────────────────────────────────────────

  Widget _termsSection() {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(
          color: _termsAccepted
              ? const Color(0xFF3DB8FF).withOpacity(0.5)
              : OpticsColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row with checkbox
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: Checkbox(
                    value: _termsAccepted,
                    onChanged: (v) => setState(() {
                      _termsAccepted = v ?? false;
                      _submitError = null;
                    }),
                    activeColor: const Color(0xFF3DB8FF),
                    side: BorderSide(
                      color: _termsAccepted
                          ? const Color(0xFF3DB8FF)
                          : OpticsColors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: OpticsTextStyles.bodySm,
                      children: [
                        const TextSpan(text: 'I have read and agree to the '),
                        TextSpan(
                          text: 'Terms and Conditions',
                          style: OpticsTextStyles.bodySm.copyWith(
                            color: const Color(0xFF3DB8FF),
                            decoration: TextDecoration.underline,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () => setState(() => _showTerms = !_showTerms),
                        ),
                        const TextSpan(text: ' of Bryzos, LLC.'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Expand/collapse toggle
          GestureDetector(
            onTap: () => setState(() => _showTerms = !_showTerms),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
              child: Row(
                children: [
                  Icon(
                    _showTerms ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: OpticsColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _showTerms ? 'HIDE TERMS' : 'READ TERMS',
                    style: OpticsTextStyles.bodySm.copyWith(
                      color: OpticsColors.textMuted,
                      fontSize: 11,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Inline T&C text panel (collapsible)
          if (_showTerms) ...[
            Container(
              height: 320,
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: OpticsColors.border),
                ),
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (!_termsScrolledToBottom && n is ScrollUpdateNotification) {
                    final metrics = n.metrics;
                    if (metrics.pixels >= metrics.maxScrollExtent - 40) {
                      setState(() => _termsScrolledToBottom = true);
                    }
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _termsText(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: AnimatedOpacity(
                opacity: _termsScrolledToBottom ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 300),
                child: Text(
                  '↓ SCROLL TO READ ALL TERMS',
                  style: OpticsTextStyles.bodySm.copyWith(
                    color: const Color(0xFF3DB8FF).withOpacity(0.7),
                    fontSize: 11,
                    letterSpacing: 0.8,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _termsText() {
    final body = OpticsTextStyles.bodySm.copyWith(
      color: OpticsColors.textMuted,
      height: 1.6,
      fontSize: 12,
    );
    final heading = body.copyWith(
      color: OpticsColors.textPrimary,
      fontWeight: FontWeight.w600,
      fontSize: 12,
      letterSpacing: 0.5,
    );

    Widget h(String t) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(t, style: heading),
    );
    Widget p(String t) => Text(t, style: body);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('NETWORK ANALYTICS — TERMS AND CONDITIONS',
            style: heading.copyWith(fontSize: 13)),
        p('Effective Date: June 1, 2026  •  Operated by: Bryzos, LLC'),
        const SizedBox(height: 12),
        p('These Terms and Conditions ("Terms") govern your access to and use of Network Analytics, a data analytics and business intelligence platform ("the Platform") operated by Bryzos, LLC. By creating your account you agree to be bound by these Terms in their entirety.'),
        const SizedBox(height: 8),
        p('IF YOU DO NOT AGREE TO THESE TERMS, DO NOT ACCESS OR USE THE PLATFORM.'),

        h('1. DESCRIPTION OF THE PLATFORM'),
        p('Network Analytics enables authorized users to connect to data sources, visualize data via dashboards and widgets, build and export reports, manage team access, and sync operational data into a read-only analytics mirror. Access is invitation-only, restricted to organizations whose applications are powered by Bryzos.'),

        h('2. ELIGIBILITY AND ACCESS'),
        p('Access is restricted to individuals who have received a valid invitation. You are responsible for maintaining credential confidentiality and must notify Bryzos immediately of any unauthorized access. Role tiers (Owner, Admin, Editor, Viewer) are assigned by your Organization and enforced by the Platform.'),

        h('3. YOUR DATA AND DATA SOURCES'),
        p('Your Data belongs to you. The Platform creates a read-only synchronized mirror of Your Data used solely for analytics. Bryzos does not guarantee that mirrored data is complete, current, or error-free. You acknowledge analytics data may lag operational data. All data source credentials are stored in encrypted vaults and never transmitted to your device. Each Organization\'s data is strictly isolated; no Organization may access another\'s data. Upon termination, Bryzos retains mirrored data for 30 days before deletion.'),

        h('4. ACCEPTABLE USE'),
        p('You agree not to: share credentials; attempt to access other tenants\' data; violate applicable privacy laws; reverse-engineer the Platform; use automated bulk extraction tools; circumvent security features; upload unlawful content; overburden Bryzos infrastructure; use the Platform for competitive intelligence; or share exports with unauthorized third parties.'),

        h('5. INTELLECTUAL PROPERTY'),
        p('Bryzos owns the Platform, its software, design, default library, and all associated IP. You retain ownership of Your Data and custom content. You may use and clone the default library for internal analytics purposes only — redistribution is prohibited. Feedback you provide may be used by Bryzos freely without compensation.'),

        h('6. PRIVACY'),
        p('Bryzos collects account information, usage data (retained in audit logs), and technical data solely to provide and improve the Platform. Bryzos does not sell your information. The Platform is built on Supabase and Amazon Web Services infrastructure.'),

        h('7. AVAILABILITY AND SERVICE LEVELS'),
        p('The Platform is provided on an "as available" basis. No uptime guarantee or SLA applies unless separately executed in writing. Sync jobs depend on your upstream data source connectivity.'),

        h('8. DISCLAIMERS'),
        p('THE PLATFORM IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND. BRYZOS DOES NOT WARRANT THAT THE PLATFORM WILL BE UNINTERRUPTED, ERROR-FREE, OR THAT DATA WILL BE COMPLETE OR ACCURATE. YOUR USE AND RELIANCE ON PLATFORM DATA IS AT YOUR OWN RISK.'),

        h('9. LIMITATION OF LIABILITY'),
        p('TO THE MAXIMUM EXTENT PERMITTED BY LAW, BRYZOS WILL NOT BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES. BRYZOS\'S TOTAL CUMULATIVE LIABILITY WILL NOT EXCEED THE GREATER OF AMOUNTS PAID IN THE PRIOR 12 MONTHS OR \$100.'),

        h('10. INDEMNIFICATION'),
        p('You agree to indemnify Bryzos against claims arising from your violation of these Terms, misuse of the Platform, violation of applicable law, or infringement of third-party rights through Your Data.'),

        h('11. TERMINATION'),
        p('Bryzos may suspend or terminate your access if you violate these Terms, your Organization\'s access is terminated, your use poses a security risk, or continued provision is no longer viable. Upon termination, access ceases immediately and data is retained per Section 3.6.'),

        h('12. MODIFICATIONS'),
        p('Bryzos may update these Terms at any time with material changes communicated at least 14 days in advance via in-Platform notification or email. Continued use after the effective date constitutes acceptance.'),

        h('13. GOVERNING LAW AND DISPUTES'),
        p('These Terms are governed by the laws of the State of Delaware. Disputes will be brought exclusively in state or federal courts in St. Louis, Missouri. All claims must be brought individually — no class actions.'),

        h('14. GENERAL'),
        p('These Terms constitute the entire agreement regarding the Platform. If any provision is unenforceable, the remainder continues in effect. Bryzos\'s failure to enforce any provision is not a waiver.'),

        h('15. CONTACT'),
        p('Questions or security concerns: legal@bryzos.com  •  bryzos.com'),

        const SizedBox(height: 16),
        Text(
          'Last reviewed: May 29, 2026',
          style: body.copyWith(fontSize: 11, color: OpticsColors.textMuted.withOpacity(0.6)),
        ),
      ],
    );
  }

  // ── Success confirmation screen ──────────────────────────────────────────

  Widget _successConfirmation() {
    final orgName = _acceptedTenantName.isEmpty ? 'the organization' : _acceptedTenantName;
    return _layout(
      title: 'ORGANIZATION ADDED',
      subtitle: '',
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: OpticsColors.surface,
            borderRadius: BorderRadius.circular(OpticsRadii.md),
            border: Border.all(color: const Color(0xFF3DB8FF).withOpacity(0.3)),
          ),
          child: Column(
            children: [
              const Icon(Icons.check_circle_outline, color: Color(0xFF3DB8FF), size: 48),
              const SizedBox(height: 14),
              Text(
                orgName.toUpperCase(),
                style: OpticsTextStyles.headingMd,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'has been added to your Network Analytics account.',
                style: OpticsTextStyles.bodySm,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'You can switch between organizations in your Organization Settings.',
                style: OpticsTextStyles.bodySm.copyWith(color: OpticsColors.textMuted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => context.go('/dashboards'),
          child: const Text('GO TO DASHBOARDS'),
        ),
      ],
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Widget _layout({
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return SingleChildScrollView(
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
          if (title.isNotEmpty) ...[
            Text(title.toUpperCase(), style: OpticsTextStyles.headingXl),
            const SizedBox(height: 6),
          ],
          if (subtitle.isNotEmpty) ...[
            Text(subtitle, style: OpticsTextStyles.bodySm),
            const SizedBox(height: 22),
          ],
          ...children,
        ],
      ),
    );
  }

  Widget _inviteSummary(Map<String, dynamic> p) {
    final tenantName = (p['tenant_name'] ?? '').toString();
    final role = (p['role'] ?? '').toString();
    final invitedEmail = (p['email'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summaryRow('Organization', tenantName.isEmpty ? '(unknown)' : tenantName),
          const SizedBox(height: 6),
          _summaryRow('Your role', _humanRole(role)),
          const SizedBox(height: 6),
          _summaryRow('Invited email', invitedEmail),
        ],
      ),
    );
  }

  Widget _summaryRow(String k, String v) {
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(k, style: OpticsTextStyles.bodySm.copyWith(color: OpticsColors.textMuted)),
        ),
        Expanded(child: Text(v, style: OpticsTextStyles.body)),
      ],
    );
  }

  Widget _errorBlock({
    required String title,
    required String body,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return _layout(
      title: title,
      subtitle: body,
      children: [
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ],
    );
  }

  String _humanRole(String r) {
    switch (r) {
      case 'owner': return 'Owner';
      case 'admin': return 'Admin';
      case 'editor': return 'Editor';
      case 'viewer': return 'Viewer';
    }
    return r;
  }
}
