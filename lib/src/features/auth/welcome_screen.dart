import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/theme.dart';

/// Post-onboarding "You're in!" screen — shown to brand-new users immediately
/// after they accept their first invite and create their account.
///
/// Gives them three options:
///   1. Continue in the browser (web app)
///   2. Download the macOS desktop app
///   3. Download the Windows desktop app
///
/// On non-web platforms (e.g. if someone opens the desktop app and somehow
/// ends up here), the download buttons are hidden and only "Go to Dashboard"
/// is shown.
class WelcomeScreen extends StatelessWidget {
  final String tenantName;
  const WelcomeScreen({super.key, this.tenantName = ''});

  static const _macDownloadUrl =
      'https://analytics.bryzos.com/downloads/NetworkAnalytics-macOS.dmg';
  static const _winDownloadUrl =
      'https://analytics.bryzos.com/downloads/NetworkAnalytics-Windows.exe';

  @override
  Widget build(BuildContext context) {
    final org = tenantName.isNotEmpty ? tenantName : 'your organization';
    return Scaffold(
      backgroundColor: OpticsColors.canvas,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ── Icon + headline ─────────────────────────────────────────
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: const Color(0xFF3DB8FF).withOpacity(0.4),
                      width: 1,
                    ),
                    color: OpticsColors.surface,
                  ),
                  child: const Icon(
                    Icons.check_circle_outline_rounded,
                    color: Color(0xFF3DB8FF),
                    size: 38,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  "YOU'RE IN!",
                  style: OpticsTextStyles.headline.copyWith(
                    fontSize: 22,
                    letterSpacing: 3,
                    color: OpticsColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  "You've been added to $org on Network Analytics.",
                  style: OpticsTextStyles.body.copyWith(
                    color: OpticsColors.textSecondary,
                    fontSize: 14,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                // ── Platform choice ─────────────────────────────────────────
                if (kIsWeb) ...[
                  Text(
                    'HOW WOULD YOU LIKE TO ACCESS NETWORK ANALYTICS?',
                    style: OpticsTextStyles.label.copyWith(
                      color: OpticsColors.textMuted,
                      fontSize: 11,
                      letterSpacing: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  // Continue in browser
                  _PlatformCard(
                    icon: Icons.language_rounded,
                    title: 'CONTINUE IN BROWSER',
                    subtitle: 'Use Network Analytics right here — no download required. Always up to date.',
                    accent: const Color(0xFF3DB8FF),
                    primary: true,
                    onTap: () => context.go('/dashboards'),
                  ),
                  const SizedBox(height: 12),
                  // Download Mac
                  _PlatformCard(
                    icon: Icons.laptop_mac_rounded,
                    title: 'DOWNLOAD FOR MAC',
                    subtitle: 'Native macOS desktop app for the best performance on Apple hardware.',
                    accent: const Color(0xFF9D7FEA),
                    onTap: () => _download(context, _macDownloadUrl),
                  ),
                  const SizedBox(height: 12),
                  // Download Windows
                  _PlatformCard(
                    icon: Icons.desktop_windows_rounded,
                    title: 'DOWNLOAD FOR WINDOWS',
                    subtitle: 'Native Windows desktop app for the full experience on PC.',
                    accent: const Color(0xFF4FC3F7),
                    onTap: () => _download(context, _winDownloadUrl),
                  ),
                ] else ...[
                  // Native desktop build — no download buttons needed
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => context.go('/dashboards'),
                      child: const Text('GO TO MY DASHBOARD'),
                    ),
                  ),
                ],

                const SizedBox(height: 32),
                TextButton(
                  onPressed: () => context.go('/dashboards'),
                  child: Text(
                    'SKIP — GO TO DASHBOARD',
                    style: OpticsTextStyles.bodySm.copyWith(
                      color: OpticsColors.textMuted,
                      fontSize: 11,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _download(BuildContext context, String url) {
    // On web we can open the download URL directly; flutter_web does support
    // url_launcher but we keep the dependency footprint minimal — use the
    // platform's window.open equivalent via a simple anchor navigation.
    // GoRouter can't navigate to external URLs, so we use a workaround:
    // show a bottom-sheet with the link so users can click it.
    showModalBottomSheet(
      context: context,
      backgroundColor: OpticsColors.surfaceElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _DownloadSheet(url: url),
    );
  }
}

class _PlatformCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final bool primary;
  final VoidCallback onTap;

  const _PlatformCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    this.primary = false,
    required this.onTap,
  });

  @override
  State<_PlatformCard> createState() => _PlatformCardState();
}

class _PlatformCardState extends State<_PlatformCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: widget.primary
                ? widget.accent.withOpacity(_hovered ? 0.18 : 0.10)
                : OpticsColors.surface,
            borderRadius: BorderRadius.circular(OpticsRadii.md),
            border: Border.all(
              color: _hovered
                  ? widget.accent.withOpacity(0.6)
                  : widget.primary
                      ? widget.accent.withOpacity(0.3)
                      : OpticsColors.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: widget.accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(widget.icon, color: widget.accent, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: OpticsTextStyles.label.copyWith(
                        color: _hovered ? widget.accent : OpticsColors.textPrimary,
                        fontSize: 12,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.subtitle,
                      style: OpticsTextStyles.bodySm.copyWith(
                        color: OpticsColors.textMuted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: _hovered ? widget.accent : OpticsColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadSheet extends StatelessWidget {
  final String url;
  const _DownloadSheet({required this.url});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DOWNLOAD', style: OpticsTextStyles.label.copyWith(letterSpacing: 1.5)),
          const SizedBox(height: 12),
          Text(
            'Copy and open the link below in a new tab to start your download:',
            style: OpticsTextStyles.bodySm.copyWith(color: OpticsColors.textSecondary),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: OpticsColors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: OpticsColors.border),
            ),
            child: SelectableText(
              url,
              style: OpticsTextStyles.bodySm.copyWith(
                color: const Color(0xFF3DB8FF),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('CLOSE'),
            ),
          ),
        ],
      ),
    );
  }
}
