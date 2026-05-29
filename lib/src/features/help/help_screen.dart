import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/theme.dart';

/// In-app Help & Getting Started page.
///
/// Static content for v1 — covers the most common questions colleagues hit
/// in the first week.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OpticsColors.canvas,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('HELP & GETTING STARTED',
                    style: OpticsTextStyles.sectionLabel),
                const SizedBox(height: 8),
                const Text('NETWORK ANALYTICS - APP DETAILS',
                    style: OpticsTextStyles.headingXl),
                const SizedBox(height: 24),
                const _HelpSection(
                  title: 'Dashboards',
                  bullets: [
                    'Open a dashboard from the "Dashboards" tab on the left navigation panel.',
                    'Each card is a widget — hover to see the tooltip, click to drill in.',
                    'Editors can drag widgets to reposition and grab the edge to resize.',
                    'Use "Dashboard Settings" to apply a global color scheme, time range, or refresh interval to all widgets at once. Click "Back to Original Format" to revert.',
                  ],
                ),
                const _HelpSection(
                  title: 'Reports Library',
                  bullets: [
                    'Open the "Reports Library" tab to see canned reports shipped with Network Analytics and any custom reports you or your team have created.',
                    'Clone any canned report to make your own editable copy — the original is never modified.',
                    'Drag one report row onto another to create a combined report that merges both sources.',
                    'Schedule a report from its row actions to receive PDF and/or Excel by email on a recurring cadence.',
                    'The Reports Library is also the catalog of metrics, widget presets, and canned reports. Drag any item onto a dashboard to add it as a widget.',
                    'Click "Combine" on two metrics in the Reports Library to create a dual-axis comparison chart.',
                  ],
                ),
                const _HelpSection(
                  title: 'Report Builder',
                  bullets: [
                    'Click "New Report" in the Reports Library to open the step-by-step Report Builder.',
                    'Step 1 — Tables: Choose your primary data table, then optionally add related tables via detected relationships.',
                    'Step 2 — Columns: Select which columns appear in the report. Columns are grouped by table for easy scanning.',
                    'Step 3 — Filters: Narrow rows with one or more filter conditions.',
                    'Step 4 — Group & Aggregate: Add GROUP BY dimensions and aggregate functions (SUM, COUNT, AVG, etc.).',
                    'Step 5 — Sort & Limit: Choose sort order and cap the number of result rows.',
                    'Step 6 — Visualize & Save: Pick a chart type, preview the live data, name the report, and save.',
                    'All saved reports appear in the Reports Library and can be edited, shared, scheduled, or exported at any time.',
                  ],
                ),
                const _HelpSection(
                  title: 'Roles & Invites',
                  bullets: [
                    'Owner — full control; can transfer ownership.',
                    'Admin — can invite teammates and change settings, but cannot transfer ownership.',
                    'Editor — can build dashboards, save library items, run reports.',
                    'Viewer — read-only across dashboards and reports.',
                    'Only owners and admins see the "Invite" button in Organization Settings.',
                  ],
                ),
                const _HelpSection(
                  title: 'Multiple Organizations',
                  bullets: [
                    'If you were invited to more than one organization, each appears as a tile under "Settings → Organizations".',
                    'Click "View Data" on a tile to switch into that org.',
                  ],
                ),
                // Additional Support — rendered last with tappable email
                _AdditionalSupportSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdditionalSupportSection extends StatelessWidget {
  const _AdditionalSupportSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ADDITIONAL SUPPORT', style: OpticsTextStyles.sectionLabel),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 7, right: 10),
                child: Icon(Icons.circle, size: 5, color: OpticsColors.accentCyan),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: OpticsTextStyles.bodySm.copyWith(height: 1.5),
                    children: [
                      const TextSpan(text: 'Email us at '),
                      TextSpan(
                        text: 'support@bryzos.com',
                        style: OpticsTextStyles.bodySm.copyWith(
                          height: 1.5,
                          color: OpticsColors.accentCyan,
                          decoration: TextDecoration.underline,
                          decorationColor: OpticsColors.accentCyan,
                        ),
                        recognizer: TapGestureRecognizer()
                          ..onTap = () async {
                            final uri = Uri.parse('mailto:support@bryzos.com');
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri);
                            }
                          },
                      ),
                      const TextSpan(text: ' for further assistance.'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  final String title;
  final List<String> bullets;
  const _HelpSection({required this.title, required this.bullets});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: OpticsTextStyles.sectionLabel),
          const SizedBox(height: 10),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 7, right: 10),
                    child: Icon(Icons.circle,
                        size: 5, color: OpticsColors.accentCyan),
                  ),
                  Expanded(
                    child: Text(b,
                        style: OpticsTextStyles.bodySm.copyWith(height: 1.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
