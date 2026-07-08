import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/theme.dart';
import '../../shared/secure_error.dart';
import '../reports/custom_builder/canned_metric_to_query_v2.dart';
import '../reports/custom_builder/query_v2_sql_generator.dart';
import 'time_range_options.dart';
import 'time_range_picker.dart';

/// The per-widget settings panel that matches the spec mockups.
/// Page 1 (Basics): Title · Chart Type · Color Scheme · Group By · Sort By · Time Range.
/// Page 2 (Data & Display): Data Filters · Max Items · Display toggles · Auto-Refresh.
/// Page 3 (SQL) — Bryzos users only: Raw SQL editor + table/column reference browser.
/// Footer: Reset / Cancel / Apply.
///
/// **Reset** restores the widget to its ORIGINAL state (when the panel was opened),
/// not to arbitrary defaults.
class WidgetSettingsPanel extends ConsumerStatefulWidget {
  final WidgetModel widget;
  final void Function(WidgetModel updated) onApply;
  final VoidCallback onCancel;
  /// Called on every setting change for live preview — updates the widget
  /// in-place without persisting to the database.
  final void Function(WidgetModel preview)? onPreview;
  const WidgetSettingsPanel({
    super.key,
    required this.widget,
    required this.onApply,
    required this.onCancel,
    this.onPreview,
  });

  @override
  ConsumerState<WidgetSettingsPanel> createState() => _WidgetSettingsPanelState();
}

/// Provider for the RDS catalog (table + column list). Cached across panel opens.
final _widgetSqlCatalogProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return ref.read(repoProvider).rdsCatalog();
});

class _WidgetSettingsPanelState extends ConsumerState<WidgetSettingsPanel> {
  late TextEditingController _title;
  late WidgetKind _kind;

  String? get _metric {
    final brz = widget.widget.binding['brz'];
    if (brz is Map) {
      return (brz['metric'] as String?)?.toLowerCase();
    }
    return null;
  }

  bool get _disallowPieDonut => _metric == 'avg_order_price_trend';

  /// The SQL tab is Bryzos-only. Non-Bryzos users never see this option — the
  /// panel shows only Basics + Data & Display, exactly as before.
  bool get _showSqlTab => isBryzosUser(ref);
  late String _colorScheme;
  late String _groupBy;
  late String _sortBy;
  late String _timeRange;
  late int _maxItems;
  late String _barOrientation;
  late Map<String, bool> _toggles;
  late Map<String, bool> _filters;
  int _page = 0;

  // ── Raw SQL escape hatch (Bryzos-only) ──
  late TextEditingController _rawSql;
  // Column browser filter (Bryzos-only SQL tab)
  String _catalogFilter = '';
  // Tracks which tables are expanded in the reference browser.
  final Set<String> _expandedTables = <String>{};

  // ── Original values (for Reset) ──
  late final String _origTitle;
  late final WidgetKind _origKind;
  late final String _origColorScheme;
  late final String _origGroupBy;
  late final String _origSortBy;
  late final String _origTimeRange;
  late final int _origMaxItems;
  late final String _origBarOrientation;
  late final Map<String, bool> _origToggles;
  late final Map<String, bool> _origFilters;
  late final String _origRawSql;

