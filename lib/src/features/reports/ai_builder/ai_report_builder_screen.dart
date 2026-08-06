// Network Analytics — AI Report Builder screen.
//
// Route: `/reports/new` (replaces the previous direct entry into the manual
// CustomReportBuilderScreen). Layout:
//
//   * Hero landing view (default) — a large prompt input + "Build manually"
//     escape hatch below.
//   * After first submit, snaps into two-panel layout: chat on the left,
//     live preview on the right with Report View / Widget View toggle.
//
// Gating: The AI feature is Bryzos-only in v1.0. Non-Bryzos users see the
// legacy manual builder directly.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/supabase_repo.dart';
import '../../../design/theme.dart';
import '../../../shared/secure_error.dart';
import '../custom_builder/custom_report_builder_screen.dart';
import '../custom_builder/custom_report_query_v2.dart';
import '../custom_builder/sql_dialect_normalizer.dart';
import '../custom_builder/v2_report_view.dart';
import '../report_viewer_screen.dart' show restDataSourceIdProvider;
import 'ai_api.dart';
import 'ai_builder_state.dart';

/// Which mode the hero screen is in.
enum _HeroMode { ai, sql }

class AiReportBuilderScreen extends ConsumerStatefulWidget {
  const AiReportBuilderScreen({super.key});

  @override
  ConsumerState<AiReportBuilderScreen> createState() =>
      _AiReportBuilderScreenState();
}

