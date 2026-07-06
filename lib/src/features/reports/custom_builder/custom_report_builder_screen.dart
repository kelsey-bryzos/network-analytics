// Optics — Custom Report Builder (ADR-0013, Phase B — revised layout)
//
// Explicit-join wizard for the "Build New Report" flow. Reads/writes the
// `custom_report_query_v2` JSON shape (see custom_report_query_v2.dart) and
// executes via the `rds_execute_query` RPC.
//
// Layout revision (2026-05-26):
//   * STEP 1 "TABLES" now combines primary + related-table selection on one
//     page so the user sees the whole query graph at a glance, ERP-style.
//   * STEP 2 "COLUMNS" renders columns as a single vertical list grouped by
//     table, not side-by-side chips. Easier to scan.
//   * Relationship lookup now normalizes mirror names so the chip cloud
//     surfaces the FKs stored in public.rds_relationships (which uses bare
//     table names like "user", while rds_catalog returns "rds_user").

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';

import '../../../data/models.dart';
import '../../../data/supabase_repo.dart';
import '../../../design/theme.dart';
import '../../../shared/secure_error.dart';
import '../report_viewer_screen.dart' show restDataSourceIdProvider;
import 'custom_report_query_v2.dart';
import 'custom_report_validator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────────────────────

final _catalogProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.read(repoProvider).rdsCatalog();
});

final _relsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  return ref.read(repoProvider).rdsRelations();
});

final _dataSourceProvider = restDataSourceIdProvider;

class _BuilderState {
  CustomReportQueryV2 query;
  int currentStep;
  String title;
  String? description;
  String? reportId;
  bool dirty;
  _BuilderState({
    required this.query,
    this.currentStep = 0,
    this.title = 'Untitled Report',
    this.description,
    this.reportId,
    this.dirty = false,
  });
}

class _BuilderNotifier extends StateNotifier<_BuilderState> {
  _BuilderNotifier() : super(_BuilderState(query: CustomReportQueryV2()));

  void hydrate({
    required String? reportId,
    required String title,
    required String? description,
    required CustomReportQueryV2 query,
  }) {
    state = _BuilderState(
      reportId: reportId,
      title: title,
      description: description,
      query: query,
    );
  }

  void setStep(int i) => state = _clone(currentStep: i);
  void setTitle(String v) => state = _clone(title: v, dirty: true);
  void setDescription(String? v) =>
      state = _clone(description: v, dirty: true);

  void mutate(void Function(CustomReportQueryV2 q) fn) {
    fn(state.query);
    state = _clone(dirty: true);
  }

  /// Toggle the Bryzos-only raw-SQL escape hatch. When entering raw mode for
  /// the first time we pre-seed the editor with the current wizard-generated
  /// SQL so the user has a starting point instead of an empty box.
  void setUseRawSql(bool v, {String? seed}) {
    state.query.useRawSql = v;
    if (v && (state.query.rawSql == null || state.query.rawSql!.trim().isEmpty)) {
      state.query.rawSql = seed;
    }
    state = _clone(dirty: true);
  }

  void setRawSql(String sql) {
    state.query.rawSql = sql;
    state = _clone(dirty: true);
  }

  _BuilderState _clone({
    int? currentStep,
    String? title,
    String? description,
    bool? dirty,
  }) =>
      _BuilderState(
        query: state.query,
        currentStep: currentStep ?? state.currentStep,
        title: title ?? state.title,
        description: description ?? state.description,
        reportId: state.reportId,
        dirty: dirty ?? state.dirty,
      );
}

final _builderProvider =
    StateNotifierProvider<_BuilderNotifier, _BuilderState>(
  (ref) => _BuilderNotifier(),
);

final _previewRowsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final st = ref.watch(_builderProvider);
  final dsId = await ref.watch(_dataSourceProvider.future);
  if (dsId == null) return const [];

  // Raw-SQL mode (Bryzos-only): bypass the wizard entirely.
  if (st.query.useRawSql) {
    final raw = (st.query.rawSql ?? '').trim();
    if (raw.isEmpty) return const [];
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return ref.read(repoProvider).rdsExecuteRawSqlBryzos(
          dataSourceId: dsId,
          sql: raw,
          preview: true,
        );
  }

  if (st.query.primaryTable == null) return const [];
  if (st.query.columns.isEmpty && st.query.aggregates.isEmpty) {
    return const [];
  }
  // Don't even attempt the round-trip if the query has blocking issues.
  // Surfacing the validator message is more useful than waiting for the
  // database to reject it.
  final report = validateCustomReportQuery(st.query);
  if (report.hasBlockers) {
    throw _PreviewBlockedException(report);
  }
  await Future<void>.delayed(const Duration(milliseconds: 250));
  return ref.read(repoProvider).rdsExecuteQuery(
        dataSourceId: dsId,
        query: st.query.toJson(),
        preview: true,
      );
});

/// Live validation report; cheap to recompute on every state change.
final _validationProvider = Provider<ValidationReport>((ref) {
  final st = ref.watch(_builderProvider);
  return validateCustomReportQuery(st.query);
});

/// Sentinel surfaced by `_previewRowsProvider` when validation has flagged
/// errors. The preview panel catches it and renders an actionable banner
/// instead of a raw exception trace.
class _PreviewBlockedException implements Exception {
  final ValidationReport report;
  _PreviewBlockedException(this.report);
  @override
  String toString() => 'Preview blocked by validation issues.';
}

// ─────────────────────────────────────────────────────────────────────────────
// Name normalization helpers — bridge rds_catalog (rds_xxx) ↔
// rds_relationships (bare xxx).
// ─────────────────────────────────────────────────────────────────────────────

/// Strip the `rds_` prefix when present. Used as the canonical key for
/// matching catalog tables against relationships.
String _bare(String t) =>
    t.startsWith('rds_') ? t.substring(4) : t;

/// Make an `rds_`-prefixed mirror name (idempotent).
String _mirror(String t) =>
    t.startsWith('rds_') ? t : 'rds_$t';

/// Pretty display from a table name: strip rds_, split on _, title-case.
String _displayName(String t) {
  final raw = _bare(t);
  return raw
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level screen.
// ─────────────────────────────────────────────────────────────────────────────

class CustomReportBuilderScreen extends ConsumerStatefulWidget {
  final String? reportId;
  const CustomReportBuilderScreen({super.key, this.reportId});

  @override
  ConsumerState<CustomReportBuilderScreen> createState() =>
      _CustomReportBuilderScreenState();
}

class _CustomReportBuilderScreenState
    extends ConsumerState<CustomReportBuilderScreen> {
  bool _hydrated = false;
  bool _saving = false;
  String? _lastError;
  bool _permissionChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionAndHydrate();
    });
  }

  /// Check if user has edit permission before allowing access to this screen.
  /// Viewers and guests are redirected back to /reports.
  Future<void> _checkPermissionAndHydrate() async {
    if (_permissionChecked) return;
    _permissionChecked = true;
    
    // Check permission using the same provider as the rest of the app
    final canEdit = ref.read(canEditProvider);
    if (!canEdit) {
      // User doesn't have permission — redirect to reports list
      if (mounted) {
        context.go('/reports');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You do not have permission to create or edit reports.'),
            backgroundColor: OpticsColors.danger,
          ),
        );
      }
      return;
    }
    
    // Permission OK — proceed with hydration
    _hydrate();
  }

  Future<void> _hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    final id = widget.reportId;
    if (id == null) {
      ref.read(_builderProvider.notifier).hydrate(
            reportId: null,
            title: 'Untitled Report',
            description: null,
            query: CustomReportQueryV2(),
          );
      return;
    }
    final client = ref.read(supabaseProvider);
    try {
      final row = await client
          .from('reports')
          .select('id, name, description, layout, query_version')
          .eq('id', id)
          .maybeSingle();
      if (row == null) return;
      final layout = (row['layout'] as Map?)?.cast<String, dynamic>() ?? {};
      final builder =
          (layout['builder'] as Map?)?.cast<String, dynamic>() ?? const {};
      final q = (builder['query_v2'] as Map?)?.cast<String, dynamic>();
      final query =
          q != null ? CustomReportQueryV2.fromJson(q) : CustomReportQueryV2();
      ref.read(_builderProvider.notifier).hydrate(
            reportId: id,
            title: (row['name'] as String?) ?? 'Untitled Report',
            description: row['description'] as String?,
            query: query,
          );
    } catch (e) {
      setState(() => _lastError = 'Failed to load report: $e');
    }
  }

  Future<void> _save({bool close = false}) async {
    final st = ref.read(_builderProvider);
    final client = ref.read(supabaseProvider);
    setState(() {
      _saving = true;
      _lastError = null;
    });
    try {
      final layout = {
        'pages': [
          {
            'title': st.title,
            'widgets': const <Map<String, dynamic>>[],
          }
        ],
        'builder': {
          'view': 'wizard',
          'query_v2': st.query.toJson(),
        },
      };
      final payload = {
        'name': st.title,
        'description': st.description,
        'layout': layout,
        'status': 'draft',
        'query_version': 2,
      };
      String? newId = st.reportId;
      if (newId == null) {
        final inserted = await client
            .from('reports')
            .insert(payload)
            .select('id')
            .single();
        newId = inserted['id'] as String?;
        if (newId != null) {
          ref.read(_builderProvider.notifier).hydrate(
                reportId: newId,
                title: st.title,
                description: st.description,
                query: st.query,
              );
        }
      } else {
        await client.from('reports').update(payload).eq('id', newId);
      }
      // ignore: unused_result
      ref.refresh(reportsProvider);
      if (!mounted) return;
      if (close && newId != null) {
        context.go('/reports/${Uri.encodeComponent(newId)}');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } catch (e) {
      setState(() => _lastError = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _publish() async {
    // Save first, then flip status to live
    await _save(close: false);
    final st = ref.read(_builderProvider);
    final reportId = st.reportId;
    if (reportId == null) return;
    try {
      await ref.read(repoProvider).setReportStatus(reportId, ReportStatus.live);
      ref.invalidate(reportsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${st.title}" published.')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        showSecureErrorSnackBar(context, ref, 'Publish failed.', e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(_builderProvider);
    final catalog = ref.watch(_catalogProvider);
    final rels = ref.watch(_relsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(st),
        if (_lastError != null)
          Container(
            margin: const EdgeInsets.symmetric(
                horizontal: OpticsSpacing.xl, vertical: OpticsSpacing.sm),
            padding: const EdgeInsets.all(OpticsSpacing.md),
            decoration: BoxDecoration(
              color: OpticsColors.danger.withValues(alpha: 0.08),
              border: Border.all(color: OpticsColors.danger),
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
            ),
            child: Text(_lastError!,
                style: const TextStyle(color: OpticsColors.danger)),
          ),
        Expanded(
          child: catalog.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
                child: SecureErrorText(
                  genericMessage: 'Failed to load catalog.',
                  error: e,
                )),
            data: (cat) => rels.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                  child: SecureErrorText(
                    genericMessage: 'Failed to load relationships.',
                    error: e,
                  )),
              data: (relMap) => _buildBody(st, cat, relMap),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(_BuilderState st) {
    // PERMISSION CHECK: Only editors+ can save reports
    final canEdit = ref.watch(canEditProvider);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: OpticsSpacing.xl, vertical: OpticsSpacing.xl),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OpticsColors.border)),
      ),
      child: Row(
        children: [
          const Text('REPORT BUILDER', style: OpticsTextStyles.headingXl),
          const Spacer(),
          // Save buttons only for editors+
          if (canEdit) ...[
            if (st.dirty)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: OpticsSpacing.sm, vertical: 4),
                decoration: BoxDecoration(
                  color: OpticsColors.accentOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(OpticsRadii.xs),
                ),
                child: Text(
                  'UNSAVED',
                  style: OpticsTextStyles.sectionLabel.copyWith(
                    color: OpticsColors.accentOrange,
                    fontSize: 11,
                  ),
                ),
              ),
            const SizedBox(width: OpticsSpacing.md),
            OutlinedButton.icon(
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'),
              onPressed: _saving ? null : () => _save(close: false),
            ),
            const SizedBox(width: OpticsSpacing.sm),
            ElevatedButton.icon(
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Save & Close'),
              onPressed: _saving ? null : () => _save(close: true),
            ),
            const SizedBox(width: OpticsSpacing.sm),
            ElevatedButton.icon(
              icon: const Icon(Icons.publish, size: 16),
              label: const Text('Publish'),
              onPressed: _saving ? null : _publish,
              style: ElevatedButton.styleFrom(
                backgroundColor: OpticsColors.accentGreen,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: OpticsSpacing.md),
          ],
          IconButton(
            tooltip: 'Back to Reports Library',
            icon: const Icon(Icons.close, size: 18, color: OpticsColors.textSecondary),
            onPressed: () => context.go('/reports'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    _BuilderState st,
    List<Map<String, dynamic>> catalog,
    Map<String, dynamic> relMap,
  ) {
    final rawLocked = st.query.useRawSql;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 240,
          child: IgnorePointer(
            ignoring: rawLocked,
            child: Opacity(
              opacity: rawLocked ? 0.4 : 1.0,
              child: _StepRail(
                currentStep: st.currentStep,
                onSelect: (i) => ref.read(_builderProvider.notifier).setStep(i),
                query: st.query,
              ),
            ),
          ),
        ),
        const VerticalDivider(width: 1, color: OpticsColors.border),
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Report name input — centered over this panel ──
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: OpticsSpacing.xl, vertical: OpticsSpacing.md),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: OpticsColors.border)),
                ),
                child: _ReportTitleInput(
                  key: ValueKey('title-${st.reportId ?? "new"}'),
                  initialValue: st.title,
                  onChanged: (v) => ref.read(_builderProvider.notifier)
                      .setTitle(v.trim().isEmpty ? 'Untitled Report' : v.trim()),
                ),
              ),
              if (rawLocked) _RawSqlLockBanner(
                onExit: () =>
                    ref.read(_builderProvider.notifier).setUseRawSql(false),
              ),
              Expanded(
                child: IgnorePointer(
                  ignoring: rawLocked,
                  child: Opacity(
                    opacity: rawLocked ? 0.35 : 1.0,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(OpticsSpacing.xl),
                      child: _StepContent(
                        step: st.currentStep,
                        query: st.query,
                        catalog: catalog,
                        relMap: relMap,
                        onMutate: (fn) =>
                            ref.read(_builderProvider.notifier).mutate(fn),
                        title: st.title,
                        description: st.description,
                        onTitleChanged: (v) =>
                            ref.read(_builderProvider.notifier).setTitle(v),
                        onDescriptionChanged: (v) =>
                            ref.read(_builderProvider.notifier).setDescription(v),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1, color: OpticsColors.border),
        Expanded(
          flex: 4,
          child: _PreviewPanel(query: st.query),
        ),
      ],
    );
  }
}