  @override
  void initState() {
    super.initState();
    final s = widget.widget.settings;

    // brz binding — used as fallback for values the settings panel may not
    // have written yet (e.g. max_items / time_range authored on the library item).
    final brz = () {
      final b = widget.widget.binding['brz'];
      if (b is Map) return b.cast<String, dynamic>();
      return <String, dynamic>{};
    }();

    // Current & original values — initialized from the widget.
    // Resolution order: user-set settings → brz binding authored default → hardcoded fallback.
    // This prevents the settings panel from clobbering the library-item defaults when
    // the user opens settings (e.g. to change chart type) without touching max_items/time_range.
    _origTitle = widget.widget.title;
    _origKind = widget.widget.kind;
    _origColorScheme = s['colorScheme'] as String? ?? 'Default';
    _origGroupBy = s['groupBy'] as String? ?? 'Shape';
    _origSortBy = s['sortBy'] as String? ?? 'Value ↓';
    final sTimeRange = s['timeRange'] as String?;
    _origTimeRange = migrateTimeRange(
      (sTimeRange != null && sTimeRange.isNotEmpty) ? sTimeRange : (brz['time_range'] as String?),
    );
    _origMaxItems = (s['maxItems'] as num?)?.toInt()
        ?? (brz['max_items'] as num?)?.toInt()
        ?? 10;
    _origBarOrientation = s['barOrientation'] as String? ?? 'Auto';
    _origToggles = {
      'Data Labels': (s['dataLabels'] as bool?) ?? false,
      'Legend': (s['legend'] as bool?) ?? true,
      'Grid Lines': (s['gridLines'] as bool?) ?? true,
      'Tooltips': (s['tooltips'] as bool?) ?? true,
      'Values': (s['values'] as bool?) ?? true,
      'Percentages': (s['percentages'] as bool?) ?? false,
      'Animate': (s['animate'] as bool?) ?? true,
    };
    _origFilters = {
      'Include Zero Stock': (s['includeZeroStock'] as bool?) ?? false,
      'Include Reserved': (s['includeReserved'] as bool?) ?? true,
      'Show Reorder Level': (s['showReorderLevel'] as bool?) ?? false,
    };
    // Raw SQL escape hatch — stored under binding.raw_sql.
    _origRawSql =
        (widget.widget.binding['raw_sql'] as String?)?.toString() ?? '';
    _rawSql = TextEditingController(text: _origRawSql);
    _rawSql.addListener(_emitPreview);

    // Set current values
    _title = TextEditingController(text: _origTitle);
    _title.addListener(_emitPreview); // Live preview title changes
    _kind = _origKind;
    if (_disallowPieDonut && (_kind == WidgetKind.pie || _kind == WidgetKind.donut)) {
      _kind = WidgetKind.line;
    }
    _colorScheme = _origColorScheme;
    _groupBy = _origGroupBy;
    _sortBy = _origSortBy;
    _timeRange = _origTimeRange;
    _maxItems = _origMaxItems;
    _barOrientation = _origBarOrientation;
    _toggles = Map<String, bool>.from(_origToggles);
    _filters = Map<String, bool>.from(_origFilters);
  }

  @override
  void dispose() {
    _title.removeListener(_emitPreview);
    _title.dispose();
    _rawSql.removeListener(_emitPreview);
    _rawSql.dispose();
    super.dispose();
  }

  /// Build a WidgetModel from current panel state (used for both preview & apply).
  WidgetModel _buildCurrentModel() {
    // Merge raw_sql into binding. Empty string clears the escape hatch so the
    // widget falls back to the canned brz.metric pipeline.
    final rawSqlText = _rawSql.text.trim();
    final mergedBinding = Map<String, dynamic>.from(widget.widget.binding);
    if (rawSqlText.isEmpty) {
      mergedBinding.remove('raw_sql');
      mergedBinding.remove('raw_sql_author_email');
    } else {
      mergedBinding['raw_sql'] = rawSqlText;
      // Stamp the current Bryzos author so the runtime knows the SQL was
      // authored by a Bryzos user (used later for shared-viewer execution).
      final email =
          ref.read(supabaseProvider).auth.currentUser?.email;
      if (email != null && isBryzosEmail(email)) {
        mergedBinding['raw_sql_author_email'] = email;
      }
    }
    return widget.widget.copyWith(
      title: _title.text.trim().isEmpty ? widget.widget.title : _title.text.trim(),
      kind: _kind,
      binding: mergedBinding,
      settings: {
        ...widget.widget.settings,
        'colorScheme': _colorScheme,
        'groupBy': _groupBy,
        'sortBy': _sortBy,
        'timeRange': _timeRange,
        'maxItems': _maxItems,
        'barOrientation': _barOrientation,
        'dataLabels': _toggles['Data Labels'],
        'legend': _toggles['Legend'],
        'gridLines': _toggles['Grid Lines'],
        'tooltips': _toggles['Tooltips'],
        'values': _toggles['Values'],
        'percentages': _toggles['Percentages'],
        'animate': _toggles['Animate'],
        'includeZeroStock': _filters['Include Zero Stock'],
        'includeReserved': _filters['Include Reserved'],
        'showReorderLevel': _filters['Show Reorder Level'],
      },
    );
  }

  /// Emit a live preview to the parent (if onPreview is provided).
  void _emitPreview() {
    widget.onPreview?.call(_buildCurrentModel());
  }

  /// Wrapper that calls setState then emits a preview.
  void _updateAndPreview(VoidCallback fn) {
    setState(fn);
    _emitPreview();
  }

  void _apply() {
    widget.onApply(_buildCurrentModel());
  }