class _AiReportBuilderScreenState
    extends ConsumerState<AiReportBuilderScreen> {
  final _heroCtrl = TextEditingController();
  final _followupCtrl = TextEditingController();
  final _chatScroll = ScrollController();

  // ── SQL builder state ─────────────────────────────────────────────────────
  _HeroMode _heroMode = _HeroMode.ai;
  final _sqlCtrl = TextEditingController();
  // The normalized query passed to the preview. Null = not yet run.
  CustomReportQueryV2? _sqlPreviewQuery;
  // Issues surfaced by the normalizer.
  List<SqlNormalizerIssue> _sqlIssues = const [];
  // Rewrites applied automatically.
  List<String> _sqlRewrites = const [];

  @override
  void dispose() {
    _heroCtrl.dispose();
    _followupCtrl.dispose();
    _chatScroll.dispose();
    _sqlCtrl.dispose();
    super.dispose();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScroll.hasClients) return;
      _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // Bryzos gate — non-Bryzos users get the manual builder directly.
    if (!isBryzosUser(ref)) {
      return const CustomReportBuilderScreen();
    }

    final st = ref.watch(aiBuilderProvider);
    ref.listen<AiBuilderState>(aiBuilderProvider, (_, __) {
      _scrollChatToBottom();
    });

    return Container(
      color: OpticsColors.canvas,
      child: st.bootstrapped
          ? _twoPanel(st)
          : _heroMode == _HeroMode.sql
              ? _sqlPanel()
              : _hero(),
    );
  }

  // ── HERO ──────────────────────────────────────────────────────────────────

  Widget _hero() {
    return Padding(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top-left page title — wrapped in a 36px-tall row so the title's
          // vertical position is identical to Reports Library (whose title
          // sits inside a row dominated by a 36px-tall search field).
          SizedBox(
            height: 36,
            child: Align(
              alignment: Alignment.centerLeft,
              child: const Text('REPORT BUILDER',
                  style: OpticsTextStyles.headingXl),
            ),
          ),
          const SizedBox(height: OpticsSpacing.md),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'WHAT REPORT WOULD YOU LIKE TO BUILD?',
                        textAlign: TextAlign.center,
                        style: OpticsTextStyles.headingLg,
                      ),
                      const SizedBox(height: OpticsSpacing.lg),
                      _heroPromptCard(),
                      const SizedBox(height: OpticsSpacing.md),
                      RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: OpticsTextStyles.bodyLight,
                          children: const [
                            TextSpan(
                              text: 'Helpful Tip: ',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: OpticsColors.textPrimary,
                              ),
                            ),
                            TextSpan(
                              text:
                                  'Describe your desired report in specific details. The more detail you provide, the better the result.',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 56),
                      _dividerOr(),
                      const SizedBox(height: 56),
                      Center(child: _manualBuildButton()),
                      const SizedBox(height: OpticsSpacing.sm),
                      Center(child: _sqlBuildButton()),
                      const SizedBox(height: OpticsSpacing.xl),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Manual-build escape hatch. Styled like a scaled-up filter chip
  // (rounded rect, dark elevated surface, thin border) — same visual
  // language as the "My Reports / Shared with Me / Canned" chips on
  // the Reports Library screen, sized up with more padding and a
  // larger font per Kelsey feedback.
  Widget _manualBuildButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.go('/reports/new/manual'),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 16,
          ),
          decoration: BoxDecoration(
            color: OpticsColors.surfaceElevated,
            borderRadius: BorderRadius.circular(OpticsRadii.md),
            border: Border.all(color: OpticsColors.border),
          ),
          child: Text(
            'Build from Manual Data Selection',
            style: OpticsTextStyles.body.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: OpticsColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _sqlBuildButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _heroMode = _HeroMode.sql),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 16,
          ),
          decoration: BoxDecoration(
            color: OpticsColors.surfaceElevated,
            borderRadius: BorderRadius.circular(OpticsRadii.md),
            border: Border.all(color: OpticsColors.border),
          ),
          child: Text(
            'Build from SQL Statement',
            style: OpticsTextStyles.body.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: OpticsColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _heroPromptCard() {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
      ),
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Multiline field. Enter submits; Shift+Enter inserts newline.
          // Uses Focus.onKeyEvent because Shortcuts is beaten by EditableText's
          // internal multiline handling on desktop/web.
          Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final isEnter =
                  event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.numpadEnter;
              if (!isEnter) return KeyEventResult.ignored;
              final shift = HardwareKeyboard.instance.isShiftPressed;
              if (shift) return KeyEventResult.ignored; // allow newline
              _submitHero();
              return KeyEventResult.handled;
            },
            child: TextField(
              controller: _heroCtrl,
              minLines: 3,
              maxLines: 8,
              textInputAction: TextInputAction.send,
              style: OpticsTextStyles.body,
              decoration: InputDecoration(
                hintText:
                    'e.g. Show me the top 10 grades by gross sales in the '
                    'last 30 days, or list quotes created per week over the '
                    'last 3 months.',
                hintStyle: OpticsTextStyles.bodyLight.copyWith(
                  color: OpticsColors.textMuted,
                ),
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(height: OpticsSpacing.md),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: _submitHero,
              icon: const Text('Generate'),
              label: const Icon(Icons.arrow_forward, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dividerOr() {
    return Row(
      children: [
        Expanded(child: Container(height: 1, color: OpticsColors.border)),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: OpticsSpacing.md),
          child: Text('OR', style: OpticsTextStyles.sectionLabel),
        ),
        Expanded(child: Container(height: 1, color: OpticsColors.border)),
      ],
    );
  }

  void _submitHero() {
    final v = _heroCtrl.text.trim();
    if (v.isEmpty) return;
    _heroCtrl.clear();
    ref.read(aiBuilderProvider.notifier).submit(v);
  }

  void _submitFollowup() {
    final v = _followupCtrl.text.trim();
    if (v.isEmpty) return;
    _followupCtrl.clear();
    ref.read(aiBuilderProvider.notifier).submit(v);
  }

  // ── SQL BUILDER PANEL ─────────────────────────────────────────────────────

  /// Run the current SQL through the normalizer and update the preview.
  void _runSql() {
    final raw = _sqlCtrl.text.trim();
    if (raw.isEmpty) return;
    final result = normalizeMySqlToPostgres(raw);
    final query = CustomReportQueryV2(
      useRawSql: true,
      rawSql: result.normalized,
    );
    setState(() {
      _sqlPreviewQuery = query;
      _sqlIssues = result.issues;
      _sqlRewrites = result.appliedRewrites;
    });
  }

  Widget _sqlPanel() {
    return Column(
      children: [
        // Header bar — page title + back button
        Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: OpticsSpacing.lg),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: OpticsColors.border)),
          ),
          child: Row(
            children: [
              InkWell(
                onTap: () => setState(() {
                  _heroMode = _HeroMode.ai;
                  _sqlPreviewQuery = null;
                  _sqlIssues = const [];
                  _sqlRewrites = const [];
                }),
                borderRadius: BorderRadius.circular(OpticsRadii.xs),
                child: Padding(
                  padding: const EdgeInsets.all(OpticsSpacing.xs),
                  child: Row(
                    children: [
                      const Icon(Icons.arrow_back_ios_new,
                          size: 13, color: OpticsColors.textSecondary),
                      const SizedBox(width: 4),
                      Text('BACK', style: OpticsTextStyles.sectionLabel),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: OpticsSpacing.md),
              const Text('SQL REPORT BUILDER',
                  style: OpticsTextStyles.headingXl),
            ],
          ),
        ),
        // Body — two columns
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left: SQL editor
              Expanded(flex: 5, child: _sqlEditorPane()),
              Container(width: 1, color: OpticsColors.border),
              // Right: live preview
              Expanded(flex: 7, child: _sqlPreviewPane()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sqlEditorPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pane header
        Container(
          height: _panelHeaderHeight,
          padding: const EdgeInsets.symmetric(horizontal: OpticsSpacing.lg),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: OpticsColors.border)),
          ),
          child: Row(
            children: [
              Text('SQL STATEMENT', style: OpticsTextStyles.sectionLabel),
              const Spacer(),
              // Run button
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _runSql,
                  borderRadius: BorderRadius.circular(OpticsRadii.sm),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: OpticsColors.accentCyan,
                      borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow,
                            size: 14, color: Colors.black),
                        const SizedBox(width: 5),
                        Text(
                          'Run',
                          style: OpticsTextStyles.body.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // SQL text area
        Expanded(
          child: Container(
            color: OpticsColors.surface,
            padding: const EdgeInsets.all(OpticsSpacing.md),
            child: TextField(
              controller: _sqlCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: OpticsColors.textPrimary,
                height: 1.6,
              ),
              decoration: InputDecoration(
                hintText:
                    'Paste or type your SQL here.\n\n'
                    'You can use the original AWS RDS table names — the system\n'
                    'will automatically translate them to the Supabase mirror names.\n\n'
                    'Example:\n'
                    '  SELECT u.first_name, u.last_name,\n'
                    '         COUNT(po.id) AS quote_count\n'
                    '  FROM user_purchase_order po\n'
                    '  JOIN user u ON po.buyer_email = u.email_id\n'
                    '  GROUP BY u.first_name, u.last_name\n'
                    '  ORDER BY quote_count DESC\n'
                    '  LIMIT 25',
                hintStyle: OpticsTextStyles.bodyLight.copyWith(
                  color: OpticsColors.textMuted,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
        // Normalizer feedback strip
        if (_sqlRewrites.isNotEmpty || _sqlIssues.isNotEmpty)
          _sqlFeedbackStrip(),
        // Bottom action bar
        _sqlActionBar(),
      ],
    );
  }

  Widget _sqlFeedbackStrip() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: BoxDecoration(
        color: OpticsColors.canvas,
        border: const Border(top: BorderSide(color: OpticsColors.border)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OpticsSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_sqlRewrites.isNotEmpty) ...[
              Text('AUTO-CORRECTED',
                  style: OpticsTextStyles.sectionLabel.copyWith(
                    color: OpticsColors.accentGreen,
                    fontSize: 10,
                  )),
              for (final r in _sqlRewrites)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check,
                          size: 11, color: OpticsColors.accentGreen),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(r,
                            style: OpticsTextStyles.bodySm
                                .copyWith(fontSize: 11)),
                      ),
                    ],
                  ),
                ),
            ],
            if (_sqlIssues.isNotEmpty) ...[
              if (_sqlRewrites.isNotEmpty)
                const SizedBox(height: OpticsSpacing.xs),
              for (final issue in _sqlIssues)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        issue.severity == SqlIssueSeverity.error
                            ? Icons.error_outline
                            : issue.severity == SqlIssueSeverity.warning
                                ? Icons.warning_amber_outlined
                                : Icons.info_outline,
                        size: 11,
                        color: issue.severity == SqlIssueSeverity.error
                            ? OpticsColors.danger
                            : issue.severity == SqlIssueSeverity.warning
                                ? OpticsColors.accentOrange
                                : OpticsColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          issue.message,
                          style: OpticsTextStyles.bodySm.copyWith(
                            fontSize: 11,
                            color: issue.severity == SqlIssueSeverity.error
                                ? OpticsColors.danger
                                : issue.severity == SqlIssueSeverity.warning
                                    ? OpticsColors.accentOrange
                                    : OpticsColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sqlActionBar() {
    final hasQuery = _sqlPreviewQuery != null;
    final hasErrors =
        _sqlIssues.any((i) => i.severity == SqlIssueSeverity.error);
    final canSave = hasQuery && !hasErrors;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OpticsColors.border)),
        color: OpticsColors.canvas,
      ),
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: Wrap(
        spacing: OpticsSpacing.sm,
        runSpacing: OpticsSpacing.sm,
        children: [
          _actionBtn(
            label: 'Save Report',
            icon: Icons.save_outlined,
            primary: true,
            enabled: canSave,
            onTap: () => _saveSqlAsReport(),
          ),
          _actionBtn(
            label: 'Open in Manual Builder',
            icon: Icons.edit_outlined,
            primary: false,
            enabled: canSave,
            onTap: () => _openSqlInManual(),
          ),
        ],
      ),
    );
  }

  Widget _sqlPreviewPane() {
    return Column(
      children: [
        // Pane header
        Container(
          height: _panelHeaderHeight,
          padding: const EdgeInsets.symmetric(horizontal: OpticsSpacing.lg),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: OpticsColors.border)),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('PREVIEW', style: OpticsTextStyles.sectionLabel),
          ),
        ),
        // Preview body
        Expanded(child: _sqlPreviewBody()),
      ],
    );
  }

  Widget _sqlPreviewBody() {
    final q = _sqlPreviewQuery;
    if (q == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.code,
                  size: 40, color: OpticsColors.textMuted),
              const SizedBox(height: OpticsSpacing.md),
              Text(
                'Enter a SQL statement and press Run to see a live preview.',
                style: OpticsTextStyles.bodyLight,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Block rendering if there are hard errors from the normalizer.
    final hasErrors =
        _sqlIssues.any((i) => i.severity == SqlIssueSeverity.error);
    if (hasErrors) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.xl),
          child: Text(
            'Fix the errors shown in the editor before running.',
            style: OpticsTextStyles.bodyLight
                .copyWith(color: OpticsColors.danger),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final dsAsync = ref.watch(restDataSourceIdProvider);
    return dsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: OpticsColors.accentCyan),
      ),
      error: (e, _) => Center(
        child: SecureErrorText(
          genericMessage: 'Could not load the data source.',
          error: e,
        ),
      ),
      data: (dsId) {
        if (dsId == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(OpticsSpacing.xl),
              child: Text(
                'No REST data source configured for this tenant.',
                style: OpticsTextStyles.bodyLight,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: V2ReportView(query: q, dataSourceId: dsId),
        );
      },
    );
  }

  Future<void> _saveSqlAsReport() async {
    final q = _sqlPreviewQuery;
    if (q == null) return;
    final name = await _promptForName('report');
    if (name == null || name.isEmpty) return;
    try {
      final layout = {
        'pages': [
          {'title': name, 'widgets': const <Map<String, dynamic>>[]}
        ],
        'builder': {
          'view': 'sql',
          'query_v2': q.toJson(),
        },
      };
      final repo = ref.read(repoProvider);
      final row = await repo.createReportRow(
        name: name,
        layout: layout,
        description: 'SQL report',
      );
      final id = row['id'] as String?;
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved report "$name".')));
      if (id != null) {
        context.go('/reports/${Uri.encodeComponent(id)}');
      }
    } catch (e) {
      if (!mounted) return;
      showSecureErrorSnackBar(context, ref, 'Could not save the report.', e);
    }
  }

  void _openSqlInManual() {
    final q = _sqlPreviewQuery;
    if (q == null) return;
    aiHandoffQuery = q.toJson();
    if (!mounted) return;
    context.go('/reports/new/manual');
  }

  // ── TWO-PANEL ─────────────────────────────────────────────────────────────

  Widget _twoPanel(AiBuilderState st) {
    return Row(
      children: [
        Expanded(flex: 5, child: _chatPanel(st)),
        Container(width: 1, color: OpticsColors.border),
        Expanded(flex: 7, child: _previewPanel(st)),
      ],
    );
  }

  Widget _chatPanel(AiBuilderState st) {
    return Container(
      color: OpticsColors.canvas,
      child: Column(
        children: [
          _chatHeader(st),
          Container(height: 1, color: OpticsColors.border),
          Expanded(child: _chatBody(st)),
          _chatInput(st),
        ],
      ),
    );
  }

  // Fixed header height shared by chat panel and preview panel so the
  // two header bars are pixel-aligned across the divider.
  static const double _panelHeaderHeight = 56;

  Widget _chatHeader(AiBuilderState st) {
    return SizedBox(
      height: _panelHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OpticsSpacing.lg),
        child: Row(
          children: [
            Text('CONVERSATION', style: OpticsTextStyles.sectionLabel),
            const Spacer(),
            _iconBtn(
              icon: Icons.undo,
              enabled: st.canUndo,
              tooltip: 'Undo',
              onTap: () => ref.read(aiBuilderProvider.notifier).undo(),
            ),
            const SizedBox(width: OpticsSpacing.xs),
            _iconBtn(
              icon: Icons.redo,
              enabled: st.canRedo,
              tooltip: 'Redo',
              onTap: () => ref.read(aiBuilderProvider.notifier).redo(),
            ),
            const SizedBox(width: OpticsSpacing.sm),
            _iconBtn(
              icon: Icons.refresh,
              enabled: true,
              tooltip: 'Start over',
              onTap: () {
                ref.read(aiBuilderProvider.notifier).reset();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required bool enabled,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(OpticsRadii.xs),
        child: Container(
          padding: const EdgeInsets.all(OpticsSpacing.xs),
          child: Icon(
            icon,
            size: 16,
            color: enabled
                ? OpticsColors.textSecondary
                : OpticsColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _chatBody(AiBuilderState st) {
    return ListView(
      controller: _chatScroll,
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      children: [
        for (final m in st.messages) _messageBubble(m),
        if (st.pendingLibraryMatches.isNotEmpty)
          _libraryMatchList(st),
        if (st.isCheckingLibrary)
          _statusRow('Checking your library…'),
        if (st.isGenerating) _statusRow('Building your report…'),
        if (st.errorMessage != null && isBryzosUser(ref))
          Padding(
            padding: const EdgeInsets.only(top: OpticsSpacing.sm),
            child: Text(
              st.errorMessage!,
              style: OpticsTextStyles.bodySm
                  .copyWith(color: OpticsColors.danger),
            ),
          ),
      ],
    );
  }

  Widget _messageBubble(ChatMessage m) {
    final isUser = m.role == ChatRole.user;
    return Padding(
      padding: const EdgeInsets.only(bottom: OpticsSpacing.md),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(
            isUser ? 'YOU' : 'SYSTEM',
            style: OpticsTextStyles.sectionLabel.copyWith(
              color: isUser
                  ? OpticsColors.accentCyan
                  : OpticsColors.textSecondary,
            ),
          ),
          const SizedBox(height: OpticsSpacing.xs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: OpticsSpacing.md,
              vertical: OpticsSpacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: isUser
                  ? OpticsColors.surfaceElevated
                  : OpticsColors.surface,
              border: Border.all(color: OpticsColors.border),
              borderRadius: BorderRadius.circular(OpticsRadii.md),
            ),
            child: Text(m.content, style: OpticsTextStyles.body),
          ),
          if (!isUser && m.providerUsed != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _providerBadge(m),
                style: OpticsTextStyles.bodySm.copyWith(
                  fontSize: 10,
                  color: OpticsColors.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _providerBadge(ChatMessage m) {
    final parts = <String>[];
    if (m.providerUsed != null) {
      parts.add(m.providerUsed!.toUpperCase());
    }
    if (m.modelUsed != null) parts.add(m.modelUsed!);
    if (m.latencyMs != null) parts.add('${m.latencyMs}ms');
    return parts.join(' · ');
  }

  Widget _libraryMatchList(AiBuilderState st) {
    return Container(
      margin: const EdgeInsets.only(bottom: OpticsSpacing.md),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('POSSIBLE MATCHES', style: OpticsTextStyles.sectionLabel),
          const SizedBox(height: OpticsSpacing.sm),
          for (final match in st.pendingLibraryMatches)
            _libraryMatchRow(match),
          const SizedBox(height: OpticsSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                // Continue building anew — use the most recent user prompt.
                final lastUser = st.messages
                    .lastWhere((m) => m.role == ChatRole.user,
                        orElse: () => ChatMessage(
                            role: ChatRole.user,
                            content: '',
                            at: DateTime.now()))
                    .content;
                ref
                    .read(aiBuilderProvider.notifier)
                    .proceedFromLibraryPrompt(lastUser);
              },
              child: Text(
                'NONE OF THESE — BUILD NEW',
                style: OpticsTextStyles.sectionLabel.copyWith(
                  color: OpticsColors.accentCyan,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _libraryMatchRow(LibraryMatch m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              border: Border.all(color: OpticsColors.border),
              borderRadius: BorderRadius.circular(OpticsRadii.xs),
            ),
            child: Text(
              m.kind.toUpperCase(),
              style: OpticsTextStyles.sectionLabel.copyWith(fontSize: 9),
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.name, style: OpticsTextStyles.body),
                if (m.description.isNotEmpty)
                  Text(
                    m.description,
                    style: OpticsTextStyles.bodySm,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Text(
            '${(m.similarity * 100).toStringAsFixed(0)}%',
            style: OpticsTextStyles.bodySm
                .copyWith(color: OpticsColors.accentCyan),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          TextButton(
            onPressed: () {
              if (m.kind == 'report') {
                context.go('/reports/${Uri.encodeComponent(m.id)}');
              } else {
                // Widget → jump to Explore or single-widget viewer.
                context.go('/explore?widgetId=${Uri.encodeComponent(m.id)}');
              }
            },
            child: Text(
              'OPEN',
              style: OpticsTextStyles.sectionLabel.copyWith(
                color: OpticsColors.accentGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OpticsSpacing.sm),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: OpticsColors.accentCyan,
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Text(label, style: OpticsTextStyles.bodySm),
        ],
      ),
    );
  }

  Widget _chatInput(AiBuilderState st) {
    // Fixed height so the send button and the text field are visually
    // identical. Plain Enter submits; Shift+Enter inserts a newline
    // (via TextInputAction.newline on the shortcut).
    const double inputHeight = 44;
    final busy = st.isGenerating || st.isCheckingLibrary;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OpticsColors.border)),
        color: OpticsColors.canvas,
      ),
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SizedBox(
              height: inputHeight,
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is! KeyDownEvent) return KeyEventResult.ignored;
                  final isEnter =
                      event.logicalKey == LogicalKeyboardKey.enter ||
                          event.logicalKey == LogicalKeyboardKey.numpadEnter;
                  if (!isEnter) return KeyEventResult.ignored;
                  if (HardwareKeyboard.instance.isShiftPressed) {
                    return KeyEventResult.ignored;
                  }
                  _submitFollowup();
                  return KeyEventResult.handled;
                },
                child: TextField(
                controller: _followupCtrl,
                maxLines: 1,
                style: OpticsTextStyles.body,
                textAlignVertical: TextAlignVertical.center,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submitFollowup(),
                decoration: InputDecoration(
                  hintText: 'Refine the report…',
                  hintStyle: OpticsTextStyles.bodyLight.copyWith(
                    color: OpticsColors.textMuted,
                  ),
                  filled: true,
                  fillColor: OpticsColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    borderSide: const BorderSide(color: OpticsColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    borderSide: const BorderSide(color: OpticsColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    borderSide: const BorderSide(
                        color: OpticsColors.accentCyan, width: 1.2),
                  ),
                  // Vertically centered inside the 44px box:
                  // (44 - 20 line-height) / 2 = 12
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: OpticsSpacing.md,
                    vertical: 12,
                  ),
                ),
              ),
              ),
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          SizedBox(
            height: inputHeight,
            child: FilledButton(
              onPressed: busy ? null : _submitFollowup,
              style: FilledButton.styleFrom(
                backgroundColor: OpticsColors.accentCyan,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(OpticsRadii.sm),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: OpticsSpacing.lg,
                ),
                minimumSize: const Size(inputHeight, inputHeight),
              ),
              child: const Icon(Icons.arrow_forward, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ── PREVIEW PANEL ─────────────────────────────────────────────────────────

  Widget _previewPanel(AiBuilderState st) {
    return Container(
      color: OpticsColors.canvas,
      child: Column(
        children: [
          _previewHeader(st),
          Container(height: 1, color: OpticsColors.border),
          Expanded(child: _previewBody(st)),
          _previewActions(st),
        ],
      ),
    );
  }

  Widget _previewHeader(AiBuilderState st) {
    // Combined pill toggle — same pattern as Reports Library > Open Report
    // (Table View / Widget View). Two segments inside one rounded container.
    return SizedBox(
      height: _panelHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: OpticsSpacing.lg),
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                color: OpticsColors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: OpticsColors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _toggleBtn(
                    icon: Icons.description_outlined,
                    label: 'Report View',
                    active: st.previewMode == PreviewMode.report,
                    onTap: () => ref
                        .read(aiBuilderProvider.notifier)
                        .setPreviewMode(PreviewMode.report),
                  ),
                  _toggleBtn(
                    icon: Icons.bar_chart,
                    label: 'Widget View',
                    active: st.previewMode == PreviewMode.widget,
                    onTap: () => ref
                        .read(aiBuilderProvider.notifier)
                        .setPreviewMode(PreviewMode.widget),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleBtn({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? OpticsColors.accentCyan.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            Icon(icon,
                size: 14,
                color: active
                    ? OpticsColors.accentCyan
                    : OpticsColors.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active
                    ? OpticsColors.accentCyan
                    : OpticsColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _previewBody(AiBuilderState st) {
    final q = st.currentQuery;
    if (q == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.xl),
          child: Text(
            st.isGenerating
                ? 'Building your report…'
                : 'The preview will appear here.',
            style: OpticsTextStyles.bodyLight,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final dsAsync = ref.watch(restDataSourceIdProvider);
    return dsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: OpticsColors.accentCyan),
      ),
      error: (e, _) => Center(
        child: SecureErrorText(
          genericMessage: 'Could not load the data source.',
          error: e,
        ),
      ),
      data: (dsId) {
        if (dsId == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(OpticsSpacing.xl),
              child: Text(
                'No REST data source configured for this tenant.',
                style: OpticsTextStyles.bodyLight,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        // Both preview modes use the same V2 renderer for now; the toggle
        // affects future save actions and sizing hints. Widget mode wraps
        // it in a compact card frame; report mode gives it full breathing
        // room.
        final query = CustomReportQueryV2.fromJson(q);
        final content = Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: V2ReportView(query: query, dataSourceId: dsId),
        );
        if (st.previewMode == PreviewMode.widget) {
          return Padding(
            padding: const EdgeInsets.all(OpticsSpacing.lg),
            child: Container(
              constraints: const BoxConstraints(
                maxWidth: 460,
                maxHeight: 320,
              ),
              decoration: BoxDecoration(
                color: OpticsColors.surface,
                border: Border.all(color: OpticsColors.border),
                borderRadius: BorderRadius.circular(OpticsRadii.md),
              ),
              child: content,
            ),
          );
        }
        return content;
      },
    );
  }

  Widget _previewActions(AiBuilderState st) {
    final enabled = st.currentQuery != null;
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: OpticsColors.border)),
        color: OpticsColors.canvas,
      ),
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: Wrap(
        spacing: OpticsSpacing.sm,
        runSpacing: OpticsSpacing.sm,
        children: [
          _actionBtn(
            label: 'Save Report',
            icon: Icons.save_outlined,
            primary: true,
            enabled: enabled,
            onTap: () => _saveAsReport(st),
          ),
          _actionBtn(
            label: 'Save Widget',
            icon: Icons.dashboard_customize_outlined,
            primary: false,
            enabled: enabled,
            onTap: () => _saveAsWidget(st),
          ),
          _actionBtn(
            label: 'Open in Manual Builder',
            icon: Icons.edit_outlined,
            primary: false,
            enabled: enabled,
            onTap: () => _openInManual(st),
          ),
        ],
      ),
    );
  }

  // Preview action button — visually matches the "+ Add Widget" button on
  // the Dashboards screen (cyan pill, 14px icon, 12px mixed-case label,
  // 14x8 padding). Non-primary variants swap to elevated surface + border.
  Widget _actionBtn({
    required String label,
    required bool primary,
    required bool enabled,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    final bg = primary
        ? OpticsColors.accentCyan
        : OpticsColors.surfaceElevated;
    final fg = primary ? Colors.black : OpticsColors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
              border: primary
                  ? null
                  : Border.all(color: OpticsColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── SAVE ACTIONS ──────────────────────────────────────────────────────────

  Future<String?> _promptForName(String kind) async {
    final ctrl = TextEditingController(
      text: kind == 'report' ? 'New AI Report' : 'New AI Widget',
    );
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: Text('SAVE ${kind.toUpperCase()}',
            style: OpticsTextStyles.headingMd),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: OpticsTextStyles.body,
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: OpticsColors.accentCyan,
              foregroundColor: Colors.black,
            ),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAsReport(AiBuilderState st) async {
    final q = st.currentQuery;
    if (q == null) return;
    final name = await _promptForName('report');
    if (name == null || name.isEmpty) return;
    try {
      final layout = {
        'pages': [
          {'title': name, 'widgets': const <Map<String, dynamic>>[]}
        ],
        'builder': {
          'view': 'wizard',
          'query_v2': q,
        },
      };
      final repo = ref.read(repoProvider);
      final row = await repo.createReportRow(
        name: name,
        layout: layout,
        description: _lastUserPrompt(st),
      );
      final id = row['id'] as String?;
      if (id != null) {
        // Fire-and-forget indexing.
        final tenantId = repo.client.auth.currentUser
            ?.appMetadata['active_tenant_id'] as String?;
        if (tenantId != null) {
          ref
              .read(aiApiProvider)
              .indexItem(kind: 'report', id: id, tenantId: tenantId);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved report "$name".')),
      );
      if (id != null) {
        context.go('/reports/${Uri.encodeComponent(id)}');
      }
    } catch (e) {
      if (!mounted) return;
      showSecureErrorSnackBar(context, ref, 'Could not save the report.', e);
    }
  }

  Future<void> _saveAsWidget(AiBuilderState st) async {
    final q = st.currentQuery;
    if (q == null) return;
    // v1.0 keeps this simple: hand off to the manual builder's Save-Widget
    // path by opening the manual builder pre-populated. Full inline
    // widget-dashboard-picker will come in a follow-up.
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Save-as-widget flow will open in the manual builder for '
          'dashboard/placement selection.',
        ),
      ),
    );
    _openInManual(st);
  }

  Future<void> _openInManual(AiBuilderState st) async {
    final q = st.currentQuery;
    if (q == null) return;
    // Stash the JSON on the notifier so the manual builder can pick it up
    // via a Riverpod handoff provider.
    aiHandoffQuery = q;
    if (!mounted) return;
    context.go('/reports/new/manual');
  }

  String _lastUserPrompt(AiBuilderState st) {
    for (final m in st.messages.reversed) {
      if (m.role == ChatRole.user) return m.content;
    }
    return '';
  }
}

/// One-shot handoff so the manual builder can pick up an AI-generated
/// query when the user chooses "Open in Manual Builder". Consumed on
/// the manual builder's first hydrate, then cleared.
Map<String, dynamic>? aiHandoffQuery;

/// Intent used to bind Enter-to-submit on multiline text fields.
class _SubmitIntent extends Intent {
  const _SubmitIntent();
}