/// Banner shown over the wizard area when raw-SQL mode is active. Includes
/// an inline "Exit raw SQL mode" affordance so the user isn't trapped.
class _RawSqlLockBanner extends StatelessWidget {
  final VoidCallback onExit;
  const _RawSqlLockBanner({required this.onExit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: OpticsSpacing.lg, vertical: OpticsSpacing.sm),
      decoration: BoxDecoration(
        color: OpticsColors.accentCyan.withValues(alpha: 0.08),
        border: const Border(
          bottom: BorderSide(color: OpticsColors.border),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline,
              size: 14, color: OpticsColors.accentCyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Wizard locked — editing raw SQL on the right.',
              style: OpticsTextStyles.bodySm
                  .copyWith(color: OpticsColors.textSecondary),
            ),
          ),
          TextButton.icon(
            onPressed: onExit,
            icon: const Icon(Icons.undo, size: 14),
            label: const Text('Exit raw SQL'),
            style: TextButton.styleFrom(
              foregroundColor: OpticsColors.accentCyan,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step rail.
// ─────────────────────────────────────────────────────────────────────────────

/// Stateful title input so the controller isn't recreated on every rebuild.
class _ReportTitleInput extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;
  const _ReportTitleInput({super.key, required this.initialValue, required this.onChanged});
  @override
  State<_ReportTitleInput> createState() => _ReportTitleInputState();
}

class _ReportTitleInputState extends State<_ReportTitleInput> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      style: const TextStyle(
        fontFamily: OpticsTextStyles.bodyFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: OpticsColors.textPrimary,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Untitled Report',
        filled: true,
        fillColor: OpticsColors.surfaceElevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          borderSide: const BorderSide(color: OpticsColors.accentCyan, width: 1.5),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _StepRail extends ConsumerWidget {
  final int currentStep;
  final ValueChanged<int> onSelect;
  final CustomReportQueryV2 query;
  const _StepRail({
    required this.currentStep,
    required this.onSelect,
    required this.query,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(_validationProvider);
    final steps = <(String, String, String)>[
      ('TABLES', 'Primary + related', _summaryTables()),
      ('COLUMNS', 'Pick columns', '${query.columns.length} selected'),
      ('FILTERS', 'Filter rows', '${query.filters.length} filters'),
      ('GROUP', 'Group & aggregate',
          '${query.groupBy.length} group · ${query.aggregates.length} agg'),
      ('SORT', 'Sort & limit', _summarySort()),
      ('VISUALIZE', 'Chart & save', query.viz.chartType.toUpperCase()),
    ];
    return Container(
      color: OpticsColors.canvas,
      padding: const EdgeInsets.symmetric(
          horizontal: OpticsSpacing.md, vertical: OpticsSpacing.lg),
      child: ListView.separated(
        itemCount: steps.length,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (_, i) {
          final (label, title, summary) = steps[i];
          final active = i == currentStep;
          final stepWorst = report.worstForStep(i);
          final stepIssues = report.forStep(i).toList();
          final tooltipMsg = stepIssues.isEmpty
              ? null
              : stepIssues.map((e) => '• ${e.title}').join('\n');
          return InkWell(
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: OpticsSpacing.md, vertical: OpticsSpacing.sm),
              decoration: BoxDecoration(
                color: active
                    ? OpticsColors.accentCyan.withValues(alpha: 0.08)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
                border: Border.all(
                  color: active
                      ? OpticsColors.accentCyan.withValues(alpha: 0.4)
                      : OpticsColors.border,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? OpticsColors.accentCyan
                              : OpticsColors.surface,
                          borderRadius:
                              BorderRadius.circular(OpticsRadii.xs),
                        ),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            color: active
                                ? Colors.black
                                : OpticsColors.textSecondary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: OpticsSpacing.sm),
                      Text(label,
                          style: OpticsTextStyles.sectionLabel.copyWith(
                            color: active
                                ? OpticsColors.accentCyan
                                : OpticsColors.textSecondary,
                          )),
                      const Spacer(),
                      if (stepWorst != null)
                        Tooltip(
                          message: tooltipMsg ?? '',
                          waitDuration: const Duration(milliseconds: 250),
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: stepWorst == IssueSeverity.error
                                  ? OpticsColors.danger
                                  : OpticsColors.warning,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(title, style: OpticsTextStyles.body),
                  const SizedBox(height: 2),
                  Text(summary,
                      style: OpticsTextStyles.bodySm.copyWith(
                          color: OpticsColors.textMuted)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _summaryTables() {
    if (query.primaryTable == null) return 'Not selected';
    final parts = <String>[_displayName(query.primaryTable!)];
    parts.addAll(query.joins.map((j) => _displayName(j.table)));
    final s = parts.join(' · ');
    return s.length > 40 ? '${s.substring(0, 40)}…' : s;
  }

  String _summarySort() {
    if (query.orderBy.isEmpty && query.limit == null) return 'Default';
    final parts = <String>[];
    if (query.orderBy.isNotEmpty) {
      parts.add(query.orderBy.map((o) => '${o.alias} ${o.dir}').join(', '));
    }
    if (query.limit != null) parts.add('LIMIT ${query.limit}');
    return parts.join(' · ');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Step content router.
// ─────────────────────────────────────────────────────────────────────────────

class _StepContent extends StatelessWidget {
  final int step;
  final CustomReportQueryV2 query;
  final List<Map<String, dynamic>> catalog;
  final Map<String, dynamic> relMap;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  final String title;
  final String? description;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onDescriptionChanged;

  const _StepContent({
    required this.step,
    required this.query,
    required this.catalog,
    required this.relMap,
    required this.onMutate,
    required this.title,
    required this.description,
    required this.onTitleChanged,
    required this.onDescriptionChanged,
  });

  @override
  Widget build(BuildContext context) {
    switch (step) {
      case 0:
        return _Step1Tables(
            query: query,
            catalog: catalog,
            relMap: relMap,
            onMutate: onMutate);
      case 1:
        return _Step2Columns(
            query: query, catalog: catalog, onMutate: onMutate);
      case 2:
        return _Step3Filters(
            query: query, catalog: catalog, onMutate: onMutate);
      case 3:
        return _Step4Group(
            query: query, catalog: catalog, onMutate: onMutate);
      case 4:
        return _Step5Sort(query: query, onMutate: onMutate);
      case 5:
        return _Step6Visualize(
          query: query,
          onMutate: onMutate,
          title: title,
          description: description,
          onTitleChanged: onTitleChanged,
          onDescriptionChanged: onDescriptionChanged,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

Widget _stepHeader(String label, String title, String help) {
  return Padding(
    padding: const EdgeInsets.only(bottom: OpticsSpacing.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: 6),
        Text(title.toUpperCase(), style: OpticsTextStyles.headingMd),
        const SizedBox(height: 6),
        Text(help,
            style: OpticsTextStyles.bodySm.copyWith(
              color: OpticsColors.textSecondary,
            )),
      ],
    ),
  );
}

// ─── Step 1 — TABLES (primary + related, all on one page) ───────────────────

class _Step1Tables extends StatefulWidget {
  final CustomReportQueryV2 query;
  final List<Map<String, dynamic>> catalog;
  final Map<String, dynamic> relMap;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  const _Step1Tables({
    required this.query,
    required this.catalog,
    required this.relMap,
    required this.onMutate,
  });
  @override
  State<_Step1Tables> createState() => _Step1TablesState();
}

class _Step1TablesState extends State<_Step1Tables> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final selected = widget.query.primaryTable;
    final filt = _filter.toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader(
          'STEP 1 · TABLES',
          'Select your data source',
          'Choose a primary table, then optionally add related tables. Every row in your report will be a row from the primary table joined out.',
        ),

        // Search
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Search tables…',
          ),
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: OpticsSpacing.xl),

        // Query tables panel — visible the moment a primary is chosen.
        if (selected != null) ...[
          _queryTablesPanel(),
          const SizedBox(height: OpticsSpacing.xl),
        ],

        // Related tables suggestions — appears after primary picked.
        if (selected != null) ...[
          _relatedSection(),
          const SizedBox(height: OpticsSpacing.xl),
        ],

        // Primary picker
        Text(
          selected == null ? 'PICK PRIMARY TABLE' : 'CHANGE PRIMARY TABLE',
          style: OpticsTextStyles.sectionLabel.copyWith(
            color: OpticsColors.accentCyan,
          ),
        ),
        const SizedBox(height: OpticsSpacing.sm),
        _tableGrid(filt),
      ],
    );
  }

  Widget _tableGrid(String filt) {
    final entries = widget.catalog.where((t) {
      if (filt.isEmpty) return true;
      final n = (t['display_name'] as String).toLowerCase();
      final tn = (t['table_name'] as String).toLowerCase();
      return n.contains(filt) || tn.contains(filt);
    }).toList();

    return Wrap(
      spacing: OpticsSpacing.md,
      runSpacing: OpticsSpacing.md,
      children: [
        for (final t in entries)
          _tableCard(
            display: t['display_name'] as String,
            tableName: t['table_name'] as String,
            cols: (t['columns'] as List).length,
            selected: widget.query.primaryTable == t['table_name'],
            onTap: () {
              widget.onMutate((q) {
                final newPrimary = t['table_name'] as String;
                if (q.primaryTable != null && q.primaryTable != newPrimary) {
                  q.joins.clear();
                  q.columns.clear();
                  q.filters.clear();
                  q.groupBy.clear();
                  q.aggregates.clear();
                  q.orderBy.clear();
                }
                q.primaryTable = newPrimary;
              });
            },
          ),
      ],
    );
  }

  Widget _tableCard({
    required String display,
    required String tableName,
    required int cols,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(OpticsRadii.md),
      onTap: onTap,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(OpticsSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? OpticsColors.accentCyan.withValues(alpha: 0.08)
              : OpticsColors.surface,
          borderRadius: BorderRadius.circular(OpticsRadii.md),
          border: Border.all(
            color: selected
                ? OpticsColors.accentCyan
                : OpticsColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.table_chart_outlined,
                  size: 16,
                  color: selected
                      ? OpticsColors.accentCyan
                      : OpticsColors.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    display,
                    style: OpticsTextStyles.body.copyWith(
                      color: selected
                          ? OpticsColors.accentCyan
                          : OpticsColors.textPrimary,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(_bare(tableName),
                style: OpticsTextStyles.bodySm
                    .copyWith(color: OpticsColors.textMuted, fontSize: 11)),
            const SizedBox(height: 6),
            Text('$cols columns',
                style: OpticsTextStyles.bodySm.copyWith(
                  color: OpticsColors.textSecondary,
                )),
          ],
        ),
      ),
    );
  }

  // ─── Query tables panel (primary + joins) ────────────────────────────────

  Widget _queryTablesPanel() {
    final q = widget.query;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('QUERY TABLES', style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: OpticsSpacing.sm),
        Container(
          padding: const EdgeInsets.all(OpticsSpacing.md),
          decoration: BoxDecoration(
            color: OpticsColors.surface,
            border: Border.all(color: OpticsColors.border),
            borderRadius: BorderRadius.circular(OpticsRadii.md),
          ),
          child: Column(
            children: [
              _primaryRow(),
              for (final j in q.joins) _joinRow(j),
            ],
          ),
        ),
      ],
    );
  }

  Widget _primaryRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.table_chart,
              size: 16, color: OpticsColors.accentCyan),
          const SizedBox(width: OpticsSpacing.sm),
          Text(_displayName(widget.query.primaryTable!),
              style: OpticsTextStyles.body
                  .copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: OpticsSpacing.sm),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: OpticsColors.accentCyan.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(OpticsRadii.xs),
            ),
            child: const Text('PRIMARY',
                style: TextStyle(
                  color: OpticsColors.accentCyan,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                )),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _joinRow(JoinSpec j) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 24),
          Tooltip(
            message: j.type == JoinType.left
                ? 'LEFT JOIN — keep rows from the primary table even when there is no match. Click to switch to INNER.'
                : 'INNER JOIN — only return rows where the primary and joined tables have a match. Click to switch to LEFT.',
            child: InkWell(
            onTap: () => widget.onMutate((q) {
              final idx = q.joins.indexWhere((x) => x.table == j.table);
              if (idx < 0) return;
              final cur = q.joins[idx];
              q.joins[idx] = JoinSpec(
                table: cur.table,
                type: cur.type == JoinType.left
                    ? JoinType.inner
                    : JoinType.left,
                external: cur.external,
                on: cur.on,
              );
            }),
            borderRadius: BorderRadius.circular(OpticsRadii.xs),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: OpticsColors.accentViolet.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(OpticsRadii.xs),
                border: Border.all(
                    color: OpticsColors.accentViolet
                        .withValues(alpha: 0.5)),
              ),
              child: Text(
                j.type == JoinType.left ? 'LEFT' : 'INNER',
                style: const TextStyle(
                  color: OpticsColors.accentViolet,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Text(_displayName(j.table), style: OpticsTextStyles.body),
          if (j.external)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: OpticsColors.accentOrange.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(OpticsRadii.xs),
              ),
              child: const Text('REF',
                  style: TextStyle(
                    color: OpticsColors.accentOrange,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  )),
            ),
          const SizedBox(width: OpticsSpacing.sm),
          if (j.on.isNotEmpty)
            Flexible(
              child: Text(
                'ON ${_bare(j.on.first.fromTable)}.${j.on.first.fromColumn} = ${_bare(j.on.first.toTable)}.${j.on.first.toColumn}',
                style: OpticsTextStyles.bodySm.copyWith(
                    color: OpticsColors.textMuted, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Spacer(),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 14),
            onPressed: () => widget.onMutate((q) {
              q.joins.removeWhere((x) => x.table == j.table);
            }),
          ),
        ],
      ),
    );
  }

  // ─── Related table suggestions ──────────────────────────────────────────

  Widget _relatedSection() {
    final suggestions = _computeSuggestions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ADD RELATED TABLES',
          style: OpticsTextStyles.sectionLabel.copyWith(
            color: OpticsColors.accentGreen,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          suggestions.isEmpty
              ? 'No additional related tables found for this primary.'
              : 'Click a chip to join the related table to your query.',
          style: OpticsTextStyles.bodySm
              .copyWith(color: OpticsColors.textMuted),
        ),
        const SizedBox(height: OpticsSpacing.sm),
        if (suggestions.isNotEmpty)
          Wrap(
            spacing: OpticsSpacing.sm,
            runSpacing: OpticsSpacing.sm,
            children: [
              for (final s in suggestions) _suggestionChip(s),
            ],
          ),
      ],
    );
  }