  /// Reset restores the widget to its ORIGINAL state when the settings panel
  /// was opened — not to generic defaults.
  void _reset() {
    setState(() {
      _title.text = _origTitle;
      _kind = _origKind;
      _colorScheme = _origColorScheme;
      _groupBy = _origGroupBy;
      _sortBy = _origSortBy;
      _timeRange = _origTimeRange;
      _rawSql.text = _origRawSql;
      _maxItems = _origMaxItems;
      _barOrientation = _origBarOrientation;
      _toggles = Map<String, bool>.from(_origToggles);
      _filters = Map<String, bool>.from(_origFilters);
    });
    _emitPreview();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      decoration: const BoxDecoration(
        color: OpticsColors.surface,
        border: Border(left: BorderSide(color: OpticsColors.border)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: OpticsSpacing.lg, vertical: OpticsSpacing.md),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: OpticsColors.border)),
            ),
            child: Row(
              children: [
                const Text('WIDGET SETTINGS', style: OpticsTextStyles.headingXl),
                const Spacer(),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: widget.onCancel,
                ),
              ],
            ),
          ),
          _PageTabs(
            page: _page,
            labels: _showSqlTab
                ? const ['Basics', 'Data & Display', 'SQL']
                : const ['Basics', 'Data & Display'],
            onChange: (p) => setState(() => _page = p),
          ),
          Expanded(
            child: _page == 2 && _showSqlTab
                // SQL tab has its own internal layout (editor + reference browser)
                // that manages its own scrolling regions — don't wrap in a global
                // scroll view.
                ? Padding(
                    padding: const EdgeInsets.all(OpticsSpacing.lg),
                    child: _pageSql(),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(OpticsSpacing.lg),
                    child: _page == 0 ? _page1() : _page2(),
                  ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: OpticsSpacing.lg, vertical: OpticsSpacing.md),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: OpticsColors.border)),
            ),
            child: Row(
              children: [
                TextButton(onPressed: _reset, child: const Text('Reset')),
                const Spacer(),
                TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _apply, child: const Text('Apply')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(t.toUpperCase(), style: OpticsTextStyles.sectionLabel),
      );

  Widget _page1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Widget title'),
        TextField(controller: _title),
        _label('Chart type'),
        _ChipGroup<WidgetKind>(
          options: [
            const ('KPI', WidgetKind.kpi),
            const ('Line', WidgetKind.line),
            const ('Bar', WidgetKind.barVertical),
            const ('Combo', WidgetKind.combo),
            if (!_disallowPieDonut) ...[
              const ('Pie', WidgetKind.pie),
              const ('Donut', WidgetKind.donut),
            ],
            const ('Table', WidgetKind.table),
          ],
          value: (_disallowPieDonut && (_kind == WidgetKind.pie || _kind == WidgetKind.donut))
              ? WidgetKind.line
              : _kind,
          onChanged: (v) => _updateAndPreview(() => _kind = v),
        ),
        if (_kind == WidgetKind.barVertical ||
            _kind == WidgetKind.barHorizontal ||
            _kind == WidgetKind.barGrouped ||
            _kind == WidgetKind.barStacked) ...[
          _label('Bar orientation'),
          _ChipGroup<String>(
            options: const [
              ('Auto', 'Auto'),
              ('Vertical', 'Vertical'),
              ('Horizontal', 'Horizontal'),
            ],
            value: _barOrientation,
            onChanged: (v) => _updateAndPreview(() => _barOrientation = v),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Auto picks the best orientation based on label length and category count.',
              style: TextStyle(
                fontSize: 11,
                color: OpticsColors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
        ],
        _label('Color scheme'),
        _ChipGroup<String>(
          options: const [
            ('Default', 'Default'),
            ('Cool', 'Cool'),
            ('Warm', 'Warm'),
            ('Mono', 'Mono'),
            ('Neon', 'Neon'),
          ],
          value: _colorScheme,
          onChanged: (v) => _updateAndPreview(() => _colorScheme = v),
        ),
        _label('Group by'),
        _ChipGroup<String>(
          options: const [
            ('Shape', 'Shape'),
            ('Grade', 'Grade'),
            ('Company', 'Company'),
            ('User', 'User'),
            ('Bracket', 'Bracket'),
            ('Status', 'Status'),
          ],
          value: _groupBy,
          onChanged: (v) => _updateAndPreview(() => _groupBy = v),
        ),
        _label('Sort by'),
        _ChipGroup<String>(
          options: const [
            ('None', 'None'),
            ('Value ↓', 'Value ↓'),
            ('Value ↑', 'Value ↑'),
            ('Qty ↓', 'Qty ↓'),
            ('Qty ↑', 'Qty ↑'),
            ('A–Z', 'A–Z'),
          ],
          value: _sortBy,
          onChanged: (v) => _updateAndPreview(() => _sortBy = v),
        ),
        _label('Default time range'),
        TimeRangePicker(
          value: _timeRange,
          onChanged: (v) => _updateAndPreview(() => _timeRange = v),
        ),
      ],
    );
  }

  Widget _page2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Data filters'),
        for (final entry in _filters.entries)
          _ToggleRow(
            label: entry.key,
            value: entry.value,
            onChanged: (v) => _updateAndPreview(() => _filters[entry.key] = v),
          ),
        _label('Max items'),
        _ChipGroup<int>(
          options: const [
            ('5', 5),
            ('10', 10),
            ('20', 20),
            ('50', 50),
            ('100', 100),
          ],
          value: _maxItems,
          onChanged: (v) => _updateAndPreview(() => _maxItems = v),
        ),
        _label('Display'),
        for (final entry in _toggles.entries)
          _ToggleRow(
            label: entry.key,
            value: entry.value,
            onChanged: (v) => _updateAndPreview(() => _toggles[entry.key] = v),
          ),
      ],
    );
  }

  // ── Bryzos-only SQL tab ──────────────────────────────────────────────────
  //
  // Top half: raw SQL editor. On Apply the SQL is persisted to
  // widget.binding.raw_sql — the widget renderer routes to
  // rds_execute_raw_sql_bryzos when this is non-empty, otherwise falls back
  // to the canned brz.metric pipeline.
  //
  // Bottom half: table + column reference browser (rds_catalog). Clicking a
  // column inserts "table"."column" at the caret position of the editor.
  Widget _pageSql() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Widget SQL (Bryzos-only)'),
        // Editor
        Expanded(
          flex: 5,
          child: Container(
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              border: Border.all(color: OpticsColors.border),
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
            ),
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _rawSql,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
              decoration: const InputDecoration.collapsed(
                hintText:
                    'SELECT ...\nFROM "rds_..."\nWHERE ...\n\nLeave empty to use the widget\'s default metric.',
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // "Load this widget's SQL" — Bryzos-only affordance. Only visible when
        // (a) the widget's canned metric has a query_v2 translation available,
        // and (b) the editor is currently empty. Clicking pre-fills the
        // editor with the Postgres SQL equivalent of the canned metric so the
        // user has an editable starting point.
        if (isCannedMetricTranslatable(_metric) && _rawSql.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.download_outlined, size: 14),
                label: const Text("Load this widget's SQL"),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 11),
                ),
                onPressed: () {
                  final metric = _metric;
                  if (metric == null) return;
                  final translation = translateCannedMetric(
                    metric: metric,
                    timeRange: _timeRange,
                  );
                  if (translation == null) return;
                  final sql = generateSqlFromQueryV2(translation.query);
                  setState(() {
                    _rawSql.text = sql.combined();
                  });
                  _emitPreview();
                },
              ),
            ),
          ),
        Text(
          'Executes via rds_execute_raw_sql_bryzos (read-only, tenant-scoped, single statement).',
          style: TextStyle(
            fontSize: 10,
            color: OpticsColors.textSecondary,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        _label('Tables & columns'),
        // Search box for column browser
        SizedBox(
          height: 30,
          child: TextField(
            onChanged: (v) => setState(() => _catalogFilter = v.trim().toLowerCase()),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter tables / columns…',
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
                borderSide: const BorderSide(color: OpticsColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
                borderSide: const BorderSide(color: OpticsColors.border),
              ),
            ),
            style: const TextStyle(fontSize: 11),
          ),
        ),
        const SizedBox(height: 6),
        // Column browser (scrollable)
        Expanded(
          flex: 4,
          child: Container(
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              border: Border.all(color: OpticsColors.border),
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
            ),
            child: Builder(
              builder: (context) {
                final async = ref.watch(_widgetSqlCatalogProvider);
                return async.when(
                  loading: () => const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      isBryzosUser(ref) ? 'Catalog error: $e' : 'Catalog unavailable.',
                      style: const TextStyle(fontSize: 11, color: OpticsColors.danger),
                    ),
                  ),
                  data: (tables) => _buildCatalogList(tables),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Renders the filtered table/column list. Click a table to expand; click
  /// a column to insert `"table"."column"` at the current caret position.
  Widget _buildCatalogList(List<Map<String, dynamic>> tables) {
    final filter = _catalogFilter;
    // Filter tables: keep any table whose name/display matches, OR any table
    // that has at least one column matching. For matching tables, we still
    // show all columns; for tables that only match via columns, we show only
    // the matching columns.
    final filtered = <Map<String, dynamic>>[];
    for (final t in tables) {
      final tName = (t['table_name'] as String? ?? '').toLowerCase();
      final tDisplay = (t['display_name'] as String? ?? '').toLowerCase();
      final tableMatches = filter.isEmpty ||
          tName.contains(filter) ||
          tDisplay.contains(filter);
      final cols = (t['columns'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      if (tableMatches) {
        filtered.add(t);
      } else {
        final matchedCols = cols.where((c) =>
            (c['name'] as String? ?? '').toLowerCase().contains(filter)).toList();
        if (matchedCols.isNotEmpty) {
          filtered.add({
            ...t,
            'columns': matchedCols,
            '_partial': true,
          });
        }
      }
    }

    if (filtered.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'No matches.',
            style: TextStyle(fontSize: 11, color: OpticsColors.textSecondary),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final t = filtered[i];
        final tName = t['table_name'] as String;
        final tDisplay = t['display_name'] as String? ?? tName;
        // Auto-expand when the user is filtering (so column matches are visible).
        final expanded = filter.isNotEmpty || _expandedTables.contains(tName);
        final cols = (t['columns'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() {
                if (_expandedTables.contains(tName)) {
                  _expandedTables.remove(tName);
                } else {
                  _expandedTables.add(tName);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 14,
                      color: OpticsColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        tName,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: OpticsColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      tDisplay,
                      style: TextStyle(
                        fontSize: 10,
                        color: OpticsColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (expanded)
              for (final c in cols)
                InkWell(
                  onTap: () => _insertAtCursor('"$tName"."${c['name']}"'),
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 26, right: 8, top: 2, bottom: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            c['name'] as String,
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: OpticsColors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          (c['data_type'] as String? ?? '').toLowerCase(),
                          style: TextStyle(
                            fontSize: 9,
                            color: OpticsColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }

  /// Inserts text at the current caret position of the raw SQL editor. If the
  /// editor has no selection (e.g. never focused), appends to the end.
  void _insertAtCursor(String text) {
    final sel = _rawSql.selection;
    final current = _rawSql.text;
    if (sel.isValid && sel.start >= 0 && sel.start <= current.length) {
      final before = current.substring(0, sel.start);
      final after = current.substring(sel.end);
      final next = '$before$text$after';
      _rawSql.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: (before + text).length),
      );
    } else {
      final needsSpace = current.isNotEmpty && !current.endsWith(' ') && !current.endsWith('\n');
      final next = '$current${needsSpace ? ' ' : ''}$text';
      _rawSql.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
    // Also copy to clipboard for convenience so the user can paste elsewhere.
    Clipboard.setData(ClipboardData(text: text));
  }
}

class _PageTabs extends StatelessWidget {
  final int page;
  final List<String> labels;
  final ValueChanged<int> onChange;
  const _PageTabs({
    required this.page,
    required this.labels,
    required this.onChange,
  });
  @override
  Widget build(BuildContext context) {
    Widget tab(int i, String label) {
      final active = page == i;
      return Expanded(
        child: InkWell(
          onTap: () => onChange(i),
          child: Container(
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? OpticsColors.accentCyan : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active
                    ? OpticsColors.textPrimary
                    : OpticsColors.textSecondary,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: OpticsColors.border)),
      ),
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) tab(i, labels[i]),
        ],
      ),
    );
  }
}

class _ChipGroup<T> extends StatelessWidget {
  final List<(String, T)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const _ChipGroup({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          GestureDetector(
            onTap: () => onChanged(o.$2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: value == o.$2
                    ? OpticsColors.accentCyan.withValues(alpha: 0.12)
                    : OpticsColors.surfaceElevated,
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
                border: Border.all(
                  color: value == o.$2
                      ? OpticsColors.accentCyan
                      : OpticsColors.border,
                ),
              ),
              child: Text(
                o.$1,
                style: TextStyle(
                  fontSize: 12,
                  color: value == o.$2
                      ? OpticsColors.accentCyan
                      : OpticsColors.textPrimary,
                  fontWeight: value == o.$2 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: OpticsTextStyles.body)),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: OpticsColors.accentCyan,
          ),
        ],
      ),
    );
  }
}


// _TimeRangePicker promoted to public `TimeRangePicker` in time_range_picker.dart
// (shared with the dashboard-level Default Time Range control).