  /// Walks rds_relationships, normalizing names so the chip cloud actually
  /// surfaces FKs. Relationships are stored with bare names (e.g. `user`)
  /// whereas the catalog uses `rds_user`; we compare on the bare form.
  List<_JoinSuggestion> _computeSuggestions() {
    final primary = widget.query.primaryTable;
    if (primary == null) return const [];
    final inQuery = <String>{
      _bare(primary),
      for (final j in widget.query.joins) _bare(j.table),
    };
    final catalogKeys = <String>{
      for (final t in widget.catalog) _bare(t['table_name'] as String),
    };
    final rels = ((widget.relMap['relationships'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    final out = <_JoinSuggestion>[];
    final seenTargets = <String>{};

    for (final r in rels) {
      final from = _bare((r['from_table'] as String?) ?? '');
      final to = _bare((r['to_table'] as String?) ?? '');
      final fc = (r['from_column'] as String?) ?? '';
      final tc = (r['to_column'] as String?) ?? '';
      final isExternal = (r['is_external'] as bool?) ?? false;
      if (from.isEmpty || to.isEmpty) continue;

      // Forward edge: child → parent.
      if (inQuery.contains(from) && !inQuery.contains(to)) {
        final targetExternal = isExternal;
        if (!targetExternal && !catalogKeys.contains(to)) continue;
        if (seenTargets.add(to)) {
          out.add(_JoinSuggestion(
            targetKey: to,
            fromTableKey: from,
            fromColumn: fc,
            toColumn: tc,
            external: targetExternal,
            reverse: false,
          ));
        }
      }
      // Reverse edge: parent → child (e.g. user → user_purchase_order).
      else if (inQuery.contains(to) && !inQuery.contains(from)) {
        if (!catalogKeys.contains(from)) continue;
        if (seenTargets.add(from)) {
          out.add(_JoinSuggestion(
            targetKey: from,
            fromTableKey: to,
            fromColumn: tc,
            toColumn: fc,
            external: false,
            reverse: true,
          ));
        }
      }
    }
    // Sort by display name.
    out.sort((a, b) =>
        _displayName(a.targetKey).compareTo(_displayName(b.targetKey)));
    return out;
  }

  Widget _suggestionChip(_JoinSuggestion s) {
    final targetMirror = s.external ? s.targetKey : _mirror(s.targetKey);
    final fromMirror =
        s.external ? s.fromTableKey : _mirror(s.fromTableKey);
    return Tooltip(
      message:
          '${_bare(fromMirror)}.${s.fromColumn} → ${_bare(targetMirror)}.${s.toColumn}'
          '${s.external ? "  ·  external reference" : s.reverse ? "  ·  reverse" : ""}',
      child: InkWell(
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        onTap: () {
          widget.onMutate((q) {
            q.joins.add(JoinSpec(
              table: targetMirror,
              type: JoinType.left,
              external: s.external,
              on: [
                JoinOnPair(
                  fromTable: fromMirror,
                  fromColumn: s.fromColumn,
                  toTable: targetMirror,
                  toColumn: s.toColumn,
                ),
              ],
            ));
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: OpticsSpacing.md, vertical: OpticsSpacing.sm),
          decoration: BoxDecoration(
            color: OpticsColors.accentGreen.withValues(alpha: 0.08),
            border: Border.all(
                color: OpticsColors.accentGreen.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_circle_outline,
                  size: 14, color: OpticsColors.accentGreen),
              const SizedBox(width: 6),
              Text(_displayName(s.targetKey),
                  style: OpticsTextStyles.body.copyWith(
                    fontWeight: FontWeight.w500,
                  )),
              if (s.external)
                Container(
                  margin: const EdgeInsets.only(left: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color:
                        OpticsColors.accentOrange.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(OpticsRadii.xs),
                  ),
                  child: const Text('REF',
                      style: TextStyle(
                        color: OpticsColors.accentOrange,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      )),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JoinSuggestion {
  final String targetKey;       // bare name
  final String fromTableKey;    // bare name
  final String fromColumn;
  final String toColumn;
  final bool external;
  final bool reverse;
  const _JoinSuggestion({
    required this.targetKey,
    required this.fromTableKey,
    required this.fromColumn,
    required this.toColumn,
    required this.external,
    required this.reverse,
  });
}

// ─── Step 2 — COLUMNS (vertical list, ERP-style) ────────────────────────────

class _Step2Columns extends StatefulWidget {
  final CustomReportQueryV2 query;
  final List<Map<String, dynamic>> catalog;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  const _Step2Columns({
    required this.query,
    required this.catalog,
    required this.onMutate,
  });
  @override
  State<_Step2Columns> createState() => _Step2ColumnsState();
}

class _Step2ColumnsState extends State<_Step2Columns> {
  String _filter = '';

  List<String> get _queryTables => <String>[
        if (widget.query.primaryTable != null) widget.query.primaryTable!,
        for (final j in widget.query.joins) j.table,
      ];

  bool get _isMultiTable => _queryTables.length > 1;

  Map<String, dynamic>? _findCatalog(String tableName) {
    for (final t in widget.catalog) {
      if (t['table_name'] == tableName) return t;
    }
    return null;
  }

  /// Per-table column list. External tables aren't in the catalog, so we
  /// shim a minimal column set (id/code/value) to remain usable.
  List<_TblCol> _columnsFor(String tableName, {bool external = false}) {
    final cat = _findCatalog(tableName);
    if (cat != null) {
      return ((cat['columns'] as List).cast<Map>())
          .where((c) => !((c['is_generated'] as bool? ?? false)))
          .map((c) => _TblCol(
                tableName: tableName,
                name: c['name'] as String,
                dataType: c['data_type'] as String,
              ))
          .toList();
    }
    if (external) {
      return const [
        _TblCol(tableName: '', name: 'id', dataType: 'uuid'),
        _TblCol(tableName: '', name: 'code', dataType: 'text'),
        _TblCol(tableName: '', name: 'value', dataType: 'text'),
      ].map((c) => _TblCol(
              tableName: tableName, name: c.name, dataType: c.dataType))
          .toList();
    }
    return const [];
  }

  bool _isSelected(String table, String col) {
    return widget.query.columns
        .any((c) => c.table == table && c.column == col);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.primaryTable == null) {
      return _emptyState('Pick a primary table in Step 1 first.');
    }
    // Build the flat list grouped by table, in query order.
    final groups = <String, List<_TblCol>>{};
    for (final t in _queryTables) {
      final isExternal = widget.query.joins
          .any((j) => j.table == t && j.external);
      groups[t] = _columnsFor(t, external: isExternal);
    }

    final filt = _filter.toLowerCase();
    bool matches(_TblCol c) {
      if (filt.isEmpty) return true;
      return c.name.toLowerCase().contains(filt) ||
          c.tableName.toLowerCase().contains(filt) ||
          c.dataType.toLowerCase().contains(filt);
    }

    final totalSelected = widget.query.columns.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header line: title + counts + clear
        Row(
          children: [
            Text('STEP 2 · COLUMNS',
                style: OpticsTextStyles.sectionLabel),
            const SizedBox(width: OpticsSpacing.md),
            Text('$totalSelected selected',
                style: OpticsTextStyles.bodySm.copyWith(
                  color: totalSelected == 0
                      ? OpticsColors.textMuted
                      : OpticsColors.accentCyan,
                  fontWeight: FontWeight.w600,
                )),
            if (_isMultiTable) ...[
              const SizedBox(width: OpticsSpacing.sm),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: OpticsColors.accentGreen.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(OpticsRadii.xs),
                ),
                child: Text('${_queryTables.length} tables',
                    style: const TextStyle(
                      color: OpticsColors.accentGreen,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    )),
              ),
            ],
            const Spacer(),
            if (totalSelected > 0)
              TextButton(
                onPressed: () => widget.onMutate((q) => q.columns.clear()),
                child: Text('CLEAR ALL',
                    style: OpticsTextStyles.bodySm
                        .copyWith(color: OpticsColors.danger)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Tap to toggle. ${_isMultiTable ? "Columns are grouped by table." : ""} Drag the selected list below to reorder.',
          style: OpticsTextStyles.bodySm
              .copyWith(color: OpticsColors.textSecondary),
        ),
        const SizedBox(height: OpticsSpacing.md),

        // Selected (in order) — drag to reorder; this controls the column
        // order in the preview/table and in saved SELECT output.
        if (widget.query.columns.isNotEmpty) ...[
          Text('SELECTED ORDER',
              style: OpticsTextStyles.sectionLabel.copyWith(
                  color: OpticsColors.accentCyan)),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: OpticsColors.surface,
              border: Border.all(color: OpticsColors.border),
              borderRadius: BorderRadius.circular(OpticsRadii.md),
            ),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: widget.query.columns.length,
              onReorder: (oldIndex, newIndex) {
                widget.onMutate((q) {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final moved = q.columns.removeAt(oldIndex);
                  q.columns.insert(newIndex, moved);
                });
              },
              itemBuilder: (ctx, i) {
                final c = widget.query.columns[i];
                return _selectedOrderTile(c, i, key: ValueKey('sel-${c.table}.${c.column}'));
              },
            ),
          ),
          const SizedBox(height: OpticsSpacing.md),
        ],

        // Search
        TextField(
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Search columns across all tables…',
          ),
          onChanged: (v) => setState(() => _filter = v),
        ),
        const SizedBox(height: OpticsSpacing.md),

        // Grouped vertical list.
        Container(
          decoration: BoxDecoration(
            color: OpticsColors.surface,
            border: Border.all(color: OpticsColors.border),
            borderRadius: BorderRadius.circular(OpticsRadii.md),
          ),
          padding: const EdgeInsets.all(OpticsSpacing.sm),
          child: Column(
            children: [
              for (final t in _queryTables)
                _tableSection(
                  t,
                  (groups[t] ?? const []).where(matches).toList(),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _selectedOrderTile(ColumnRef c, int i, {required Key key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: const Tooltip(
              message: 'Drag to reorder column',
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.drag_indicator,
                    size: 18, color: OpticsColors.textMuted),
              ),
            ),
          ),
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: OpticsColors.accentCyan.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(OpticsRadii.xs),
            ),
            child: Text('${i + 1}',
                style: const TextStyle(
                    color: OpticsColors.accentCyan,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.alias,
                    style: OpticsTextStyles.body
                        .copyWith(fontWeight: FontWeight.w600)),
                Text('${_bare(c.table)}.${c.column}',
                    style: OpticsTextStyles.bodySm.copyWith(
                        color: OpticsColors.textMuted, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 14),
            onPressed: () => widget.onMutate((q) {
              q.columns.removeWhere(
                  (x) => x.table == c.table && x.column == c.column);
            }),
          ),
        ],
      ),
    );
  }

  Widget _tableSection(String tableName, List<_TblCol> cols) {
    if (cols.isEmpty) return const SizedBox.shrink();
    final isPrimary = tableName == widget.query.primaryTable;
    return Padding(
      padding: const EdgeInsets.only(bottom: OpticsSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isMultiTable)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isPrimary
                    ? OpticsColors.accentCyan.withValues(alpha: 0.08)
                    : OpticsColors.accentGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(OpticsRadii.xs),
              ),
              child: Row(
                children: [
                  Icon(Icons.table_chart,
                      size: 14,
                      color: isPrimary
                          ? OpticsColors.accentCyan
                          : OpticsColors.accentGreen),
                  const SizedBox(width: 8),
                  Text(_displayName(tableName),
                      style: OpticsTextStyles.sectionLabel.copyWith(
                        color: isPrimary
                            ? OpticsColors.accentCyan
                            : OpticsColors.accentGreen,
                        fontSize: 11,
                      )),
                  if (isPrimary) ...[
                    const SizedBox(width: 6),
                    const Text('PRIMARY',
                        style: TextStyle(
                          color: OpticsColors.accentCyan,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        )),
                  ],
                ],
              ),
            ),
          ...cols.map(_columnTile),
        ],
      ),
    );
  }

  Widget _columnTile(_TblCol c) {
    final selected = _isSelected(c.tableName, c.name);
    final cfg = selected
        ? widget.query.columns.firstWhere(
            (x) => x.table == c.tableName && x.column == c.name)
        : null;
    return InkWell(
      borderRadius: BorderRadius.circular(OpticsRadii.xs),
      onTap: () {
        widget.onMutate((q) {
          if (selected) {
            q.columns.removeWhere(
                (x) => x.table == c.tableName && x.column == c.name);
          } else {
            q.columns.add(ColumnRef(
                table: c.tableName, column: c.name, alias: c.name));
          }
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? OpticsColors.accentCyan.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(OpticsRadii.xs),
          border: selected
              ? Border.all(
                  color:
                      OpticsColors.accentCyan.withValues(alpha: 0.4))
              : null,
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected
                  ? OpticsColors.accentCyan
                  : OpticsColors.textMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    style: OpticsTextStyles.body.copyWith(
                      color: selected
                          ? OpticsColors.accentCyan
                          : OpticsColors.textPrimary,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(children: [
                    Text(_typeLabel(c.dataType),
                        style: OpticsTextStyles.bodySm.copyWith(
                            color: OpticsColors.textMuted, fontSize: 11)),
                    if (cfg != null && cfg.alias != cfg.column) ...[
                      const SizedBox(width: 8),
                      Text('as "${cfg.alias}"',
                          style: OpticsTextStyles.bodySm.copyWith(
                              color: OpticsColors.accentCyan,
                              fontSize: 11,
                              fontStyle: FontStyle.italic)),
                    ],
                  ]),
                ],
              ),
            ),
            if (selected)
              IconButton(
                tooltip: 'Alias',
                icon: const Icon(Icons.tune, size: 16),
                onPressed: () => _editAlias(c),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editAlias(_TblCol c) async {
    final cur = widget.query.columns
        .firstWhere((x) => x.table == c.tableName && x.column == c.name);
    final ctl = TextEditingController(text: cur.alias);
    final v = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: const Text('Column alias'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Display alias'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
              child: const Text('Apply')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    widget.onMutate((q) {
      final idx = q.columns
          .indexWhere((x) => x.table == c.tableName && x.column == c.name);
      if (idx >= 0) {
        q.columns[idx] =
            ColumnRef(table: c.tableName, column: c.name, alias: v);
      }
    });
  }
}

class _TblCol {
  final String tableName;
  final String name;
  final String dataType;
  const _TblCol({
    required this.tableName,
    required this.name,
    required this.dataType,
  });
}

String _typeLabel(String t) {
  final lo = t.toLowerCase();
  if (lo.contains('int')) return 'number';
  if (lo.contains('numeric') || lo.contains('decimal')) return 'number';
  if (lo.contains('bool')) return 'boolean';
  if (lo.contains('uuid')) return 'id';
  if (lo.contains('json')) return 'json';
  if (lo.contains('time') || lo.contains('date')) return 'date';
  return 'text';
}

// ─── Step 3 — FILTERS ───────────────────────────────────────────────────────

class _Step3Filters extends StatelessWidget {
  final CustomReportQueryV2 query;
  final List<Map<String, dynamic>> catalog;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  const _Step3Filters({
    required this.query,
    required this.catalog,
    required this.onMutate,
  });

  List<(String, String, String)> _allColumns() {
    final inQuery = <String>{
      if (query.primaryTable != null) query.primaryTable!,
      for (final j in query.joins) j.table,
    };
    final out = <(String, String, String)>[];
    for (final t in catalog) {
      final tn = t['table_name'] as String;
      if (!inQuery.contains(tn)) continue;
      for (final c in (t['columns'] as List).cast<Map>()) {
        out.add((tn, c['name'] as String, c['data_type'] as String));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (query.primaryTable == null) {
      return _emptyState('Pick a primary table in Step 1 first.');
    }
    final allCols = _allColumns();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('STEP 3 · FILTERS', 'Filter the rows',
            'Each filter is column · operator · value. Multiple filters AND together.'),
        const _StepGuidanceCard(
          icon: Icons.lightbulb_outline,
          title: 'Operator tips',
          body:
              '   • =, !=, >, <, >=, <=, LIKE, ILIKE — need a single value.\n'
              '   • IN, NOT IN — comma-separate values (e.g. open, in_progress).\n'
              '   • BETWEEN — provide both a low and a high value.\n'
              '   • IS NULL, IS NOT NULL — leave the value field blank.\n\n'
              'A filter with a missing value will block the preview until you fill it in.',
        ),
        const SizedBox(height: OpticsSpacing.md),
        for (int i = 0; i < query.filters.length; i++)
          _filterRow(context, query.filters[i], i, allCols),
        const SizedBox(height: OpticsSpacing.md),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add filter'),
          onPressed: allCols.isEmpty
              ? null
              : () {
                  final first = allCols.first;
                  onMutate((q) {
                    q.filters.add(FilterSpec(
                      table: first.$1,
                      column: first.$2,
                      op: '=',
                      value: '',
                    ));
                  });
                },
        ),
      ],
    );
  }

  Widget _filterRow(
    BuildContext context,
    FilterSpec f,
    int index,
    List<(String, String, String)> allCols,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: _DynamicWidthColumnPicker(
              current: '${f.table}.${f.column}',
              allCols: allCols,
              onSelected: (v) {
                final parts = v.split('.');
                if (parts.length < 2) return;
                final tbl = parts.sublist(0, parts.length - 1).join('.');
                final col = parts.last;
                onMutate((q) {
                  q.filters[index] = FilterSpec(
                    table: tbl,
                    column: col,
                    op: f.op,
                    value: f.value,
                  );
                });
              },
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              initialValue: f.op,
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              items: [
                for (final op in kFilterOps)
                  DropdownMenuItem(value: op, child: Text(op)),
              ],
              onChanged: (v) {
                if (v == null) return;
                onMutate((q) {
                  q.filters[index] = FilterSpec(
                    table: f.table,
                    column: f.column,
                    op: v,
                    value: (v == 'IS NULL' || v == 'IS NOT NULL')
                        ? null
                        : f.value,
                  );
                });
              },
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Expanded(
            flex: 4,
            child: (f.op == 'IS NULL' || f.op == 'IS NOT NULL')
                ? const SizedBox.shrink()
                : TextFormField(
                    initialValue: f.value?.toString() ?? '',
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: (f.op == 'IN' || f.op == 'NOT IN')
                          ? 'val1, val2, val3'
                          : (f.op == 'BETWEEN' ? 'low, high' : 'value'),
                    ),
                    onChanged: (v) {
                      onMutate((q) {
                        dynamic value = v;
                        if (f.op == 'IN' ||
                            f.op == 'NOT IN' ||
                            f.op == 'BETWEEN') {
                          value =
                              v.split(',').map((s) => s.trim()).toList();
                        }
                        q.filters[index] = FilterSpec(
                          table: f.table,
                          column: f.column,
                          op: f.op,
                          value: value,
                        );
                      });
                    },
                  ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 14),
            onPressed: () {
              onMutate((q) => q.filters.removeAt(index));
            },
          ),
        ],
      ),
    );
  }
}

// ─── Step 4 — GROUP / Aggregate ─────────────────────────────────────────────

class _Step4Group extends StatelessWidget {
  final CustomReportQueryV2 query;
  final List<Map<String, dynamic>> catalog;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  const _Step4Group({
    required this.query,
    required this.catalog,
    required this.onMutate,
  });

  List<(String, String)> _allColumns() {
    final inQuery = <String>{
      if (query.primaryTable != null) query.primaryTable!,
      for (final j in query.joins) j.table,
    };
    final out = <(String, String)>[];
    for (final t in catalog) {
      final tn = t['table_name'] as String;
      if (!inQuery.contains(tn)) continue;
      for (final c in (t['columns'] as List).cast<Map>()) {
        out.add((tn, c['name'] as String));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (query.primaryTable == null) {
      return _emptyState('Pick a primary table in Step 1 first.');
    }
    final allCols = _allColumns();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('STEP 4 · GROUP & AGGREGATE',
            'Roll up rows into summaries',
            'Pick the columns to group by, then add aggregates like SUM, AVG, COUNT on the rest.'),
        const _StepGuidanceCard(
          icon: Icons.info_outline,
          title: 'Grouping rule',
          body:
              'When you add a GROUP BY or an aggregate, every column in Step 2 must either:\n'
              '   • be listed here as a Group By, or\n'
              '   • be wrapped in an aggregate (SUM, AVG, COUNT, MIN, MAX) below.\n\n'
              'If you skip a column, the database returns no rows and the preview stays empty.\n\n'
              'Not sure you need grouping? Leave both empty and the report just lists every row.',
        ),
        const SizedBox(height: OpticsSpacing.md),
        Text('GROUP BY', style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: OpticsSpacing.sm),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final g in query.groupBy)
              InputChip(
                label: Text('${_bare(g.table)}.${g.column}'),
                onDeleted: () {
                  onMutate((q) => q.groupBy.removeWhere(
                      (x) => x.table == g.table && x.column == g.column));
                },
              ),
            ActionChip(
              avatar: const Icon(Icons.add, size: 14),
              label: const Text('Add'),
              onPressed: allCols.isEmpty
                  ? null
                  : () async {
                      final picked = await _pickColumn(context, allCols);
                      if (picked == null) return;
                      onMutate((q) {
                        q.groupBy.add(GroupBySpec(
                            table: picked.$1, column: picked.$2));
                      });
                    },
            ),
          ],
        ),
        const SizedBox(height: OpticsSpacing.xl),
        Text('AGGREGATES', style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: OpticsSpacing.sm),
        for (int i = 0; i < query.aggregates.length; i++)
          _aggregateRow(context, query.aggregates[i], i, allCols),
        const SizedBox(height: OpticsSpacing.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add aggregate'),
          onPressed: allCols.isEmpty
              ? null
              : () {
                  final first = allCols.first;
                  onMutate((q) {
                    q.aggregates.add(AggregateSpec(
                      table: first.$1,
                      column: first.$2,
                      fn: 'count',
                      alias: '${first.$2}_count',
                    ));
                  });
                },
        ),
      ],
    );
  }

  Future<(String, String)?> _pickColumn(
      BuildContext ctx, List<(String, String)> all) async {
    return showDialog<(String, String)>(
      context: ctx,
      builder: (dctx) {
        return SimpleDialog(
          backgroundColor: OpticsColors.surface,
          title: const Text('Pick column'),
          children: [
            SizedBox(
              width: 400,
              height: 400,
              child: ListView(
                children: [
                  for (final c in all)
                    ListTile(
                      dense: true,
                      title: Text('${_bare(c.$1)}.${c.$2}'),
                      onTap: () => Navigator.pop(dctx, c),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _aggregateRow(
    BuildContext context,
    AggregateSpec a,
    int index,
    List<(String, String)> allCols,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Tooltip(
              message:
                  'SUM → totals numeric values\n'
                  'AVG → mean of numeric values\n'
                  'COUNT → number of rows\n'
                  'COUNT DISTINCT → unique non-null values\n'
                  'MIN / MAX → smallest / largest value',
              waitDuration: const Duration(milliseconds: 350),
              child: DropdownButtonFormField<String>(
                initialValue: a.fn,
                isDense: true,
                decoration: const InputDecoration(isDense: true),
                items: [
                  for (final fn in kAggregateFns)
                    DropdownMenuItem(
                        value: fn, child: Text(fn.toUpperCase())),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  onMutate((q) {
                    q.aggregates[index] = AggregateSpec(
                      table: a.table,
                      column: a.column,
                      fn: v,
                      alias: a.alias,
                    );
                  });
                },
              ),
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Expanded(
            flex: 4,
            child: DropdownButtonFormField<String>(
              initialValue: '${a.table}.${a.column}',
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              selectedItemBuilder: (ctx) => [
                for (final c in allCols)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_bare(c.$1)}.${c.$2}',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: OpticsTextStyles.body,
                    ),
                  ),
              ],
              items: [
                for (final c in allCols)
                  DropdownMenuItem(
                    value: '${c.$1}.${c.$2}',
                    child: Text('${_bare(c.$1)}.${c.$2}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                final parts = v.split('.');
                if (parts.length < 2) return;
                final tbl = parts.sublist(0, parts.length - 1).join('.');
                final col = parts.last;
                onMutate((q) {
                  q.aggregates[index] = AggregateSpec(
                    table: tbl,
                    column: col,
                    fn: a.fn,
                    alias: a.alias,
                  );
                });
              },
            ),
          ),
          const SizedBox(width: OpticsSpacing.sm),
          Expanded(
            flex: 3,
            child: TextFormField(
              initialValue: a.alias,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'alias',
              ),
              onChanged: (v) {
                onMutate((q) {
                  q.aggregates[index] = AggregateSpec(
                    table: a.table,
                    column: a.column,
                    fn: a.fn,
                    alias: v.trim(),
                  );
                });
              },
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 14),
            onPressed: () =>
                onMutate((q) => q.aggregates.removeAt(index)),
          ),
        ],
      ),
    );
  }
}

// ─── Step 5 — SORT & LIMIT ──────────────────────────────────────────────────

class _Step5Sort extends StatelessWidget {
  final CustomReportQueryV2 query;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  const _Step5Sort({required this.query, required this.onMutate});

  List<String> _allAliases() {
    return <String>[
      for (final c in query.columns) c.alias,
      for (final a in query.aggregates) a.alias,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (query.primaryTable == null) {
      return _emptyState('Pick a primary table in Step 1 first.');
    }
    final aliases = _allAliases();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('STEP 5 · SORT & LIMIT', 'Order and cap the result',
            'Sort by any selected column or aggregate alias. Optionally limit the number of rows.'),
        const _StepGuidanceCard(
          icon: Icons.bolt_outlined,
          title: 'Sort runs automatically',
          body:
              'Each rule you add below becomes part of the query\'s ORDER BY. Rows arrive '
              'already sorted in the Live Preview, in the saved report, and in exports — '
              'there\'s no separate "apply" button.\n\n'
              'Sort runs after grouping, so you can sort by an aggregate alias '
              '(e.g. total_qty DESC) too.',
        ),
        const SizedBox(height: OpticsSpacing.md),
        for (int i = 0; i < query.orderBy.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<String>(
                    initialValue: query.orderBy[i].alias,
                    isDense: true,
                    decoration: const InputDecoration(isDense: true),
                    items: [
                      for (final a in aliases)
                        DropdownMenuItem(value: a, child: Text(a)),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      onMutate((q) {
                        q.orderBy[i] =
                            OrderBySpec(alias: v, dir: q.orderBy[i].dir);
                      });
                    },
                  ),
                ),
                const SizedBox(width: OpticsSpacing.sm),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: query.orderBy[i].dir,
                    isDense: true,
                    decoration: const InputDecoration(isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'ASC', child: Text('ASC')),
                      DropdownMenuItem(value: 'DESC', child: Text('DESC')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      onMutate((q) {
                        q.orderBy[i] = OrderBySpec(
                            alias: q.orderBy[i].alias, dir: v);
                      });
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 14),
                  onPressed: () =>
                      onMutate((q) => q.orderBy.removeAt(i)),
                ),
              ],
            ),
          ),
        const SizedBox(height: OpticsSpacing.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add sort'),
          onPressed: aliases.isEmpty
              ? null
              : () => onMutate((q) {
                    q.orderBy.add(
                        OrderBySpec(alias: aliases.first, dir: 'ASC'));
                  }),
        ),
        const SizedBox(height: OpticsSpacing.xl),
        Text('LIMIT', style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: OpticsSpacing.sm),
        Row(
          children: [
            SizedBox(
              width: 160,
              child: TextFormField(
                initialValue: query.limit?.toString() ?? '',
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'No limit',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) {
                  onMutate((q) {
                    q.limit = v.isEmpty ? null : int.tryParse(v);
                  });
                },
              ),
            ),
            const SizedBox(width: OpticsSpacing.sm),
            Text(query.limit == null ? 'No limit' : 'rows',
                style: OpticsTextStyles.bodySm
                    .copyWith(color: OpticsColors.textMuted)),
          ],
        ),
      ],
    );
  }
}

// ─── Step 6 — VISUALIZE & SAVE ──────────────────────────────────────────────

class _Step6Visualize extends StatefulWidget {
  final CustomReportQueryV2 query;
  final void Function(void Function(CustomReportQueryV2 q)) onMutate;
  final String title;
  final String? description;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onDescriptionChanged;
  const _Step6Visualize({
    required this.query,
    required this.onMutate,
    required this.title,
    required this.description,
    required this.onTitleChanged,
    required this.onDescriptionChanged,
  });

  @override
  State<_Step6Visualize> createState() => _Step6VisualizeState();
}

class _Step6VisualizeState extends State<_Step6Visualize> {
  late final TextEditingController _titleCtl;
  late final TextEditingController _descCtl;

  static const _chartTypes = <(String, String)>[
    ('table', 'Table'),
    ('kpi', 'KPI'),
    ('bar', 'Bar'),
    ('hbar', 'H-Bar'),
    ('line', 'Line'),
    ('area', 'Area'),
    ('pie', 'Pie'),
    ('donut', 'Donut'),
    ('combo', 'Combo'),
  ];

  @override
  void initState() {
    super.initState();
    _titleCtl = TextEditingController(text: widget.title);
    _descCtl = TextEditingController(text: widget.description ?? '');
  }

  @override
  void dispose() {
    _titleCtl.dispose();
    _descCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allAliases = <String>[
      for (final c in widget.query.columns) c.alias,
      for (final a in widget.query.aggregates) a.alias,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('STEP 6 · VISUALIZE & SAVE', 'Pick a chart and save',
            'Choose how the data renders, then save the report.'),
        const _StepGuidanceCard(
          icon: Icons.tips_and_updates_outlined,
          title: 'Chart axis tips',
          body:
              '   • Bar / Line / Pie / Donut — need an X (category) and a numeric Y. '
              'If Y isn\'t numeric we fall back to counting rows per X.\n'
              '   • KPI — shows a single Y value from the first row.\n'
              '   • Table — no axes needed; shows everything as a grid.\n\n'
              'If the preview looks wrong, check that Y points at a SUM/COUNT/AVG alias from Step 4.',
        ),
        const SizedBox(height: OpticsSpacing.md),
        Text('CHART TYPE', style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: OpticsSpacing.sm),
        Wrap(
          spacing: OpticsSpacing.sm,
          runSpacing: OpticsSpacing.sm,
          children: [
            for (final t in _chartTypes)
              ChoiceChip(
                label: Text(t.$2),
                selected: widget.query.viz.chartType == t.$1,
                onSelected: (_) {
                  widget.onMutate((q) {
                    // Auto-pick sensible defaults for x / y when switching
                    // to a non-table chart so the preview re-renders
                    // immediately. First dimension-ish alias → x, first
                    // numeric-ish alias → y.
                    String? x = q.viz.x;
                    String? y = q.viz.y;
                    if (t.$1 != 'table') {
                      final aliases = <String>[
                        for (final c in q.columns) c.alias,
                        for (final a in q.aggregates) a.alias,
                      ];
                      final numericAliases = <String>{
                        for (final a in q.aggregates) a.alias,
                      };
                      x ??= aliases.firstWhere(
                          (a) => !numericAliases.contains(a),
                          orElse: () => aliases.isEmpty ? '' : aliases.first);
                      if (x.isEmpty) x = null;
                      y ??= aliases.firstWhere(
                          (a) => numericAliases.contains(a),
                          orElse: () => aliases.isEmpty
                              ? ''
                              : aliases.last);
                      if (y == x || (y?.isEmpty ?? true)) {
                        y = aliases.where((a) => a != x).isEmpty
                            ? y
                            : aliases.firstWhere((a) => a != x);
                      }
                      if ((y?.isEmpty ?? true)) y = null;
                    }
                    q.viz = VizSpec(
                      chartType: t.$1,
                      x: x,
                      y: y,
                    );
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: OpticsSpacing.lg),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: allAliases.contains(widget.query.viz.x)
                    ? widget.query.viz.x
                    : null,
                isDense: true,
                decoration: const InputDecoration(
                    isDense: true, labelText: 'X / category'),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text('—')),
                  for (final a in allAliases)
                    DropdownMenuItem(value: a, child: Text(a)),
                ],
                onChanged: (v) => widget.onMutate((q) {
                  q.viz = VizSpec(
                      chartType: q.viz.chartType, x: v, y: q.viz.y);
                }),
              ),
            ),
            const SizedBox(width: OpticsSpacing.sm),
            Tooltip(
              message: 'Swap X and Y selections',
              child: OutlinedButton.icon(
                onPressed: () => widget.onMutate((q) {
                  q.viz = VizSpec(
                      chartType: q.viz.chartType,
                      x: q.viz.y,
                      y: q.viz.x);
                }),
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: Text(
                  'SWITCH AXES',
                  style: OpticsTextStyles.sectionLabel
                      .copyWith(fontSize: 11),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: OpticsColors.accentCyan,
                  side: BorderSide(color: OpticsColors.border),
                  padding: const EdgeInsets.symmetric(
                      horizontal: OpticsSpacing.md, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                  ),
                ),
              ),
            ),
            const SizedBox(width: OpticsSpacing.sm),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: allAliases.contains(widget.query.viz.y)
                    ? widget.query.viz.y
                    : null,
                isDense: true,
                decoration: const InputDecoration(
                    isDense: true, labelText: 'Y / value'),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text('—')),
                  for (final a in allAliases)
                    DropdownMenuItem(value: a, child: Text(a)),
                ],
                onChanged: (v) => widget.onMutate((q) {
                  q.viz = VizSpec(
                      chartType: q.viz.chartType, x: q.viz.x, y: v);
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: OpticsSpacing.xl),
        Text('REPORT DETAILS', style: OpticsTextStyles.sectionLabel),
        const SizedBox(height: OpticsSpacing.sm),
        TextField(
          controller: _titleCtl,
          decoration: const InputDecoration(
              isDense: true, labelText: 'Title'),
          onChanged: widget.onTitleChanged,
        ),
        const SizedBox(height: OpticsSpacing.sm),
        TextField(
          controller: _descCtl,
          decoration: const InputDecoration(
              isDense: true, labelText: 'Description (optional)'),
          maxLines: 3,
          onChanged: widget.onDescriptionChanged,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Preview panel (right).
// ─────────────────────────────────────────────────────────────────────────────

class _PreviewPanel extends ConsumerWidget {
  final CustomReportQueryV2 query;
  const _PreviewPanel({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_previewRowsProvider);
    final report = ref.watch(_validationProvider);
    final bryzos = isBryzosUser(ref);
    final rawMode = query.useRawSql;
    return Container(
      color: OpticsColors.canvas,
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('LIVE PREVIEW', style: OpticsTextStyles.sectionLabel),
              const Spacer(),
              rows.maybeWhen(
                loading: () => const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5)),
                data: (r) => Text('${r.length} rows',
                    style: OpticsTextStyles.bodySm
                        .copyWith(color: OpticsColors.textMuted)),
                orElse: () => const SizedBox.shrink(),
              ),
            ],
          ),
          if (!rawMode && report.issues.isNotEmpty) ...[
            const SizedBox(height: OpticsSpacing.sm),
            _ValidationBanner(report: report, onJumpToStep: (s) {
              ref.read(_builderProvider.notifier).setStep(s);
            }),
          ],
          const SizedBox(height: OpticsSpacing.md),
          Expanded(
            flex: 6,
            child: rows.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) {
                if (e is _PreviewBlockedException) {
                  return _PreviewBlockedView(
                    report: e.report,
                    onJumpToStep: (s) =>
                        ref.read(_builderProvider.notifier).setStep(s),
                  );
                }
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(OpticsSpacing.md),
                    child: Text(
                      'Query failed:\n$e',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: OpticsColors.danger),
                    ),
                  ),
                );
              },
              data: (r) => _renderViz(r),
            ),
          ),
          const SizedBox(height: OpticsSpacing.md),
          const Divider(height: 1, color: OpticsColors.border),
          const SizedBox(height: OpticsSpacing.md),
          Row(
            children: [
              Text(rawMode ? 'RAW SQL' : 'SQL SUMMARY',
                  style: OpticsTextStyles.sectionLabel),
              const Spacer(),
              if (bryzos) _RawSqlToggle(query: query),
            ],
          ),
          const SizedBox(height: OpticsSpacing.sm),
          Expanded(
            flex: 3,
            child: rawMode
                ? _RawSqlEditor(
                    initialSql: query.rawSql ?? _summarySql(query),
                    onChanged: (v) =>
                        ref.read(_builderProvider.notifier).setRawSql(v),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      _summarySql(query),
                      style: const TextStyle(
                        color: OpticsColors.textSecondary,
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _renderViz(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: OpticsColors.surface,
          border: Border.all(color: OpticsColors.border),
          borderRadius: BorderRadius.circular(OpticsRadii.md),
        ),
        alignment: Alignment.center,
        child: const Text('No rows yet — finish the wizard.',
            style: OpticsTextStyles.bodySm),
      );
    }
    final viz = query.viz;
    switch (viz.chartType) {
      case 'kpi':
        return _renderKpi(rows);
      case 'bar':
      case 'hbar':
        return _renderBar(rows, horizontal: viz.chartType == 'hbar');
      case 'line':
      case 'area':
        return _renderLine(rows, area: viz.chartType == 'area');
      case 'pie':
      case 'donut':
        return _renderPie(rows, donut: viz.chartType == 'donut');
      case 'combo':
        return _renderCombo(rows);
      default:
        return _renderTable(rows);
    }
  }

  Widget _renderCombo(List<Map<String, dynamic>> rows) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null) return _renderTable(rows);
    final bars = _seriesFor(rows, x, y).take(20).toList();
    if (bars.isEmpty) return _renderTable(rows);
    final maxV = bars
        .map((e) => e.value)
        .fold<double>(0, (a, b) => b > a ? b : a);
    final maxY = maxV <= 0 ? 1.0 : maxV * 1.08;
    final linePts = <FlSpot>[
      for (int i = 0; i < bars.length; i++)
        FlSpot(i.toDouble(), bars[i].value),
    ];
    return Container(
      padding: const EdgeInsets.all(OpticsSpacing.md),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: Stack(
        children: [
          // Bars (cyan)
          BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY,
              minY: 0,
              barGroups: [
                for (int i = 0; i < bars.length; i++)
                  BarChartGroupData(x: i, barRods: [
                    BarChartRodData(
                      toY: bars[i].value,
                      color: OpticsColors.accentCyan,
                      width: 14,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ]),
              ],
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (v, _) => Text(
                            v.toStringAsFixed(0),
                            style: OpticsTextStyles.bodySm
                                .copyWith(fontSize: 10),
                          )),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= bars.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          bars[i].key.length > 10
                              ? '${bars[i].key.substring(0, 10)}…'
                              : bars[i].key,
                          style: OpticsTextStyles.bodySm
                              .copyWith(fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          // Line overlay (violet) tracing the bar tops
          LineChart(
            LineChartData(
              minX: -0.5,
              maxX: bars.length - 0.5,
              minY: 0,
              maxY: maxY,
              lineBarsData: [
                LineChartBarData(
                  spots: linePts,
                  isCurved: true,
                  barWidth: 2,
                  color: OpticsColors.accentViolet,
                  dotData: FlDotData(
                    show: true,
                    getDotPainter: (_, __, ___, ____) =>
                        FlDotCirclePainter(
                            radius: 3,
                            color: OpticsColors.accentViolet,
                            strokeWidth: 0),
                  ),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              // Reserve identical padding so line coords align with bar centers.
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (v, _) => const SizedBox.shrink(),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderTable(List<Map<String, dynamic>> rows) {
    // Drive header order from the wizard's `query.columns` (then aggregates)
    // so reordering on Step 2 immediately reflects in the live preview.
    // Fall back to the raw row keys when the query has no projection yet.
    final orderedHeaders = <String>[
      for (final c in query.columns) c.alias,
      for (final a in query.aggregates) a.alias,
    ];
    final seen = <String>{};
    final headers = <String>[];
    for (final h in orderedHeaders) {
      if (rows.first.containsKey(h) && seen.add(h)) headers.add(h);
    }
    // Append any extras the RPC returned that the wizard didn't anticipate.
    for (final h in rows.first.keys) {
      if (seen.add(h)) headers.add(h);
    }

    // Detect numeric columns so we can right-align and color them like
    // the dashboard widget table (widget_renderer._singleSeriesTable).
    final numericCols = <String>{};
    for (final h in headers) {
      var hasValue = false;
      var allNum = true;
      for (final r in rows) {
        final v = r[h];
        if (v == null) continue;
        hasValue = true;
        if (v is num) continue;
        if (double.tryParse(v.toString()) == null) {
          allNum = false;
          break;
        }
      }
      if (hasValue && allNum) numericCols.add(h);
    }
    final primaryNumeric =
        headers.firstWhere(numericCols.contains, orElse: () => '');
    double grandTotal = 0;
    if (primaryNumeric.isNotEmpty) {
      for (final r in rows) {
        final v = r[primaryNumeric];
        final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
        if (n != null) grandTotal += n;
      }
    }
    final showShare = primaryNumeric.isNotEmpty && grandTotal > 0;
    final palette = OpticsColors.chartPalette;

    Widget headerCell(String text, {bool rightAlign = false}) => Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: OpticsColors.textMuted,
          ),
          textAlign: rightAlign ? TextAlign.right : TextAlign.left,
          overflow: TextOverflow.ellipsis,
        );

    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(
              children: [
                SizedBox(width: 24, child: headerCell('#')),
                for (int i = 0; i < headers.length; i++)
                  Expanded(
                    flex: i == 0 ? 3 : 2,
                    child: headerCell(
                      headers[i],
                      rightAlign: numericCols.contains(headers[i]),
                    ),
                  ),
                if (showShare)
                  SizedBox(
                    width: 56,
                    child: headerCell('Share', rightAlign: true),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (int rank = 0; rank < rows.take(50).length; rank++)
                    _styledTableRow(
                      rank: rank,
                      row: rows[rank],
                      headers: headers,
                      numericCols: numericCols,
                      primaryNumeric: primaryNumeric,
                      grandTotal: grandTotal,
                      showShare: showShare,
                      palette: palette,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _styledTableRow({
    required int rank,
    required Map<String, dynamic> row,
    required List<String> headers,
    required Set<String> numericCols,
    required String primaryNumeric,
    required double grandTotal,
    required bool showShare,
    required List<Color> palette,
  }) {
    final rowColor = palette[rank % palette.length];
    final isOdd = rank % 2 == 1;
    double? primaryVal;
    if (showShare) {
      final v = row[primaryNumeric];
      primaryVal = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    }
    final share = (primaryVal != null && grandTotal > 0)
        ? primaryVal / grandTotal * 100
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      color: isOdd
          ? OpticsColors.surfaceElevated.withValues(alpha: 0.3)
          : Colors.transparent,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '${rank + 1}',
              style: const TextStyle(
                fontSize: 12,
                color: OpticsColors.textMuted,
              ),
            ),
          ),
          for (int i = 0; i < headers.length; i++)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: i == 0
                  ? Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            color: rowColor,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            row[headers[i]]?.toString() ?? '',
                            style: const TextStyle(
                              fontSize: 12,
                              color: OpticsColors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      row[headers[i]]?.toString() ?? '',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: numericCols.contains(headers[i])
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: numericCols.contains(headers[i])
                            ? rowColor
                            : OpticsColors.textSecondary,
                      ),
                      textAlign: numericCols.contains(headers[i])
                          ? TextAlign.right
                          : TextAlign.left,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
          if (showShare)
            SizedBox(
              width: 56,
              child: Text(
                '${share.toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontSize: 12,
                  color: OpticsColors.textSecondary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }

  Widget _renderKpi(List<Map<String, dynamic>> rows) {
    final y = query.viz.y;
    final first = rows.first;
    final v =
        y != null && first.containsKey(y) ? first[y] : first.values.first;
    return Container(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((y ?? '').toUpperCase(),
              style: OpticsTextStyles.sectionLabel),
          const SizedBox(height: OpticsSpacing.md),
          Text(v?.toString() ?? '—', style: OpticsTextStyles.kpiNumber),
        ],
      ),
    );
  }

  Widget _renderBar(List<Map<String, dynamic>> rows,
      {bool horizontal = false}) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null) return _renderTable(rows);
    final bars = _seriesFor(rows, x, y).take(20).toList();
    if (bars.isEmpty) return _renderTable(rows);
    if (horizontal) {
      return Container(
        padding: const EdgeInsets.all(OpticsSpacing.md),
        decoration: BoxDecoration(
          color: OpticsColors.surface,
          border: Border.all(color: OpticsColors.border),
          borderRadius: BorderRadius.circular(OpticsRadii.md),
        ),
        child: _HorizontalBars(bars: bars),
      );
    }
    return Container(
      padding: const EdgeInsets.all(OpticsSpacing.md),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          barGroups: [
            for (int i = 0; i < bars.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: bars[i].value,
                  color: OpticsColors.accentCyan,
                  width: 14,
                  borderRadius: BorderRadius.circular(3),
                ),
              ]),
          ],
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(0),
                        style: OpticsTextStyles.bodySm
                            .copyWith(fontSize: 10),
                      )),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= bars.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      bars[i].key.length > 10
                          ? '${bars[i].key.substring(0, 10)}…'
                          : bars[i].key,
                      style:
                          OpticsTextStyles.bodySm.copyWith(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _renderLine(List<Map<String, dynamic>> rows, {bool area = false}) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null) return _renderTable(rows);
    final series = _seriesFor(rows, x, y).toList();
    if (series.isEmpty) return _renderTable(rows);
    final pts = <FlSpot>[
      for (int i = 0; i < series.length; i++)
        FlSpot(i.toDouble(), series[i].value),
    ];
    return Container(
      padding: const EdgeInsets.all(OpticsSpacing.md),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: LineChart(
        LineChartData(
          lineBarsData: [
            LineChartBarData(
              spots: pts,
              isCurved: true,
              barWidth: 2,
              color: OpticsColors.accentCyan,
              dotData: const FlDotData(show: false),
              belowBarData: area
                  ? BarAreaData(
                      show: true,
                      color: OpticsColors.accentCyan
                          .withValues(alpha: 0.18),
                    )
                  : BarAreaData(show: false),
            ),
          ],
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
        ),
      ),
    );
  }

  Widget _renderPie(List<Map<String, dynamic>> rows, {bool donut = false}) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null) return _renderTable(rows);
    final slices = _seriesFor(rows, x, y).take(8).toList();
    if (slices.isEmpty) return _renderTable(rows);
    return Container(
      padding: const EdgeInsets.all(OpticsSpacing.md),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: PieChart(
        PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: donut ? 40 : 0,
          sections: [
            for (int i = 0; i < slices.length; i++)
              PieChartSectionData(
                value: slices[i].value,
                color: OpticsColors.chartPalette[
                    i % OpticsColors.chartPalette.length],
                title: slices[i].key.length > 8
                    ? '${slices[i].key.substring(0, 8)}…'
                    : slices[i].key,
                radius: 70,
                titleStyle: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w600),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Inline step guidance card ──────────────────────────────────────────────

/// A subtle informational callout used inside steps to explain rules the user
/// has to follow (e.g. GROUP BY / SELECT cardinality). Kept visually quiet so
/// it teaches without nagging.
class _StepGuidanceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _StepGuidanceCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.accentCyan.withValues(alpha: 0.06),
        border: Border.all(
            color: OpticsColors.accentCyan.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: OpticsSpacing.md, vertical: OpticsSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: OpticsColors.accentCyan),
          const SizedBox(width: OpticsSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: OpticsTextStyles.bodySm.copyWith(
                    color: OpticsColors.accentCyan,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: OpticsTextStyles.bodySm.copyWith(
                    color: OpticsColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Validation surfacing widgets ───────────────────────────────────────────

/// Compact banner above the preview area. Lists up to two issues with a
/// "Fix in Step N" jump link. Color shifts based on worst severity.
class _ValidationBanner extends StatelessWidget {
  final ValidationReport report;
  final ValueChanged<int> onJumpToStep;
  const _ValidationBanner({required this.report, required this.onJumpToStep});

  @override
  Widget build(BuildContext context) {
    final hasError = report.hasBlockers;
    final accent = hasError
        ? OpticsColors.danger
        : OpticsColors.warning;
    final icon = hasError ? Icons.error_outline : Icons.warning_amber_rounded;
    final shown = report.issues.take(2).toList();
    final more = report.issues.length - shown.length;

    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: OpticsSpacing.md, vertical: OpticsSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in shown) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 14, color: accent),
                const SizedBox(width: OpticsSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(issue.title,
                          style: OpticsTextStyles.bodySm.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          )),
                      const SizedBox(height: 2),
                      Text(issue.detail,
                          style: OpticsTextStyles.bodySm
                              .copyWith(color: OpticsColors.textSecondary)),
                      if (issue.fixHint != null) ...[
                        const SizedBox(height: 2),
                        Text(issue.fixHint!,
                            style: OpticsTextStyles.bodySm.copyWith(
                              color: OpticsColors.textMuted,
                              fontStyle: FontStyle.italic,
                            )),
                      ],
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => onJumpToStep(issue.step),
                  style: TextButton.styleFrom(
                    foregroundColor: accent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                  child: Text('Step ${issue.step + 1} →',
                      style: OpticsTextStyles.bodySm
                          .copyWith(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            if (issue != shown.last)
              const Divider(
                  height: OpticsSpacing.md,
                  color: OpticsColors.border),
          ],
          if (more > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '+ $more more — see step badges on the left.',
                style: OpticsTextStyles.bodySm
                    .copyWith(color: OpticsColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-panel view shown when validation has at least one error.
class _PreviewBlockedView extends StatelessWidget {
  final ValidationReport report;
  final ValueChanged<int> onJumpToStep;
  const _PreviewBlockedView(
      {required this.report, required this.onJumpToStep});

  @override
  Widget build(BuildContext context) {
    final blockers = report.blockers.toList();
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.danger.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline,
                  size: 18, color: OpticsColors.danger),
              const SizedBox(width: OpticsSpacing.sm),
              Text(
                blockers.length == 1
                    ? 'Preview is blocked by 1 issue'
                    : 'Preview is blocked by ${blockers.length} issues',
                style: OpticsTextStyles.body
                    .copyWith(color: OpticsColors.danger),
              ),
            ],
          ),
          const SizedBox(height: OpticsSpacing.md),
          for (final b in blockers) ...[
            Text(b.title,
                style: OpticsTextStyles.bodySm.copyWith(
                  color: OpticsColors.textPrimary,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 2),
            Text(b.detail,
                style: OpticsTextStyles.bodySm
                    .copyWith(color: OpticsColors.textSecondary)),
            if (b.fixHint != null) ...[
              const SizedBox(height: 2),
              Text(b.fixHint!,
                  style: OpticsTextStyles.bodySm.copyWith(
                    color: OpticsColors.textMuted,
                    fontStyle: FontStyle.italic,
                  )),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.east, size: 14),
                label: Text('Jump to Step ${b.step + 1}'),
                onPressed: () => onJumpToStep(b.step),
              ),
            ),
            if (b != blockers.last)
              const Divider(
                  height: OpticsSpacing.lg, color: OpticsColors.border),
          ],
        ],
      ),
    );
  }
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// Build an (X → Y) series for charts. When Y is null or non-numeric across
/// the dataset, falls back to counting rows per X value (categorical mode).
Iterable<MapEntry<String, double>> _seriesFor(
    List<Map<String, dynamic>> rows, String x, String? y) {
  if (y != null) {
    final numeric = rows
        .map((r) => _toDouble(r[y]))
        .whereType<double>()
        .isNotEmpty;
    if (numeric) {
      return rows
          .map((r) {
            final yv = _toDouble(r[y]);
            if (yv == null) return null;
            return MapEntry(r[x]?.toString() ?? '', yv);
          })
          .whereType<MapEntry<String, double>>();
    }
  }
  // Categorical fallback: count rows per X value.
  final counts = <String, double>{};
  for (final r in rows) {
    final k = r[x]?.toString() ?? '';
    counts[k] = (counts[k] ?? 0) + 1;
  }
  return counts.entries;
}

/// Toggle that flips the builder between wizard mode and raw-SQL mode.
/// Bryzos-only — caller is responsible for not rendering it for non-Bryzos.
class _RawSqlToggle extends ConsumerWidget {
  final CustomReportQueryV2 query;
  const _RawSqlToggle({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = query.useRawSql;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'EDIT SQL',
          style: OpticsTextStyles.bodySm.copyWith(
            color: active ? OpticsColors.accentCyan : OpticsColors.textMuted,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          height: 18,
          child: Switch(
            value: active,
            onChanged: (v) {
              if (v) {
                // Entering raw mode: confirm + seed with current SQL summary.
                showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: OpticsColors.surface,
                    title: const Text('Enable raw SQL mode?'),
                    content: const Text(
                      'The wizard will lock and the query will run exactly '
                      'as written. Only single-statement, read-only SELECT '
                      'or WITH queries are allowed.\n\n'
                      'Bryzos staff only.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Enable'),
                      ),
                    ],
                  ),
                ).then((confirmed) {
                  if (confirmed == true) {
                    ref.read(_builderProvider.notifier).setUseRawSql(
                          true,
                          seed: _summarySql(query),
                        );
                  }
                });
              } else {
                // Exiting raw mode — wizard takes over again.
                ref.read(_builderProvider.notifier).setUseRawSql(false);
              }
            },
          ),
        ),
      ],
    );
  }
}

/// Stateful raw-SQL editor — keeps its own controller so cursor position
/// survives the autoDispose preview rebuilds.
class _RawSqlEditor extends StatefulWidget {
  final String initialSql;
  final ValueChanged<String> onChanged;
  const _RawSqlEditor({required this.initialSql, required this.onChanged});

  @override
  State<_RawSqlEditor> createState() => _RawSqlEditorState();
}

class _RawSqlEditorState extends State<_RawSqlEditor> {
  late final TextEditingController _ctl;
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialSql);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _focus.requestFocus(),
      child: Container(
        decoration: BoxDecoration(
          color: OpticsColors.surfaceElevated,
          border: Border.all(color: OpticsColors.border),
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: TextField(
            controller: _ctl,
            focusNode: _focus,
            scrollController: _scroll,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(
              color: OpticsColors.textPrimary,
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.4,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: 'SELECT ...',
              hintStyle: TextStyle(
                color: OpticsColors.textMuted,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
              contentPadding: EdgeInsets.only(right: 12),
            ),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 600), () {
                widget.onChanged(v);
              });
            },
          ),
        ),
      ),
    );
  }
}

String _summarySql(CustomReportQueryV2 q) {
  if (q.primaryTable == null) return '-- pick a primary table';
  final sb = StringBuffer();
  sb.write('SELECT\n');
  final selectParts = <String>[
    for (final c in q.columns)
      '  ${_bare(c.table)}.${c.column} AS ${c.alias}',
    for (final a in q.aggregates)
      '  ${a.fn.toUpperCase()}(${_bare(a.table)}.${a.column}) AS ${a.alias}',
  ];
  if (selectParts.isEmpty) selectParts.add('  *');
  sb.write(selectParts.join(',\n'));
  sb.write('\nFROM ${_bare(q.primaryTable!)}\n');
  for (final j in q.joins) {
    final onPair = j.on.isEmpty ? null : j.on.first;
    final on = onPair == null
        ? ''
        : 'ON ${_bare(onPair.fromTable)}.${onPair.fromColumn} = ${_bare(onPair.toTable)}.${onPair.toColumn}';
    final lbl = j.type == JoinType.left ? 'LEFT JOIN' : 'INNER JOIN';
    sb.write('$lbl ${_bare(j.table)} $on\n');
  }
  if (q.filters.isNotEmpty) {
    sb.write('WHERE\n');
    sb.write(q.filters
        .map((f) =>
            '  ${_bare(f.table)}.${f.column} ${f.op} ${_renderValue(f)}')
        .join(' AND\n'));
    sb.write('\n');
  }
  if (q.groupBy.isNotEmpty) {
    sb.write('GROUP BY\n');
    sb.write(q.groupBy
        .map((g) => '  ${_bare(g.table)}.${g.column}')
        .join(',\n'));
    sb.write('\n');
  }
  if (q.orderBy.isNotEmpty) {
    sb.write('ORDER BY\n');
    sb.write(
        q.orderBy.map((o) => '  ${o.alias} ${o.dir}').join(',\n'));
    sb.write('\n');
  }
  if (q.limit != null) sb.write('LIMIT ${q.limit}\n');
  return sb.toString();
}

String _renderValue(FilterSpec f) {
  if (f.op == 'IS NULL' || f.op == 'IS NOT NULL') return '';
  if (f.value is List) {
    return '(${(f.value as List).join(', ')})';
  }
  return f.value == null ? 'NULL' : "'${f.value}'";
}

Widget _emptyState(String msg) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: OpticsSpacing.xxl),
    child: Center(
      child: Text(msg,
          style: OpticsTextStyles.bodySm
              .copyWith(color: OpticsColors.textMuted)),
    ),
  );
}

// ignore: unused_element
double _unused() => math.pi;

// ─── _DynamicWidthColumnPicker ──────────────────────────────────────────────
//
// A column dropdown whose popup menu sizes to its widest item rather than the
// trigger field's width. Used in the Filters step so users can read full
// `table.column` names like `user_purchase_order.freight_amount` without
// being truncated to `user_purchase_order.fr…`.
//
// The trigger button still respects whatever width its parent gives it
// (so the row layout stays intact); only the *open menu* grows.
class _DynamicWidthColumnPicker extends StatelessWidget {
  final String current;
  final List<(String, String, String)> allCols;
  final ValueChanged<String> onSelected;

  const _DynamicWidthColumnPicker({
    required this.current,
    required this.allCols,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final currentLabel = () {
      final parts = current.split('.');
      if (parts.length < 2) return current;
      final tbl = parts.sublist(0, parts.length - 1).join('.');
      final col = parts.last;
      return '${_bare(tbl)}.$col';
    }();

    return MenuAnchor(
      style: MenuStyle(
        backgroundColor:
            WidgetStatePropertyAll(OpticsColors.surfaceElevated),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: OpticsColors.border),
          ),
        ),
      ),
      menuChildren: [
        for (final c in allCols)
          MenuItemButton(
            onPressed: () => onSelected('${c.$1}.${c.$2}'),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                '${_bare(c.$1)}.${c.$2}',
                style: OpticsTextStyles.body,
              ),
            ),
          ),
      ],
      builder: (ctx, controller, _) {
        return InkWell(
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          borderRadius: BorderRadius.circular(6),
          child: InputDecorator(
            isEmpty: false,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    currentLabel,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: OpticsTextStyles.body,
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Horizontal bar chart ────────────────────────────────────────────────────
// fl_chart's BarChart is vertical-only, so we render H-Bar with a lightweight
// custom widget: a vertical list of rows, each with a category label, a
// proportionally-filled accent bar, and the numeric value.
class _HorizontalBars extends StatelessWidget {
  final List<MapEntry<String, double>> bars;
  const _HorizontalBars({required this.bars});

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) return const SizedBox.shrink();
    final maxV = bars
        .map((e) => e.value.abs())
        .fold<double>(0, (a, b) => a > b ? a : b);
    return LayoutBuilder(
      builder: (context, c) {
        final labelW = (c.maxWidth * 0.28).clamp(80.0, 180.0);
        final valueW = (c.maxWidth * 0.14).clamp(60.0, 120.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final b in bars)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: labelW,
                      child: Text(
                        b.key,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style:
                            OpticsTextStyles.bodySm.copyWith(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: OpticsSpacing.sm),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          height: 14,
                          color: OpticsColors.border.withValues(alpha: 0.25),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor:
                                  maxV == 0 ? 0 : (b.value.abs() / maxV),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: OpticsColors.accentCyan,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: OpticsSpacing.sm),
                    SizedBox(
                      width: valueW,
                      child: Text(
                        _fmtBarValue(b.value),
                        textAlign: TextAlign.right,
                        style:
                            OpticsTextStyles.bodySm.copyWith(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static String _fmtBarValue(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e9) {
      return v.toStringAsFixed(0);
    }
    return v.toStringAsFixed(2);
  }
}
