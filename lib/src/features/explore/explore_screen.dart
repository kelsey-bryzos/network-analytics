// =====================================================================
// Report Builder
// ---------------------------------------------------------------------
// Excel-style report-authoring surface. Replaces the old "Data Explorer"
// schema browser.
//
// Layout
//   ┌─────────────────────────────────────────────────────────────┐
//   │ Report Builder · <Report Title>   [Table | Widget]  Publish │
//   ├─────────────┬───────────────────────────────────────────────┤
//   │ CATALOG     │  CANVAS                                       │
//   │  ▸ Table A  │  ┌──────────────────────────────────────────┐ │
//   │    • col 1  │  │  growing data table (drag cols here)     │ │
//   │    • col 2  │  └──────────────────────────────────────────┘ │
//   │  ▸ Table B  │                                               │
//   │    …        │                                               │
//   └─────────────┴───────────────────────────────────────────────┘
//
// Behavior
//   - Left panel: all `rds_*` mirror tables, collapsible, with their
//     columns nested underneath. Searchable.
//   - Drag a column onto the canvas → it becomes the next column in
//     a growing Excel-style table. All columns must come from the
//     same upstream table (we hint, then block, mismatched drops).
//   - Top-right toggle: Table view / Widget view.
//       * Table view  — Excel-style growing table.
//       * Widget view — full chart builder (type · X axis · Y measure ·
//                       aggregation · color scheme), live-rendered with
//                       fl_chart against the same column selection.
//   - Auto-save: every change debounced 800 ms → updateReportLayout.
//   - Publish: flips status to `live`.
//   - Share: toggles reports.shared_with_tenant.
//   - Export CSV: download current table view.
//   - `?reportId=<id>` query param hydrates the canvas with an
//     existing report's saved column selection + widget config.
// =====================================================================

import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/canvas_zoom.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';

// ── Providers ─────────────────────────────────────────────────────────────

/// Pick the first REST data source for the active tenant.
final _activeRestSourceProvider = FutureProvider<DataSource?>((ref) async {
  ref.watch(activeTenantProvider);
  final sources = await ref.watch(dataSourcesProvider.future);
  for (final s in sources) {
    if (s.kind == 'rest') return s;
  }
  return null;
});

/// Full schema catalog — every `rds_*` table + columns.
final _catalogProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.watch(activeTenantProvider);
  return ref.watch(repoProvider).rdsCatalog();
});

/// System-curated relationships + display expressions.
/// Powers the "virtual" columns (Buyer Name, Buyer Company, etc.) that appear
/// in the catalog under any base table whose FK columns target another mirror
/// with a registered display expression.
final _relationsProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  ref.watch(activeTenantProvider);
  return ref.watch(repoProvider).rdsRelations();
});

/// Live data for the current column selection. Re-runs whenever the
/// selected (table, columns) tuple changes.
class _PreviewArgs {
  final String dataSourceId;
  final String table;
  /// Each entry is a column projection for `rds_select_joined` —
  /// `{alias, column}` (real) or `{alias, path, expr}` (virtual).
  final List<Map<String, dynamic>> columns;
  final int? limit;
  /// Stable key used for value equality across projection lists.
  final String _key;
  _PreviewArgs({
    required this.dataSourceId,
    required this.table,
    required this.columns,
    required this.limit,
  }) : _key = jsonEncode(columns);

  @override
  bool operator ==(Object other) =>
      other is _PreviewArgs &&
      other.dataSourceId == dataSourceId &&
      other.table == table &&
      other.limit == limit &&
      other._key == _key;
  @override
  int get hashCode =>
      Object.hash(dataSourceId, table, limit, _key);
}

final _previewProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, _PreviewArgs>((ref, args) async {
  if (args.columns.isEmpty) return const [];
  return ref.watch(repoProvider).rdsSelectJoined(
        dataSourceId: args.dataSourceId,
        baseTable: args.table,
        columns: args.columns,
        limit: args.limit,
      );
});

/// One column on the report canvas.
///
/// Two shapes exist:
///   * **Real column** — a column physically present on `table`. `path` and
///     `expr` are null. `column` is the upstream column name on `table`.
///   * **Virtual column** — a human-friendly column auto-derived from a chain
///     of foreign-key hops + a display expression. `table` is the BASE table
///     the report is anchored to (so virtuals from different base tables are
///     still mutually exclusive in the same report). `path` is the FK chain
///     from `table` to the final hop; `expr` is the SQL display expression
///     evaluated on the final hop. `column` is the alias used as the output
///     column name (e.g. `buyer_name`).
class _DraggedColumn {
  final String table;          // base table (bare upstream name)
  final String tableDisplay;   // display name of base table
  final String column;         // real col name OR alias for virtual
  final String dataType;       // upstream type or 'text' for virtuals
  final List<Map<String, String>>? path; // join hops; null for real cols
  final String? expr;          // SQL display expr; null for real cols
  final String? virtualLabel;  // pretty label (e.g. "Buyer Name")

  const _DraggedColumn({
    required this.table,
    required this.tableDisplay,
    required this.column,
    required this.dataType,
    this.path,
    this.expr,
    this.virtualLabel,
  });

  bool get isVirtual => path != null && expr != null;

  /// Display label to show in column headers and the catalog.
  String get label => virtualLabel ?? column;

  Map<String, dynamic> toRpcColumn() {
    if (isVirtual) {
      return {
        'alias': column,
        'path': path,
        'expr': expr,
      };
    }
    return {
      'alias': column,
      'column': column,
    };
  }

  Map<String, dynamic> toJson() => {
        'table': table,
        'table_display': tableDisplay,
        'column': column,
        'data_type': dataType,
        if (path != null) 'path': path,
        if (expr != null) 'expr': expr,
        if (virtualLabel != null) 'virtual_label': virtualLabel,
      };

  factory _DraggedColumn.fromJson(Map m) {
    final rawPath = m['path'];
    List<Map<String, String>>? path;
    if (rawPath is List) {
      path = rawPath
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList();
    }
    return _DraggedColumn(
      table: m['table'] as String? ?? '',
      tableDisplay: m['table_display'] as String? ?? '',
      column: m['column'] as String? ?? '',
      dataType: m['data_type'] as String? ?? 'text',
      path: path,
      expr: m['expr'] as String?,
      virtualLabel: m['virtual_label'] as String?,
    );
  }
}

/// Tiny BFS frontier node used by the auto-link pathfinder. Walks the
/// `rds_relationships` graph from a base table to the dropped column's
/// table and records the FK chain so the drop can be promoted to a
/// virtual joined column.
class _BfsNode {
  final String table;
  final List<Map<String, String>> path;
  const _BfsNode(this.table, this.path);
}

/// Payload for an in-canvas column reorder drag (header → header).
class _ColumnReorder {
  final int fromIndex;
  const _ColumnReorder({required this.fromIndex});
}

// ── Screen ────────────────────────────────────────────────────────────────

enum _BuilderView { table, blended, widgetView }

enum _ChartKind { kpi, bar, hbar, line, area, combo, pie, donut, gauge, table }

extension _ChartKindX on _ChartKind {
  String get wire => name;
  static _ChartKind fromString(String? s) {
    switch (s) {
      case 'kpi':   return _ChartKind.kpi;
      case 'hbar':  return _ChartKind.hbar;
      case 'line':  return _ChartKind.line;
      case 'area':  return _ChartKind.area;
      case 'combo': return _ChartKind.combo;
      case 'pie':   return _ChartKind.pie;
      case 'donut': return _ChartKind.donut;
      case 'gauge': return _ChartKind.gauge;
      case 'table': return _ChartKind.table;
      case 'bar':
      default:      return _ChartKind.bar;
    }
  }
  String get label {
    switch (this) {
      case _ChartKind.kpi:   return 'KPI';
      case _ChartKind.bar:   return 'Bar';
      case _ChartKind.hbar:  return 'H-Bar';
      case _ChartKind.line:  return 'Line';
      case _ChartKind.area:  return 'Area';
      case _ChartKind.combo: return 'Combo';
      case _ChartKind.pie:   return 'Pie';
      case _ChartKind.donut: return 'Donut';
      case _ChartKind.gauge: return 'Gauge';
      case _ChartKind.table: return 'Table';
    }
  }
  IconData get icon {
    switch (this) {
      case _ChartKind.kpi:   return Icons.numbers;
      case _ChartKind.bar:   return Icons.bar_chart;
      case _ChartKind.hbar:  return Icons.align_horizontal_left;
      case _ChartKind.line:  return Icons.show_chart;
      case _ChartKind.area:  return Icons.area_chart;
      case _ChartKind.combo: return Icons.insights;
      case _ChartKind.pie:   return Icons.pie_chart_outline;
      case _ChartKind.donut: return Icons.donut_large;
      case _ChartKind.gauge: return Icons.speed;
      case _ChartKind.table: return Icons.table_chart_outlined;
    }
  }
}

enum _Aggregation { sum, count, avg, min, max }

extension _AggX on _Aggregation {
  String get wire => name;
  static _Aggregation fromString(String? s) {
    switch (s) {
      case 'count': return _Aggregation.count;
      case 'avg':   return _Aggregation.avg;
      case 'min':   return _Aggregation.min;
      case 'max':   return _Aggregation.max;
      case 'sum':
      default:      return _Aggregation.sum;
    }
  }
  String get label {
    switch (this) {
      case _Aggregation.sum:   return 'Sum';
      case _Aggregation.count: return 'Count';
      case _Aggregation.avg:   return 'Average';
      case _Aggregation.min:   return 'Min';
      case _Aggregation.max:   return 'Max';
    }
  }
}

class _WidgetConfig {
  _ChartKind kind;
  String? xColumn; // dimension
  String? yColumn; // measure (null when kind = count or kpi-count)
  _Aggregation agg;
  String colorScheme; // 'default' | 'cool' | 'warm' | 'mono' | 'neon'
  int maxItems;
  bool showLegend;
  bool showGrid;
  bool showLabels;

  _WidgetConfig({
    this.kind = _ChartKind.bar,
    this.xColumn,
    this.yColumn,
    this.agg = _Aggregation.sum,
    this.colorScheme = 'default',
    this.maxItems = 10,
    this.showLegend = true,
    this.showGrid = true,
    this.showLabels = true,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        if (xColumn != null) 'x': xColumn,
        if (yColumn != null) 'y': yColumn,
        'agg': agg.wire,
        'color_scheme': colorScheme,
        'max_items': maxItems,
        'show_legend': showLegend,
        'show_grid': showGrid,
        'show_labels': showLabels,
      };

  factory _WidgetConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return _WidgetConfig();
    return _WidgetConfig(
      kind: _ChartKindX.fromString(j['kind'] as String?),
      xColumn: j['x'] as String?,
      yColumn: j['y'] as String?,
      agg: _AggX.fromString(j['agg'] as String?),
      colorScheme: (j['color_scheme'] as String?) ?? 'default',
      maxItems: (j['max_items'] as num?)?.toInt() ?? 10,
      showLegend: j['show_legend'] as bool? ?? true,
      showGrid: j['show_grid'] as bool? ?? true,
      showLabels: j['show_labels'] as bool? ?? true,
    );
  }
}

class ExploreScreen extends ConsumerStatefulWidget {
  final String? reportId;
  const ExploreScreen({super.key, this.reportId});
  @override
  ConsumerState<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends ConsumerState<ExploreScreen> {
  // ── Canvas state ──
  String? _selectedTable;                 // e.g. "user_purchase_order"
  String? _selectedTableDisplay;          // e.g. "User Purchase Order"
  final List<_DraggedColumn> _columns = [];
  Report? _report;                        // null until loaded / created
  String _title = 'Untitled Report';
  String _search = '';
  _BuilderView _view = _BuilderView.table;
  // null = "All rows" (no LIMIT). Default to 100 rows.
  int? _previewLimit = 100;
  _WidgetConfig _widget = _WidgetConfig();

  /// Widgets carried over from a canned-report clone (uses the
  /// `layout.pages[].widgets[]` schema, NOT the column-builder schema).
  /// These are surfaced read-only in the builder so the user can see what
  /// they inherited and isn't presented with a blank canvas.  Preserved
  /// verbatim on save so PDF/Excel exports still have content.
  List<Map<String, dynamic>> _carriedPages = const [];

  // Width of the right-side live preview panel, in logical pixels.
  // User can resize it by dragging the divider between center and right panels.
  // The middle (canvas) panel uses Expanded so it absorbs whatever's left.
  double _rightPanelWidth = 360;
  static const double _rightPanelMin = 240;
  static const double _rightPanelMax = 900;

  // ── Auto-save plumbing ──
  Timer? _saveDebounce;
  bool _saving = false;
  DateTime? _lastSavedAt;
  bool _dirty = false;

  // ── Catalog UI state ──
  final Set<String> _expanded = {}; // tables expanded in the left panel

  @override
  void initState() {
    super.initState();
    if (widget.reportId != null && widget.reportId!.isNotEmpty) {
      _loadReport(widget.reportId!);
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadReport(String id) async {
    final repo = ref.read(repoProvider);
    final r = await repo.getReport(id);
    if (r == null || !mounted) return;
    final layout = r.layout;
    final builder = (layout['builder'] as Map?)?.cast<String, dynamic>();
    final table = builder?['table'] as String?;
    final cols = (builder?['columns'] as List?)
            ?.cast<Map>()
            .map((m) => _DraggedColumn.fromJson(m))
            .toList() ??
        const <_DraggedColumn>[];
    final widgetCfg = _WidgetConfig.fromJson(
        (builder?['widget'] as Map?)?.cast<String, dynamic>());
    final viewStr = builder?['view'] as String?;
    final view = switch (viewStr) {
      'widget' => _BuilderView.widgetView,
      'blended' => _BuilderView.blended,
      _ => _BuilderView.table,
    };
    // Preserve any widgets that came in via the canned-report schema
    // (layout.pages[].widgets[]). We don't translate them — they render
    // read-only in a banner and pass through unchanged on save so the
    // PDF/Excel export still has real content.
    final pages = (layout['pages'] as List?)
            ?.whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    setState(() {
      _report = r;
      _title = r.name;
      _selectedTable = table;
      _selectedTableDisplay = cols.isNotEmpty ? cols.first.tableDisplay : null;
      _columns
        ..clear()
        ..addAll(cols);
      _widget = widgetCfg;
      _view = view;
      _carriedPages = pages;
      _lastSavedAt = r.createdAt;
      _dirty = false;
    });
    // Heal any stale virtual columns whose `table` doesn't match the report's
    // current base table. These come from legacy drops (before drop-time
    // re-pathing) — their FK chain is wrong for the report's anchor and the
    // RPC rejects them as "relationship X -> Y (forward) not registered".
    // Re-run BFS from the report's actual base to the virtual's terminal
    // (table, column) and rewrite the path in-place.
    if (table != null) {
      _healStaleVirtuals();
    }
  }

  /// Walks `_columns` and, for any virtual whose `table` != `_selectedTable`,
  /// rebuilds the FK path by BFS so the join-aware RPC can resolve it.
  /// Runs after the relations provider has resolved (which happens
  /// asynchronously) — if it isn't ready yet we re-schedule.
  Future<void> _healStaleVirtuals() async {
    // Make sure the relations registry is loaded.
    await ref.read(_relationsProvider.future);
    if (!mounted || _selectedTable == null) return;
    final base = _selectedTable!;
    final rebuilt = <_DraggedColumn>[];
    final dropped = <String>[];
    var changed = false;
    for (final c in _columns) {
      if (!c.isVirtual || c.table.toLowerCase() == base.toLowerCase()) {
        rebuilt.add(c);
        continue;
      }
      final lastHop = (c.path != null && c.path!.isNotEmpty)
          ? c.path!.last
          : null;
      final terminalTable = lastHop?['to'] ?? c.table;
      final terminalColumn = c.expr ?? c.column;
      final probe = _DraggedColumn(
        table: terminalTable,
        tableDisplay: terminalTable,
        column: terminalColumn,
        dataType: c.dataType,
      );
      final linked = _autoLinkColumn(probe);
      if (linked != null) {
        rebuilt.add(_DraggedColumn(
          table: base,
          tableDisplay: _selectedTableDisplay ?? base,
          column: c.column,
          dataType: c.dataType,
          path: linked.path,
          expr: linked.expr,
          virtualLabel: c.virtualLabel ?? linked.virtualLabel,
        ));
        changed = true;
      } else {
        // No reachable path — drop the column so the preview can render.
        dropped.add(c.virtualLabel ?? c.column);
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {
        _columns
          ..clear()
          ..addAll(rebuilt);
      });
      // Persist the healed layout so subsequent loads are clean.
      _markDirty();
      if (dropped.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Removed ${dropped.length} column(s) with no valid join '
              'path from ${_selectedTableDisplay ?? base}: '
              '${dropped.join(", ")}',
            ),
          ),
        );
      }
    }
  }

  // ── Persistence ──

  void _markDirty() {
    if (!mounted) return;
    final wasLive = _report?.status == ReportStatus.live;
    setState(() => _dirty = true);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _saveNow);
    // If the user edits a previously-published report, demote it back to
    // draft so the Publish button flips from green/checkmark to blue.
    if (wasLive) {
      _revertToPendingIfNeeded();
    }
  }

  Map<String, dynamic> _buildLayout() {
    return {
      // Preserve any widgets carried over from a canned clone so they
      // continue to render in the published report and in PDF/Excel
      // exports. The column-builder edits live alongside under `builder`.
      'pages': _carriedPages,
      'builder': {
        'view': switch (_view) {
          _BuilderView.table => 'table',
          _BuilderView.blended => 'blended',
          _BuilderView.widgetView => 'widget',
        },
        'table': _selectedTable,
        'columns': _columns.map((c) => c.toJson()).toList(),
        'widget': _widget.toJson(),
      },
    };
  }

  Future<void> _saveNow() async {
    final repo = ref.read(repoProvider);
    final layout = _buildLayout();
    setState(() => _saving = true);
    try {
      if (_report == null) {
        // Auto-create the row on first save.
        final tenantId = ref.read(activeTenantProvider);
        if (tenantId == null) return;
        final row = await repo.client
            .from('reports')
            .insert({
              'tenant_id': tenantId,
              'name': _title,
              'description': null,
              'layout': layout,
              'status': ReportStatus.pending.wire,
              'shared_with_tenant': false,
            })
            .select('*')
            .single();
        _report = Report.fromMap({
          ...row,
          'is_canned': false,
          'category': 'custom',
        });
      } else {
        await repo.updateReportLayout(
          _report!.id,
          layout: layout,
          name: _title,
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _lastSavedAt = DateTime.now();
      });
      ref.invalidate(reportsProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  Future<void> _publish() async {
    await _saveNow();
    if (_report == null) return;
    try {
      await ref
          .read(repoProvider)
          .setReportStatus(_report!.id, ReportStatus.live);
      if (!mounted) return;
      setState(() {
        _report = _cloneReport(_report!, status: ReportStatus.live);
      });
      ref.invalidate(reportsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$_title" published.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Publish failed: $e')),
      );
    }
  }

  Future<void> _saveAndClose() async {
    _saveDebounce?.cancel();
    await _saveNow();
    if (!mounted) return;
    context.go('/reports');
  }

  Future<void> _buildNewReport() async {
    // Flush any pending edits to the current report first so nothing is lost.
    _saveDebounce?.cancel();
    if (_dirty) {
      await _saveNow();
      if (!mounted) return;
    }
    setState(() {
      _report = null;
      _title = 'Untitled Report';
      _selectedTable = null;
      _selectedTableDisplay = null;
      _columns.clear();
      _widget = _WidgetConfig();
      _carriedPages = const [];
      _view = _BuilderView.table;
      _dirty = false;
      _lastSavedAt = null;
      _search = '';
      _expanded.clear();
    });
  }

  /// Revert a published report back to draft (pending) once the user edits it
  /// again so the Publish button flips from green back to blue.
  Future<void> _revertToPendingIfNeeded() async {
    final r = _report;
    if (r == null || r.status != ReportStatus.live) return;
    try {
      await ref.read(repoProvider).setReportStatus(r.id, ReportStatus.pending);
      if (!mounted) return;
      setState(() {
        _report = _cloneReport(r, status: ReportStatus.pending);
      });
      ref.invalidate(reportsProvider);
    } catch (_) {
      // Best-effort — UI will still reflect dirty state via the button.
    }
  }

  Future<void> _toggleShare() async {
    if (_report == null) {
      await _saveNow();
      if (_report == null) return;
    }
    final newVal = !_report!.sharedWithTenant;
    try {
      await ref.read(repoProvider).client
          .from('reports')
          .update({'shared_with_tenant': newVal}).eq('id', _report!.id);
      if (!mounted) return;
      setState(() {
        _report = _cloneReport(_report!, sharedWithTenant: newVal);
      });
      ref.invalidate(reportsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(newVal
                ? 'Shared with your tenant.'
                : 'Sharing turned off — only you can see this report now.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }

  Report _cloneReport(Report r, {ReportStatus? status, bool? sharedWithTenant}) {
    return Report(
      id: r.id,
      tenantId: r.tenantId,
      name: r.name,
      isCanned: r.isCanned,
      category: r.category,
      description: r.description,
      layout: r.layout,
      status: status ?? r.status,
      createdAt: r.createdAt,
      archivedAt: r.archivedAt,
      createdBy: r.createdBy,
      createdByName: r.createdByName,
      sharedWithTenant: sharedWithTenant ?? r.sharedWithTenant,
    );
  }

  Future<void> _exportCsv(List<Map<String, dynamic>> rows) async {
    final headers = _columns.map((c) => c.column).toList();
    final buf = StringBuffer();
    buf.writeln(headers.map(_csvCell).join(','));
    for (final r in rows) {
      buf.writeln(headers.map((h) => _csvCell(r[h])).join(','));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              'CSV copied to clipboard — ${rows.length} rows × ${headers.length} cols.')),
    );
  }

  String _csvCell(dynamic v) {
    if (v == null) return '';
    final s = v is String ? v : v.toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  // ── Column ops ──

  bool _isMismatchedTable(_DraggedColumn c) {
    return _selectedTable != null && _selectedTable != c.table;
  }

  void _addColumn(_DraggedColumn c) {
    // If the dropped column belongs to a *different* table than the report's
    // current base, attempt to auto-link it as a virtual joined column by
    // walking the registered relationship graph (BFS). Only fall back to the
    // "Different source table" dialog when no path can be found.
    if (_isMismatchedTable(c)) {
      if (c.isVirtual) {
        // Virtual columns carry a path built from *their* source table. When
        // dropped onto a report based on a different table, we must re-derive
        // the path from the report's base. The original virtual's terminal
        // table = the last hop's `to`; the column it really points at is the
        // virtual's `expr`. Re-run BFS to that (table, column).
        final lastHop = (c.path != null && c.path!.isNotEmpty)
            ? c.path!.last
            : null;
        final terminalTable = lastHop?['to'] ?? c.table;
        final terminalColumn = c.expr ?? c.column;
        final probe = _DraggedColumn(
          table: terminalTable,
          tableDisplay: terminalTable,
          column: terminalColumn,
          dataType: c.dataType,
        );
        final linked = _autoLinkColumn(probe);
        if (linked != null) {
          c = linked;
        } else {
          _showMismatchDialog(c);
          return;
        }
      } else {
        final linked = _autoLinkColumn(c);
        if (linked != null) {
          c = linked;
        } else {
          _showMismatchDialog(c);
          return;
        }
      }
    }
    if (_columns.any((x) => x.column == c.column && x.table == c.table)) {
      return; // already present
    }
    setState(() {
      _selectedTable ??= c.table;
      _selectedTableDisplay ??= c.tableDisplay;
      _columns.add(c);
      // Seed widget defaults the first time we have at least two cols.
      _widget.xColumn ??= _firstTextColumn() ?? c.column;
      _widget.yColumn ??= _firstNumericColumn();
    });
    _markDirty();
  }

  /// BFS through `rds_relationships` from `_selectedTable` to `c.table`.
  /// On success returns a virtual `_DraggedColumn` that the join-aware RPC
  /// can resolve via LEFT JOINs. On failure returns null and the caller
  /// falls back to the mismatch dialog.
  _DraggedColumn? _autoLinkColumn(_DraggedColumn c) {
    final base = _selectedTable;
    if (base == null || base == c.table) return null;

    final relsAsync = ref.read(_relationsProvider);
    final relsMap = relsAsync.asData?.value;
    if (relsMap == null) return null;

    final rels = (relsMap['relationships'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (rels.isEmpty) return null;

    // Build adjacency in *both* directions.
    // Forward (many→one): A.fk → B.id  joined as  JOIN B ON B.id = A.fk
    // Reverse (one→many): B → A via fk joined as  JOIN A ON A.fk = B.id
    // Each adjacency record carries a `dir` field consumed by the join RPC.
    final adj = <String, List<Map<String, String>>>{};
    for (final r in rels) {
      final from = (r['from_table'] as String? ?? '').toLowerCase();
      final to = (r['to_table'] as String? ?? '').toLowerCase();
      final fk = r['from_column'] as String? ?? '';
      final toCol = r['to_column'] as String? ?? 'id';
      final role = (r['role_label'] as String?) ?? '';
      if (from.isEmpty || to.isEmpty || fk.isEmpty) continue;
      // Forward edge: from → to
      adj.putIfAbsent(from, () => []).add({
        'fk': fk,
        'to': to,
        'to_column': toCol,
        'role': role,
        'dir': 'forward',
      });
      // Reverse edge: to → from (1:many)
      adj.putIfAbsent(to, () => []).add({
        'fk': fk,
        'to': from,
        'to_column': toCol,
        'role': role,
        'dir': 'reverse',
      });
    }

    final visited = <String>{base.toLowerCase()};
    final queue = <_BfsNode>[_BfsNode(base.toLowerCase(), const [])];
    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      final edges = adj[node.table] ?? const [];
      for (final e in edges) {
        final next = e['to']!;
        if (visited.contains(next)) continue;
        final nextPath = [
          ...node.path,
          {
            'fk': e['fk']!,
            'to': next,
            'to_column': e['to_column']!,
            'dir': e['dir']!,
          },
        ];
        if (next == c.table.toLowerCase()) {
          final roleSegments = <String>[];
          for (var i = 0; i < nextPath.length; i++) {
            final hopFrom = i == 0 ? base.toLowerCase() : nextPath[i - 1]['to']!;
            final hopFk = nextPath[i]['fk']!;
            final hopTo = nextPath[i]['to']!;
            final hopDir = nextPath[i]['dir']!;
            final origin = (adj[hopFrom] ?? const [])
                .firstWhere(
                    (r) =>
                        r['fk'] == hopFk &&
                        r['to'] == hopTo &&
                        r['dir'] == hopDir,
                    orElse: () => const {});
            final role = origin['role'] ?? '';
            if (role.isNotEmpty) roleSegments.add(role);
          }
          final hopLabel = roleSegments.isNotEmpty
              ? roleSegments.join(' ')
              : c.tableDisplay;
          final colLabel = _titleCase(c.column);
          final label = '$hopLabel $colLabel';
          final alias = _slugifyLabel(label);
          return _DraggedColumn(
            table: base,
            tableDisplay: _selectedTableDisplay ?? base,
            column: alias,
            dataType: c.dataType,
            path: nextPath,
            expr: c.column,
            virtualLabel: label,
          );
        }
        visited.add(next);
        queue.add(_BfsNode(next, nextPath));
      }
    }
    return null;
  }

  String _titleCase(String s) => s
      .split('_')
      .where((p) => p.isNotEmpty)
      .map((p) => p[0].toUpperCase() + p.substring(1))
      .join(' ');

  String _slugifyLabel(String s) {
    var t = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    while (t.startsWith('_')) {
      t = t.substring(1);
    }
    while (t.endsWith('_')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  /// Returns the auto-generated virtual columns surfaced under `baseBare` in
  /// the catalog browser (one per registered relationship with a display
  /// expression on the target table).
  List<_DraggedColumn> _virtualColumnsFor(String baseBare, String baseDisplay) {
    final relsAsync = ref.read(_relationsProvider);
    final relsMap = relsAsync.asData?.value;
    if (relsMap == null) return const [];

    final rels = (relsMap['relationships'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final displays = (relsMap['displays'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (rels.isEmpty || displays.isEmpty) return const [];

    final dispByTable = <String, Map<String, dynamic>>{
      for (final d in displays) (d['table_name'] as String).toLowerCase(): d,
    };

    final out = <_DraggedColumn>[];
    for (final r in rels) {
      if ((r['from_table'] as String? ?? '').toLowerCase() !=
          baseBare.toLowerCase()) {
        continue;
      }
      final to = (r['to_table'] as String? ?? '').toLowerCase();
      final fk = r['from_column'] as String? ?? '';
      final toCol = r['to_column'] as String? ?? 'id';
      final role = (r['role_label'] as String?) ?? '';
      final disp = dispByTable[to];
      if (disp == null) continue;
      final expr = disp['display_expr'] as String? ?? '';
      final dispLabel = disp['display_label'] as String? ?? 'Name';
      if (expr.isEmpty) continue;
      final hopLabel = role.isNotEmpty ? role : _titleCase(to);
      final label = '$hopLabel $dispLabel';
      final alias = _slugifyLabel(label);
      out.add(_DraggedColumn(
        table: baseBare,
        tableDisplay: baseDisplay,
        column: alias,
        dataType: 'text',
        path: [
          {'fk': fk, 'to': to, 'to_column': toCol},
        ],
        expr: expr,
        virtualLabel: label,
      ));
    }
    out.sort((a, b) => a.label.compareTo(b.label));
    return out;
  }

  Widget _virtualColumnNode(_DraggedColumn v) {
    final already = _columns.any(
        (x) => x.table == v.table && x.column == v.column);
    final tile = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => already ? _removeColumn(v) : _addColumn(v),
        child: Container(
          margin: const EdgeInsets.only(left: 28, right: 4, top: 1, bottom: 1),
          padding: const EdgeInsets.symmetric(
              horizontal: OpticsSpacing.sm, vertical: 4),
          decoration: BoxDecoration(
            color: already
                ? OpticsColors.accentCyan.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(children: [
            Icon(Icons.link,
                size: 12,
                color: already
                    ? OpticsColors.accentCyan
                    : OpticsColors.accentViolet),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                v.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: already
                      ? OpticsColors.accentCyan
                      : OpticsColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (already)
              const Icon(Icons.check,
                  size: 12, color: OpticsColors.accentCyan),
          ]),
        ),
      ),
    );
    return Draggable<_DraggedColumn>(
      data: v,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: OpticsColors.surface,
            border: Border.all(color: OpticsColors.accentViolet, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(v.label,
              style: const TextStyle(
                  fontSize: 12, color: OpticsColors.textPrimary)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }

  void _removeColumn(_DraggedColumn c) {
    setState(() {
      _columns.removeWhere((x) => x.column == c.column && x.table == c.table);
      if (_columns.isEmpty) {
        _selectedTable = null;
        _selectedTableDisplay = null;
        _widget = _WidgetConfig();
      } else {
        if (_widget.xColumn == c.column) {
          _widget.xColumn = _firstTextColumn() ?? _columns.first.column;
        }
        if (_widget.yColumn == c.column) {
          _widget.yColumn = _firstNumericColumn();
        }
      }
    });
    _markDirty();
  }

  String? _firstTextColumn() {
    for (final c in _columns) {
      if (!_isNumericType(c.dataType)) return c.column;
    }
    return null;
  }

  String? _firstNumericColumn() {
    for (final c in _columns) {
      if (_isNumericType(c.dataType)) return c.column;
    }
    return null;
  }

  bool _isNumericType(String t) {
    return t == 'integer' ||
        t == 'bigint' ||
        t == 'smallint' ||
        t == 'numeric' ||
        t == 'double precision' ||
        t == 'real';
  }

  Future<void> _showMismatchDialog(_DraggedColumn c) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: const Text('Different source table'),
        content: Text(
          'Columns from "${c.tableDisplay}" can\'t be combined with columns '
          'from "${_selectedTableDisplay ?? _selectedTable}" in the same table. '
          '\n\nClear the current table and start over with "${c.tableDisplay}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (res == true && mounted) {
      setState(() {
        _columns
          ..clear()
          ..add(c);
        _selectedTable = c.table;
        _selectedTableDisplay = c.tableDisplay;
        _widget = _WidgetConfig(xColumn: c.column);
      });
      _markDirty();
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final sourceAsync = ref.watch(_activeRestSourceProvider);
    return Padding(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(sourceAsync),
          const SizedBox(height: OpticsSpacing.md),
          Expanded(
            child: sourceAsync.when(
              data: (src) {
                if (src == null) return _noSource();
                return LayoutBuilder(builder: (context, constraints) {
                  // Clamp the right panel against the available width so the
                  // canvas never collapses below a reasonable minimum.
                  // Right-side live preview only renders in Blended view.
                  final showRight = _view == _BuilderView.blended;
                  // Reserved space: catalog (320) + 2 gutters (lg) + min canvas (320).
                  final maxRightForLayout = (constraints.maxWidth -
                          320 -
                          (OpticsSpacing.lg * 2) -
                          320)
                      .clamp(_rightPanelMin, _rightPanelMax);
                  final effectiveRightWidth = showRight
                      ? _rightPanelWidth
                          .clamp(_rightPanelMin, maxRightForLayout)
                          .toDouble()
                      : 0.0;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 320, child: _buildCatalogPanel()),
                      const SizedBox(width: OpticsSpacing.lg),
                      // Tabs live inside the canvas column so they only
                      // span the middle (+ optional preview) area, not the
                      // catalog. The active tab visually "opens into" the
                      // canvas surface below.
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _viewTabStrip(),
                            Expanded(child: _buildCanvas(src)),
                          ],
                        ),
                      ),
                      // Right-side live widget preview — only meaningful in
                      // Blended view (Widget view already shows the chart full-size).
                      if (showRight) ...[
                        _buildPanelResizer(maxRightForLayout),
                        Container(
                          width: effectiveRightWidth,
                          decoration: const BoxDecoration(
                            // Lift panel above canvas so the shadow has
                            // visible contrast against the darker page bg.
                            color: OpticsColors.surfaceElevated,
                            boxShadow: [
                              // ERP-style depth shadow rotated to cast
                              // leftward into the canvas. Boosted vs. raw
                              // ERP recipe so it's visible against
                              // Optics' near-pure-black canvas.
                              BoxShadow(
                                color: Color(0xFF000000),
                                offset: Offset(-14, 0),
                                blurRadius: 18,
                                spreadRadius: -4,
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Spacer to match the tab strip height so the
                              // preview panel top aligns with the canvas top.
                              const SizedBox(height: 36),
                              // Top: live preview (~half-height).
                              Expanded(child: _buildLivePreviewPanel(src)),
                              const SizedBox(height: OpticsSpacing.md),
                              // Bottom: widget controls (~half-height).
                              Expanded(child: _buildWidgetControlsPanel()),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                });
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, st) => Center(
                child: Text('Failed to load data sources: $e',
                    style: const TextStyle(color: OpticsColors.danger)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ──
  Widget _buildHeader(AsyncValue<DataSource?> sourceAsync) {
    final src = sourceAsync.asData?.value;
    final shared = _report?.sharedWithTenant ?? false;
    return Row(
      children: [
        const Text('Report Builder', style: OpticsTextStyles.headingXl),
        const SizedBox(width: 12),
        if (src != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: OpticsColors.accentCyan.withValues(alpha: 0.10),
              border: Border.all(
                  color: OpticsColors.accentCyan.withValues(alpha: 0.40)),
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.cable, size: 12, color: OpticsColors.accentCyan),
              const SizedBox(width: 6),
              Text(src.name,
                  style: const TextStyle(
                      fontSize: 12,
                      color: OpticsColors.accentCyan,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ],
        const SizedBox(width: 16),
        // Inline editable title.
        Flexible(
          child: SizedBox(
            width: 320,
            child: TextFormField(
              key: ValueKey(_report?.id ?? 'new'),
              initialValue: _title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: OpticsColors.textPrimary,
              ),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Untitled Report',
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              onChanged: (v) {
                _title = v.trim().isEmpty ? 'Untitled Report' : v.trim();
                _markDirty();
              },
            ),
          ),
        ),
        const SizedBox(width: 12),
        _saveStatusChip(),
        const Spacer(),
        IconButton(
          tooltip: shared
              ? 'Shared with tenant — click to unshare'
              : 'Share with tenant',
          icon: Icon(
            shared ? Icons.group : Icons.group_outlined,
            size: 18,
            color: shared ? OpticsColors.accentGreen : OpticsColors.textSecondary,
          ),
          onPressed: _columns.isEmpty ? null : _toggleShare,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.save_outlined, size: 14),
          label: const Text('Save & Close'),
          onPressed: _columns.isEmpty ? null : _saveAndClose,
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.note_add_outlined, size: 14),
          label: const Text('Build New Report'),
          onPressed: _columns.isEmpty ? null : _buildNewReport,
        ),
        const SizedBox(width: 8),
        Builder(builder: (context) {
          final published = _report?.status == ReportStatus.live && !_dirty;
          final baseStyle = Theme.of(context).elevatedButtonTheme.style;
          final style = published
              ? (baseStyle ?? const ButtonStyle()).copyWith(
                  backgroundColor:
                      WidgetStatePropertyAll(OpticsColors.accentGreen),
                  foregroundColor:
                      const WidgetStatePropertyAll(Colors.white),
                )
              : baseStyle;
          return ElevatedButton.icon(
            style: style,
            icon: Icon(
              published ? Icons.check_circle : Icons.publish,
              size: 14,
            ),
            label: Text(published ? 'Published' : 'Publish'),
            onPressed: _columns.isEmpty ? null : _publish,
          );
        }),
      ],
    );
  }

  Widget _saveStatusChip() {
    String text;
    Color color;
    IconData icon;
    if (_saving) {
      text = 'Saving…';
      color = OpticsColors.accentCyan;
      icon = Icons.sync;
    } else if (_dirty) {
      text = 'Unsaved';
      color = OpticsColors.accentOrange;
      icon = Icons.edit;
    } else if (_lastSavedAt != null) {
      text = 'Saved';
      color = OpticsColors.accentGreen;
      icon = Icons.check_circle_outline;
    } else {
      text = 'Draft';
      color = OpticsColors.textMuted;
      icon = Icons.note_outlined;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: 0.4)),
      ]),
    );
  }

  // ── Folder-style view tabs (Table | Blended | Widget) ──
  // Classic file-folder strip that sits flush on top of the canvas
  // container. The active tab uses the same surface color as the canvas
  // and hides its bottom border so the two visually merge into one body.
  Widget _viewTabStrip() {
    return SizedBox(
      height: 36,
      child: Stack(children: [
        // Bottom border line that runs the full strip width; the active
        // tab punches through it because its own bottom edge sits 1px lower.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(height: 1, color: OpticsColors.border),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _folderTab(
                Icons.table_rows_outlined, 'Table View', _BuilderView.table),
            const SizedBox(width: 2),
            _folderTab(Icons.view_column_outlined, 'Blended View',
                _BuilderView.blended),
            const SizedBox(width: 2),
            _folderTab(Icons.bar_chart_outlined, 'Widget View',
                _BuilderView.widgetView),
          ],
        ),
      ]),
    );
  }

  Widget _folderTab(IconData icon, String label, _BuilderView v) {
    final active = _view == v;
    return InkWell(
      onTap: () {
        setState(() => _view = v);
        _markDirty();
      },
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(OpticsRadii.sm),
        topRight: Radius.circular(OpticsRadii.sm),
      ),
      child: Container(
        // Active tab is taller and overlaps the strip's bottom border line
        // by 1px so its bottom edge "merges" into the canvas below.
        height: active ? 33 : 28,
        margin: EdgeInsets.only(bottom: active ? 0 : 2),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active
              ? OpticsColors.surface
              : OpticsColors.surfaceElevated,
          border: Border(
            top: BorderSide(color: OpticsColors.border),
            left: BorderSide(color: OpticsColors.border),
            right: BorderSide(color: OpticsColors.border),
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(OpticsRadii.sm),
            topRight: Radius.circular(OpticsRadii.sm),
          ),
        ),
        child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 14,
                color: active
                    ? OpticsColors.accentCyan
                    : OpticsColors.textSecondary),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: 0.3,
                  color: active
                      ? OpticsColors.textPrimary
                      : OpticsColors.textSecondary,
                )),
          ]),
        ),
      ),
    );
  }

  Widget _noSource() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: OpticsCard(
          title: 'No data source connected',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connect a Bryzos REST data source under Settings → Data Sources to start building reports here.',
                style: OpticsTextStyles.body
                    .copyWith(color: OpticsColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Left panel: schema catalog ──
  Widget _buildCatalogPanel() {
    final catalogAsync = ref.watch(_catalogProvider);
    return OpticsCard(
      expandChild: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Text('CATALOG',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: OpticsColors.textSecondary)),
            const SizedBox(width: 8),
            catalogAsync.maybeWhen(
              data: (rows) => Text('${rows.length}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: OpticsColors.accentCyan)),
              orElse: () => const SizedBox.shrink(),
            ),
          ]),
          const SizedBox(height: OpticsSpacing.sm),
          TextField(
            decoration: const InputDecoration(
              hintText: 'Search tables or columns…',
              prefixIcon: Icon(Icons.search, size: 14),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) => setState(() => _search = v.toLowerCase()),
          ),
          const SizedBox(height: OpticsSpacing.sm),
          const Divider(height: 1, color: OpticsColors.border),
          Expanded(
            child: catalogAsync.when(
              data: (rows) => _catalogList(rows),
              loading: () =>
                  const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, st) => Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Could not load catalog: $e',
                    style: const TextStyle(color: OpticsColors.danger)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _catalogList(List<Map<String, dynamic>> tables) {
    final q = _search;
    // Filter: a table is shown if its name matches OR any of its columns match.
    final filtered = <Map<String, dynamic>>[];
    for (final t in tables) {
      final cols = (t['columns'] as List).cast<Map<String, dynamic>>();
      if (q.isEmpty) {
        filtered.add(t);
        continue;
      }
      final tName = (t['table_name'] as String).toLowerCase();
      final tDisp = (t['display_name'] as String).toLowerCase();
      final tMatch = tName.contains(q) || tDisp.contains(q);
      final matchingCols = cols
          .where((c) => (c['name'] as String).toLowerCase().contains(q))
          .toList();
      if (tMatch || matchingCols.isNotEmpty) {
        filtered.add({
          ...t,
          if (!tMatch && matchingCols.isNotEmpty) 'columns': matchingCols,
        });
        // Auto-expand when matching by column.
        if (!tMatch && matchingCols.isNotEmpty) {
          _expanded.add(t['table_name'] as String);
        }
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: filtered.length,
      itemBuilder: (_, i) => _tableNode(filtered[i]),
    );
  }

  Widget _tableNode(Map<String, dynamic> t) {
    final tableName = t['table_name'] as String;
    final bare = tableName.startsWith('rds_') ? tableName.substring(4) : tableName;
    final display = t['display_name'] as String;
    final cols = (t['columns'] as List).cast<Map<String, dynamic>>();
    final isExpanded = _expanded.contains(tableName) || _search.isNotEmpty;
    final isActiveTable = _selectedTable == bare;
    final virtuals = _virtualColumnsFor(bare, display);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expanded.remove(tableName);
              } else {
                _expanded.add(tableName);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: OpticsSpacing.sm, vertical: 5),
            child: Row(children: [
              Icon(
                isExpanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: OpticsColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Icon(Icons.table_chart_outlined,
                  size: 14,
                  color: isActiveTable
                      ? OpticsColors.accentCyan
                      : OpticsColors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  display,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        isActiveTable ? FontWeight.w700 : FontWeight.w500,
                    color: isActiveTable
                        ? OpticsColors.accentCyan
                        : OpticsColors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${cols.length}',
                  style: const TextStyle(
                      fontSize: 12, color: OpticsColors.textMuted)),
            ]),
          ),
        ),
        if (isExpanded) ...[
          if (virtuals.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(left: 32, top: 6, bottom: 2),
              child: Text(
                'LINKED COLUMNS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: OpticsColors.textMuted,
                ),
              ),
            ),
            ...virtuals.map(_virtualColumnNode),
            const Padding(
              padding: EdgeInsets.only(left: 32, top: 6, bottom: 2),
              child: Text(
                'FIELDS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: OpticsColors.textMuted,
                ),
              ),
            ),
          ],
          ...cols.map((c) => _columnNode(bare, display, c)),
        ],
      ],
    );
  }

  Widget _columnNode(
      String bareTable, String tableDisplay, Map<String, dynamic> c) {
    final name = c['name'] as String;
    final dataType = (c['data_type'] as String?) ?? 'text';
    final already = _columns.any(
        (x) => x.table == bareTable && x.column == name);
    final dragData = _DraggedColumn(
      table: bareTable,
      tableDisplay: tableDisplay,
      column: name,
      dataType: dataType,
    );

    final tile = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () =>
            already ? _removeColumn(dragData) : _addColumn(dragData),
        child: Container(
          margin: const EdgeInsets.only(left: 28, right: 4, top: 1, bottom: 1),
          padding: const EdgeInsets.symmetric(
              horizontal: OpticsSpacing.sm, vertical: 4),
          decoration: BoxDecoration(
            color: already
                ? OpticsColors.accentCyan.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: already
                  ? OpticsColors.accentCyan.withValues(alpha: 0.30)
                  : Colors.transparent,
            ),
          ),
          child: Row(children: [
            Icon(Icons.drag_indicator,
                size: 12, color: OpticsColors.textMuted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(name,
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'Menlo',
                      color: already
                          ? OpticsColors.accentCyan
                          : OpticsColors.textPrimary,
                      fontWeight:
                          already ? FontWeight.w600 : FontWeight.normal),
                  overflow: TextOverflow.ellipsis),
            ),
            Text(_shortType(dataType),
                style: const TextStyle(
                    fontSize: 12, color: OpticsColors.textMuted)),
            const SizedBox(width: 6),
            // Subtle indicator (check) when column is on the canvas.
            SizedBox(
              width: 14,
              height: 14,
              child: already
                  ? Icon(Icons.check,
                      size: 14, color: OpticsColors.accentCyan)
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
      ),
    );

    return Draggable<_DraggedColumn>(
      data: dragData,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: OpticsColors.accentCyan.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
            boxShadow: const [
              BoxShadow(blurRadius: 12, color: Colors.black54),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.view_column,
                size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Text(name,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }

  String _shortType(String t) {
    switch (t) {
      case 'character varying':
      case 'text':
        return 'text';
      case 'timestamp with time zone':
      case 'timestamp without time zone':
        return 'datetime';
      case 'double precision':
      case 'numeric':
      case 'integer':
      case 'bigint':
      case 'smallint':
        return 'number';
      case 'boolean':
        return 'bool';
      case 'jsonb':
      case 'json':
        return 'json';
      case 'uuid':
        return 'uuid';
      case 'date':
        return 'date';
      default:
        return t;
    }
  }

  // ── Canvas ──
  Widget _buildCanvas(DataSource src) {
    // Widget view = full chart builder. Table & Blended both show the data
    // table canvas (Blended additionally renders a live preview on the right).
    final Widget canvas;
    if (_view == _BuilderView.widgetView) {
      canvas = _widgetCanvas(src);
    } else {
      canvas = DragTarget<_DraggedColumn>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (d) => _addColumn(d.data),
        builder: (ctx, candidate, rejected) {
          final hovered = candidate.isNotEmpty;
          if (_columns.isEmpty) {
            return _emptyCanvas(hovered: hovered);
          }
          return _dataTableCanvas(src, hovered: hovered);
        },
      );
    }
    // If this report was cloned from a canned template, surface the
    // carried-over widgets above the column builder so the user can see
    // what they inherited (and the canvas isn't deceptively blank).
    final Widget effective = _carriedPages.isNotEmpty
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _carriedWidgetsBanner(),
              const SizedBox(height: 12),
              Expanded(child: canvas),
            ],
          )
        : canvas;
    // Only the canvas itself zooms/pans — catalog, view tabs, right preview
    // panel, and toolbar buttons stay at their default position.
    return CanvasZoom(child: effective);
  }

  /// Read-only summary of widgets inherited from a canned-report clone.
  /// Renders as a banner with title chips so the user understands the
  /// cloned report isn't empty and these widgets will be exported in
  /// PDF/Excel.  Edits to bindings are done via the column builder below.
  Widget _carriedWidgetsBanner() {
    final widgets = <Map<String, dynamic>>[];
    for (final p in _carriedPages) {
      final ws = (p['widgets'] as List?)
              ?.whereType<Map>()
              .map((m) => m.cast<String, dynamic>()) ??
          const <Map<String, dynamic>>[];
      widgets.addAll(ws);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(
          color: OpticsColors.accentCyan.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined,
                  size: 16, color: OpticsColors.accentCyan),
              const SizedBox(width: 8),
              Text(
                'CLONED FROM CANNED REPORT — ${widgets.length} widget${widgets.length == 1 ? '' : 's'} preserved',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: OpticsColors.accentCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'These widgets render in the published report and in PDF / Excel exports. '
            'Add table-based columns below to extend the report — the carried widgets will be preserved.',
            style: TextStyle(fontSize: 12, color: OpticsColors.textMuted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final w in widgets)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: OpticsColors.canvas,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: OpticsColors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_iconForWidgetType(w['type'] as String?),
                          size: 13, color: OpticsColors.textMuted),
                      const SizedBox(width: 6),
                      Text(
                        (w['title'] as String?)?.trim().isNotEmpty == true
                            ? w['title'] as String
                            : (w['type'] as String? ?? 'widget'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: OpticsColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _iconForWidgetType(String? type) {
    switch (type) {
      case 'kpi':
        return Icons.numbers_outlined;
      case 'line':
        return Icons.show_chart;
      case 'bar':
        return Icons.bar_chart_outlined;
      case 'pie':
      case 'donut':
        return Icons.pie_chart_outline;
      case 'gauge':
        return Icons.speed_outlined;
      case 'table':
        return Icons.table_chart_outlined;
      case 'map':
        return Icons.public_outlined;
      case 'text':
      case 'markdown':
        return Icons.notes_outlined;
      default:
        return Icons.widgets_outlined;
    }
  }

  Widget _emptyCanvas({required bool hovered}) {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(
          color: hovered
              ? OpticsColors.accentCyan
              : OpticsColors.border,
          width: hovered ? 1.5 : 1,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_view_outlined,
                size: 48,
                color: hovered
                    ? OpticsColors.accentCyan
                    : OpticsColors.textMuted),
            const SizedBox(height: 16),
            Text(
              hovered ? 'Drop column to start your report'
                     : 'Drag a column from the catalog to begin',
              style: TextStyle(
                fontSize: 14,
                color: hovered
                    ? OpticsColors.accentCyan
                    : OpticsColors.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Each column you add becomes a column in this growing table.',
              style: TextStyle(fontSize: 12, color: OpticsColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataTableCanvas(DataSource src, {required bool hovered}) {
    final args = _PreviewArgs(
      dataSourceId: src.id,
      table: _selectedTable!,
      columns: _columns.map((c) => c.toRpcColumn()).toList(),
      limit: _previewLimit,
    );
    final dataAsync = ref.watch(_previewProvider(args));

    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(
          color:
              hovered ? OpticsColors.accentCyan : OpticsColors.border,
          width: hovered ? 1.5 : 1,
        ),
      ),
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _canvasToolbar(dataAsync),
          const SizedBox(height: OpticsSpacing.sm),
          Expanded(
            child: dataAsync.when(
              data: (rows) => _excelStyleTable(rows),
              loading: () => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, st) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load rows: $e',
                      style: const TextStyle(color: OpticsColors.danger),
                      textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _canvasToolbar(AsyncValue<List<Map<String, dynamic>>> dataAsync) {
    final rowCount = dataAsync.asData?.value.length;
    return Row(children: [
      Icon(Icons.table_view, size: 14, color: OpticsColors.accentCyan),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          _selectedTableDisplay ?? _selectedTable ?? '—',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: OpticsColors.textPrimary),
        ),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: OpticsColors.surfaceElevated,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${_columns.length} ${_columns.length == 1 ? "column" : "columns"} · ${rowCount ?? "…"} rows',
          style: const TextStyle(
              fontSize: 12, color: OpticsColors.textSecondary),
        ),
      ),
      const Spacer(),
      DropdownButton<int?>(
        value: _previewLimit,
        isDense: true,
        underline: const SizedBox.shrink(),
        dropdownColor: OpticsColors.surfaceElevated,
        style: const TextStyle(fontSize: 12, color: OpticsColors.textPrimary),
        items: <DropdownMenuItem<int?>>[
          for (final v in const [50, 100, 250, 500, 1000])
            DropdownMenuItem<int?>(
              value: v,
              child: Text('$v rows',
                  style: const TextStyle(fontSize: 12)),
            ),
          const DropdownMenuItem<int?>(
            value: null,
            child: Text('All rows',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
        onChanged: (v) => setState(() => _previewLimit = v),
      ),
      const SizedBox(width: 8),
      IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 16),
        onPressed: () => ref.invalidate(_previewProvider),
      ),
      IconButton(
        tooltip: 'Export CSV',
        icon: const Icon(Icons.download, size: 16),
        onPressed: dataAsync.asData?.value.isEmpty ?? true
            ? null
            : () => _exportCsv(dataAsync.asData!.value),
      ),
      IconButton(
        tooltip: 'Clear all columns',
        icon: const Icon(Icons.layers_clear, size: 16),
        onPressed: () {
          setState(() {
            _columns.clear();
            _selectedTable = null;
            _selectedTableDisplay = null;
            _widget = _WidgetConfig();
          });
          _markDirty();
        },
      ),
    ]);
  }

  Widget _excelStyleTable(List<Map<String, dynamic>> rows) {
    // The first data column (if any) is frozen alongside the row-# column.
    // Frozen pane scrolls vertically with the right pane (shared outer
    // SingleChildScrollView) but never scrolls horizontally.
    return ClipRRect(
      borderRadius: BorderRadius.circular(OpticsRadii.sm),
      child: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Frozen pane: row-# + first data column ─────────────
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _frozenHeaderRow(),
                  ...List<Widget>.generate(
                      rows.length, (i) => _frozenBodyRow(rows[i], i)),
                ],
              ),
              // ── Scrollable pane: remaining columns + add gutter ────
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _scrollableHeaderRow(),
                      ...List<Widget>.generate(rows.length,
                          (i) => _scrollableBodyRow(rows[i], i)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const double _colWidth = 180;
  static const double _rowHeight = 28;

  // ── Frozen pane (left) ────────────────────────────────────────────
  Widget _frozenHeaderRow() {
    return Container(
      decoration: const BoxDecoration(
        color: OpticsColors.surfaceElevated,
        border: Border(
          bottom: BorderSide(color: OpticsColors.borderBright),
          right: BorderSide(color: OpticsColors.borderBright, width: 1),
        ),
      ),
      child: Row(children: [
        _rowNumberHeaderCell(),
        if (_columns.isNotEmpty) _headerCell(_columns[0], 0),
      ]),
    );
  }

  Widget _frozenBodyRow(Map<String, dynamic> r, int index) {
    final isAlt = index.isOdd;
    return Container(
      decoration: BoxDecoration(
        color: isAlt
            ? OpticsColors.surfaceElevated.withValues(alpha: 0.35)
            : Colors.transparent,
        border: const Border(
          bottom: BorderSide(color: OpticsColors.border, width: 0.5),
          right: BorderSide(color: OpticsColors.borderBright, width: 1),
        ),
      ),
      child: Row(children: [
        _rowNumberBodyCell(index),
        if (_columns.isNotEmpty) _bodyDataCell(r, _columns[0]),
      ]),
    );
  }

  // ── Scrollable pane (right) ──────────────────────────────────────
  Widget _scrollableHeaderRow() {
    return Container(
      decoration: const BoxDecoration(
        color: OpticsColors.surfaceElevated,
        border: Border(
          bottom: BorderSide(color: OpticsColors.borderBright),
        ),
      ),
      child: Row(children: [
        for (int i = 1; i < _columns.length; i++) _headerCell(_columns[i], i),
        _addColumnGutter(),
      ]),
    );
  }

  Widget _scrollableBodyRow(Map<String, dynamic> r, int index) {
    final isAlt = index.isOdd;
    return Container(
      decoration: BoxDecoration(
        color: isAlt
            ? OpticsColors.surfaceElevated.withValues(alpha: 0.35)
            : Colors.transparent,
        border: const Border(
          bottom: BorderSide(color: OpticsColors.border, width: 0.5),
        ),
      ),
      child: Row(children: [
        for (int i = 1; i < _columns.length; i++) _bodyDataCell(r, _columns[i]),
        // Trailing add-column gutter so body width matches the header.
        const SizedBox(width: 120, height: _rowHeight),
      ]),
    );
  }

  // ── Shared cell builders ─────────────────────────────────────────
  Widget _rowNumberHeaderCell() {
    return Container(
      width: 36,
      height: _rowHeight,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: OpticsColors.border)),
      ),
      child: const Text('#',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: OpticsColors.textMuted)),
    );
  }

  Widget _rowNumberBodyCell(int index) {
    return Container(
      width: 36,
      height: _rowHeight,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        border:
            Border(right: BorderSide(color: OpticsColors.border, width: 0.5)),
      ),
      child: Text('${index + 1}',
          style: const TextStyle(fontSize: 12, color: OpticsColors.textMuted)),
    );
  }

  Widget _bodyDataCell(Map<String, dynamic> r, _DraggedColumn c) {
    return SizedBox(
      width: _colWidth,
      height: _rowHeight,
      child: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          border:
              Border(right: BorderSide(color: OpticsColors.border, width: 0.5)),
        ),
        child: Text(
          _formatCell(r[c.column]),
          style: const TextStyle(
              fontSize: 12,
              fontFamily: 'Menlo',
              color: OpticsColors.textPrimary),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _addColumnGutter() {
    return DragTarget<_DraggedColumn>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _addColumn(d.data),
      builder: (ctx, candidate, rejected) {
        final hovered = candidate.isNotEmpty;
        return Container(
          width: 120,
          height: _rowHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovered
                ? OpticsColors.accentCyan.withValues(alpha: 0.15)
                : Colors.transparent,
            border: const Border(
              left: BorderSide(color: OpticsColors.border),
            ),
          ),
          child: Text(
            hovered ? 'Drop here' : '+ Add column',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: hovered
                  ? OpticsColors.accentCyan
                  : OpticsColors.textMuted,
            ),
          ),
        );
      },
    );
  }

  Widget _headerCell(_DraggedColumn c, int index) {
    // Body of the cell (drag handle + name + remove).
    Widget cellBody({bool ghost = false, bool dropBefore = false, bool dropAfter = false}) {
      return Container(
        width: _colWidth,
        height: _rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: ghost
              ? OpticsColors.accentCyan.withValues(alpha: 0.10)
              : null,
          border: Border(
            right: const BorderSide(color: OpticsColors.border),
            left: dropBefore
                ? const BorderSide(color: OpticsColors.accentCyan, width: 2)
                : BorderSide.none,
          ),
        ),
        child: Row(children: [
          const Icon(Icons.drag_indicator,
              size: 12, color: OpticsColors.textMuted),
          const SizedBox(width: 2),
          Expanded(
            child: Tooltip(
              message: '${c.tableDisplay}.${c.column}\nDrag to reorder',
              child: Text(
                c.column,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  fontFamily: 'Menlo',
                  color: OpticsColors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Tooltip(
            message: 'Remove column',
            child: InkWell(
              onTap: () => _removeColumn(c),
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close,
                    size: 12, color: OpticsColors.textMuted),
              ),
            ),
          ),
        ]),
      );
    }

    // Wrap in DragTarget<_ColumnReorder> so other header cells can drop here.
    return DragTarget<_ColumnReorder>(
      onWillAcceptWithDetails: (d) => d.data.fromIndex != index,
      onAcceptWithDetails: (d) => _reorderColumn(d.data.fromIndex, index),
      builder: (ctx, candidate, _) {
        final hovered = candidate.isNotEmpty;
        // The Draggable wraps the cell body so the cell itself is the handle.
        return Draggable<_ColumnReorder>(
          data: _ColumnReorder(fromIndex: index),
          axis: Axis.horizontal,
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: 0.85,
              child: Container(
                decoration: BoxDecoration(
                  color: OpticsColors.surfaceElevated,
                  border: Border.all(color: OpticsColors.accentCyan),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: cellBody(ghost: true),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: cellBody(),
          ),
          child: cellBody(dropBefore: hovered),
        );
      },
    );
  }

  void _reorderColumn(int from, int to) {
    if (from == to || from < 0 || to < 0) return;
    if (from >= _columns.length || to >= _columns.length) return;
    setState(() {
      final item = _columns.removeAt(from);
      // When moving forward, the target index shifts left by one after removal.
      final insertAt = from < to ? to : to;
      _columns.insert(insertAt, item);
    });
    _markDirty();
  }

  // (Legacy single-pane row builder removed in favor of the split
  // frozen/scrollable panes above.)
  // ignore: unused_element
  Widget _bodyRowLegacy(Map<String, dynamic> r, int index) {
    final isAlt = index.isOdd;
    return Container(
      decoration: BoxDecoration(
        color: isAlt
            ? OpticsColors.surfaceElevated.withValues(alpha: 0.35)
            : Colors.transparent,
        border: const Border(
          bottom: BorderSide(color: OpticsColors.border, width: 0.5),
        ),
      ),
      child: Row(children: [
        _rowNumberBodyCell(index),
        for (final c in _columns) _bodyDataCell(r, c),
        const SizedBox(width: 120, height: _rowHeight),
      ]),
    );
  }

  String _formatCell(dynamic v) {
    if (v == null) return '';
    if (v is String) {
      return v.length > 80 ? '${v.substring(0, 77)}…' : v;
    }
    if (v is num || v is bool) return v.toString();
    try {
      final s = jsonEncode(v);
      return s.length > 80 ? '${s.substring(0, 77)}…' : s;
    } catch (_) {
      return v.toString();
    }
  }

  // ── Draggable divider between canvas and live preview panel ──
  // Dragging left widens the right panel; dragging right narrows it.
  // The gutter visually preserves the same OpticsSpacing.lg padding by
  // centering a thin handle inside a wider transparent hit-target.
  Widget _buildPanelResizer(double maxRight) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Tooltip(
        message: 'Drag to resize panel',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) {
            setState(() {
              // Dragging right (positive dx) shrinks the right panel.
              final next = (_rightPanelWidth - d.delta.dx)
                  .clamp(_rightPanelMin, maxRight)
                  .toDouble();
              _rightPanelWidth = next;
            });
          },
          child: SizedBox(
            width: OpticsSpacing.lg,
            child: Center(
              child: Container(
                width: 3,
                decoration: BoxDecoration(
                  color: OpticsColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Right-side live preview panel (Table view only) ──
  Widget _buildLivePreviewPanel(DataSource src) {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Panel header.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                OpticsSpacing.md, OpticsSpacing.md, OpticsSpacing.md, 8),
            child: Row(children: [
              const Icon(Icons.insert_chart_outlined,
                  size: 14, color: OpticsColors.accentCyan),
              const SizedBox(width: 6),
              const Text('LIVE PREVIEW',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: OpticsColors.textSecondary,
                  )),
              const Spacer(),
              // Mini chart-type switcher so the user can preview different
              // chart kinds without leaving Table view.
              _miniChartTypeSwitcher(),
            ]),
          ),
          Divider(
              color: OpticsColors.border.withValues(alpha: 0.3),
              height: 1),
          Expanded(child: _livePreviewBody(src)),
        ],
      ),
    );
  }

  Widget _miniChartTypeSwitcher() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _ChartKind.values.map((k) {
        final active = _widget.kind == k;
        return InkWell(
          onTap: () {
            setState(() => _widget.kind = k);
            _markDirty();
          },
          borderRadius: BorderRadius.circular(4),
          child: Tooltip(
            message: k.label,
            child: Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: active
                    ? OpticsColors.accentCyan.withValues(alpha: 0.14)
                    : Colors.transparent,
                border: Border.all(
                  color: active
                      ? OpticsColors.accentCyan
                      : OpticsColors.border,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(k.icon,
                  size: 12,
                  color: active
                      ? OpticsColors.accentCyan
                      : OpticsColors.textSecondary),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _livePreviewBody(DataSource src) {
    if (_columns.isEmpty || _selectedTable == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.bar_chart_outlined,
                  size: 36, color: OpticsColors.textMuted),
              SizedBox(height: 10),
              Text(
                'Drag columns into the canvas to see a live preview here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: OpticsColors.textMuted),
              ),
            ],
          ),
        ),
      );
    }
    final args = _PreviewArgs(
      dataSourceId: src.id,
      table: _selectedTable!,
      columns: _columns.map((c) => c.toRpcColumn()).toList(),
      limit: _previewLimit,
    );
    final dataAsync = ref.watch(_previewProvider(args));
    return Padding(
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: dataAsync.when(
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(
              child: Text('No rows returned for this selection.',
                  style: TextStyle(
                      fontSize: 12, color: OpticsColors.textMuted)),
            );
          }
          return _chartPreview(rows);
        },
        loading: () => const Center(
            child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, st) => Center(
          child: Text('Preview error: $e',
              style: const TextStyle(
                  fontSize: 12, color: OpticsColors.danger)),
        ),
      ),
    );
  }

  // ── Widget controls panel (Blended view, lower-right) ──
  Widget _buildWidgetControlsPanel() {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                OpticsSpacing.md, OpticsSpacing.md, OpticsSpacing.md, 8),
            child: Row(children: const [
              Icon(Icons.tune,
                  size: 14, color: OpticsColors.accentCyan),
              SizedBox(width: 6),
              Text('WIDGET CONTROLS',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: OpticsColors.textSecondary,
                  )),
            ]),
          ),
          Divider(
              color: OpticsColors.border.withValues(alpha: 0.3),
              height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(OpticsSpacing.md),
              child: _widgetConfigPanel(),
            ),
          ),
        ],
      ),
    );
  }

  // ── Widget view (full chart builder) ──
  Widget _widgetCanvas(DataSource src) {
    if (_columns.isEmpty) {
      return _emptyWidgetCanvas();
    }
    final args = _PreviewArgs(
      dataSourceId: src.id,
      table: _selectedTable!,
      columns: _columns.map((c) => c.toRpcColumn()).toList(),
      limit: _previewLimit,
    );
    final dataAsync = ref.watch(_previewProvider(args));

    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(color: OpticsColors.border),
      ),
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Chart configuration sidebar.
          SizedBox(width: 240, child: _widgetConfigPanel()),
          const SizedBox(width: OpticsSpacing.lg),
          // Live chart preview.
          Expanded(
            child: dataAsync.when(
              data: (rows) => _chartPreview(rows),
              loading: () => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
              error: (e, st) => Center(
                child: Text('Could not load rows: $e',
                    style: const TextStyle(color: OpticsColors.danger)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyWidgetCanvas() {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.lg),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.insert_chart_outlined,
                size: 48, color: OpticsColors.textMuted),
            const SizedBox(height: 12),
            const Text(
              'Pick columns in Table view first.',
              style: TextStyle(
                  fontSize: 14,
                  color: OpticsColors.textMuted,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            const Text(
              'Once you have at least one column, switch back here to chart it.',
              style: TextStyle(fontSize: 12, color: OpticsColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _widgetConfigPanel() {
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        border: Border.all(color: OpticsColors.border),
      ),
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionLabel('CHART TYPE'),
            const SizedBox(height: 6),
            _chartTypeRow(),
            const SizedBox(height: 14),
            _sectionLabel('X AXIS'),
            const SizedBox(height: 4),
            _columnDropdown(
              value: _widget.xColumn,
              onChanged: (v) {
                setState(() => _widget.xColumn = v);
                _markDirty();
              },
              hint: 'Select dimension',
            ),
            const SizedBox(height: 14),
            _sectionLabel('Y MEASURE'),
            const SizedBox(height: 4),
            if (_widget.kind != _ChartKind.kpi || _widget.agg != _Aggregation.count)
              _columnDropdown(
                value: _widget.yColumn,
                onChanged: (v) {
                  setState(() => _widget.yColumn = v);
                  _markDirty();
                },
                hint: 'Select measure',
                numericOnly: true,
              ),
            const SizedBox(height: 8),
            _sectionLabel('AGGREGATION'),
            const SizedBox(height: 4),
            _aggDropdown(),
            const SizedBox(height: 14),
            _sectionLabel('COLOR SCHEME'),
            const SizedBox(height: 4),
            _colorSchemeDropdown(),
            const SizedBox(height: 14),
            _sectionLabel('MAX ITEMS'),
            const SizedBox(height: 4),
            _maxItemsDropdown(),
            const SizedBox(height: 14),
            _sectionLabel('DISPLAY'),
            const SizedBox(height: 4),
            _toggleRow('Show legend', _widget.showLegend, (v) {
              setState(() => _widget.showLegend = v);
              _markDirty();
            }),
            _toggleRow('Show grid', _widget.showGrid, (v) {
              setState(() => _widget.showGrid = v);
              _markDirty();
            }),
            _toggleRow('Show labels', _widget.showLabels, (v) {
              setState(() => _widget.showLabels = v);
              _markDirty();
            }),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(text,
        style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: OpticsColors.textSecondary));
  }

  Widget _chartTypeRow() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: _ChartKind.values.map((k) {
        final active = _widget.kind == k;
        return InkWell(
          onTap: () {
            setState(() => _widget.kind = k);
            _markDirty();
          },
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? OpticsColors.accentCyan.withValues(alpha: 0.14)
                  : OpticsColors.surface,
              border: Border.all(
                color: active
                    ? OpticsColors.accentCyan
                    : OpticsColors.border,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(k.icon,
                  size: 13,
                  color: active
                      ? OpticsColors.accentCyan
                      : OpticsColors.textSecondary),
              const SizedBox(width: 4),
              Text(k.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: active
                        ? OpticsColors.accentCyan
                        : OpticsColors.textPrimary,
                  )),
            ]),
          ),
        );
      }).toList(),
    );
  }

  Widget _columnDropdown({
    required String? value,
    required ValueChanged<String?> onChanged,
    required String hint,
    bool numericOnly = false,
  }) {
    final items = _columns
        .where((c) => !numericOnly || _isNumericType(c.dataType))
        .toList();
    if (items.isEmpty) {
      return Text(
        numericOnly
            ? 'No numeric columns yet.'
            : 'No columns added yet.',
        style: const TextStyle(
            fontSize: 12, color: OpticsColors.textMuted),
      );
    }
    final safeValue = items.any((c) => c.column == value) ? value : null;
    return DropdownButtonFormField<String>(
      initialValue: safeValue,
      isDense: true,
      isExpanded: true,
      hint: Text(hint, style: const TextStyle(fontSize: 12)),
      style: const TextStyle(fontSize: 12, color: OpticsColors.textPrimary),
      dropdownColor: OpticsColors.surfaceElevated,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding:
            EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      items: items
          .map((c) => DropdownMenuItem(
                value: c.column,
                child: Text(c.column,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'Menlo'),
                    overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: onChanged,
    );
  }

  Widget _aggDropdown() {
    return DropdownButtonFormField<_Aggregation>(
      initialValue: _widget.agg,
      isDense: true,
      isExpanded: true,
      style: const TextStyle(fontSize: 12, color: OpticsColors.textPrimary),
      dropdownColor: OpticsColors.surfaceElevated,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      items: _Aggregation.values
          .map((a) => DropdownMenuItem(
                value: a,
                child: Text(a.label, style: const TextStyle(fontSize: 12)),
              ))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _widget.agg = v);
        _markDirty();
      },
    );
  }

  Widget _colorSchemeDropdown() {
    const schemes = ['default', 'cool', 'warm', 'mono', 'neon'];
    return DropdownButtonFormField<String>(
      initialValue: _widget.colorScheme,
      isDense: true,
      isExpanded: true,
      style: const TextStyle(fontSize: 12, color: OpticsColors.textPrimary),
      dropdownColor: OpticsColors.surfaceElevated,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      items: schemes
          .map((s) => DropdownMenuItem(
                value: s,
                child: Text(s[0].toUpperCase() + s.substring(1),
                    style: const TextStyle(fontSize: 12)),
              ))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _widget.colorScheme = v);
        _markDirty();
      },
    );
  }

  Widget _maxItemsDropdown() {
    return DropdownButtonFormField<int>(
      initialValue: _widget.maxItems,
      isDense: true,
      isExpanded: true,
      style: const TextStyle(fontSize: 12, color: OpticsColors.textPrimary),
      dropdownColor: OpticsColors.surfaceElevated,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      items: const [5, 10, 20, 50, 100]
          .map((v) => DropdownMenuItem(
                value: v,
                child: Text('$v', style: const TextStyle(fontSize: 12)),
              ))
          .toList(),
      onChanged: (v) {
        if (v == null) return;
        setState(() => _widget.maxItems = v);
        _markDirty();
      },
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12, color: OpticsColors.textPrimary)),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
        ),
      ]),
    );
  }

  // ── Chart preview ──

  List<_Aggregated> _aggregate(List<Map<String, dynamic>> rows) {
    final x = _widget.xColumn;
    final y = _widget.yColumn;
    if (x == null) return const [];

    final groups = <String, List<double>>{};
    final order = <String>[];
    for (final r in rows) {
      final key = _formatLabel(r[x]);
      final v = _numeric(r[y]);
      final list = groups[key];
      if (list == null) {
        groups[key] = [if (v != null) v];
        order.add(key);
      } else {
        if (v != null) list.add(v);
      }
    }

    final result = <_Aggregated>[];
    for (final k in order) {
      final vals = groups[k] ?? const <double>[];
      double agg;
      switch (_widget.agg) {
        case _Aggregation.count:
          agg = (groups[k]?.length ?? 0).toDouble();
          // count uses the number of rows in the group, not just non-null y.
          agg = rows
              .where((r) => _formatLabel(r[x]) == k)
              .length
              .toDouble();
          break;
        case _Aggregation.sum:
          agg = vals.fold(0.0, (a, b) => a + b);
          break;
        case _Aggregation.avg:
          agg = vals.isEmpty
              ? 0
              : vals.fold(0.0, (a, b) => a + b) / vals.length;
          break;
        case _Aggregation.min:
          agg = vals.isEmpty
              ? 0
              : vals.reduce((a, b) => a < b ? a : b);
          break;
        case _Aggregation.max:
          agg = vals.isEmpty
              ? 0
              : vals.reduce((a, b) => a > b ? a : b);
          break;
      }
      result.add(_Aggregated(k, agg));
    }

    // Sort: descending by value if not the count-of-rows mode for a kpi card.
    result.sort((a, b) => b.value.compareTo(a.value));

    if (result.length > _widget.maxItems) {
      return result.sublist(0, _widget.maxItems);
    }
    return result;
  }

  double? _numeric(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  String _formatLabel(dynamic v) {
    if (v == null) return '—';
    if (v is String) return v;
    if (v is num) return v.toString();
    return v.toString();
  }

  Widget _chartPreview(List<Map<String, dynamic>> rows) {
    if (_widget.kind == _ChartKind.kpi) {
      return _kpiPreview(rows);
    }
    if (_widget.xColumn == null) {
      return const Center(
        child: Text('Pick an X axis to render this chart.',
            style: TextStyle(
                fontSize: 13, color: OpticsColors.textMuted)),
      );
    }
    if (_widget.kind != _ChartKind.kpi &&
        _widget.agg != _Aggregation.count &&
        _widget.yColumn == null) {
      return const Center(
        child: Text('Pick a Y measure (or change aggregation to Count).',
            style: TextStyle(
                fontSize: 13, color: OpticsColors.textMuted)),
      );
    }
    final data = _aggregate(rows);
    if (data.isEmpty) {
      return const Center(
        child: Text('No data for the current selection.',
            style: TextStyle(
                fontSize: 13, color: OpticsColors.textMuted)),
      );
    }
    final palette = _paletteFor(_widget.colorScheme);
    switch (_widget.kind) {
      case _ChartKind.bar:   return _barChart(data, palette);
      case _ChartKind.hbar:  return _hBarChart(data, palette);
      case _ChartKind.line:  return _lineChart(data, palette);
      case _ChartKind.area:  return _lineChart(data, palette, area: true);
      case _ChartKind.combo: return _comboChart(data, palette);
      case _ChartKind.pie:   return _pieChart(data, palette, donut: false);
      case _ChartKind.donut: return _pieChart(data, palette, donut: true);
      case _ChartKind.gauge: return _gaugeChart(data, palette);
      case _ChartKind.table: return _tableChart(rows);
      case _ChartKind.kpi:   return _kpiPreview(rows); // unreachable
    }
  }

  Widget _kpiPreview(List<Map<String, dynamic>> rows) {
    double value;
    String label;
    if (_widget.agg == _Aggregation.count || _widget.yColumn == null) {
      value = rows.length.toDouble();
      label = 'Count of rows';
    } else {
      final nums = rows
          .map((r) => _numeric(r[_widget.yColumn]))
          .whereType<double>()
          .toList();
      switch (_widget.agg) {
        case _Aggregation.sum:
          value = nums.fold(0.0, (a, b) => a + b);
          break;
        case _Aggregation.avg:
          value = nums.isEmpty
              ? 0
              : nums.fold(0.0, (a, b) => a + b) / nums.length;
          break;
        case _Aggregation.min:
          value =
              nums.isEmpty ? 0 : nums.reduce((a, b) => a < b ? a : b);
          break;
        case _Aggregation.max:
          value =
              nums.isEmpty ? 0 : nums.reduce((a, b) => a > b ? a : b);
          break;
        case _Aggregation.count:
          value = rows.length.toDouble();
          break;
      }
      label = '${_widget.agg.label} of ${_widget.yColumn}';
    }
    final formatted = value == value.roundToDouble()
        ? NumberFormat('#,##0').format(value.toInt())
        : NumberFormat('#,##0.00').format(value);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            formatted,
            style: TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.w800,
              color: _paletteFor(_widget.colorScheme).first,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 8),
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: OpticsColors.textSecondary)),
          const SizedBox(height: 12),
          Text('Across ${rows.length} rows',
              style: const TextStyle(
                  fontSize: 12, color: OpticsColors.textMuted)),
        ],
      ),
    );
  }

  Widget _barChart(List<_Aggregated> data, List<Color> palette) {
    final maxY = data.fold<double>(0, (m, d) => d.value > m ? d.value : m);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxY * 1.15,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) =>
                  OpticsColors.surfaceElevated,
              getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
                '${data[g.x.toInt()].label}\n${_fmt(r.toY)}',
                const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: _widget.showLabels,
                reservedSize: 44,
                getTitlesWidget: (v, _) => Text(_fmtShort(v),
                    style: const TextStyle(
                        fontSize: 10, color: OpticsColors.textMuted)),
              ),
            ),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: _widget.showLabels,
                reservedSize: 36,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= data.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _truncate(data[i].label, 10),
                      style: const TextStyle(
                          fontSize: 10, color: OpticsColors.textMuted),
                    ),
                  );
                },
              ),
            ),
          ),
          gridData: FlGridData(
            show: _widget.showGrid,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: OpticsColors.border.withValues(alpha: 0.6),
              strokeWidth: 0.5,
            ),
          ),
          borderData: FlBorderData(show: false),
          barGroups: List.generate(data.length, (i) {
            final color = palette[i % palette.length];
            return BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: data[i].value,
                color: color,
                width: _previewBarWidth(data.length),
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4)),
              ),
            ]);
          }),
        ),
      ),
    );
  }

  // Bar width for the Live Preview bar chart. Scales down only when there
  // are lots of categories; otherwise stays thick and readable.
  double _previewBarWidth(int count) {
    if (count <= 3) return 56;
    if (count <= 5) return 44;
    if (count <= 8) return 32;
    if (count <= 12) return 22;
    if (count <= 20) return 14;
    return 10;
  }

  Widget _lineChart(List<_Aggregated> data, List<Color> palette,
      {bool area = false}) {
    final maxY = data.fold<double>(0, (m, d) => d.value > m ? d.value : m);
    final spots = List.generate(
        data.length, (i) => FlSpot(i.toDouble(), data[i].value));
    final color = palette.first;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: LineChart(
        LineChartData(
          maxY: maxY * 1.15,
          minY: 0,
          gridData: FlGridData(
            show: _widget.showGrid,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: OpticsColors.border.withValues(alpha: 0.6),
              strokeWidth: 0.5,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: _widget.showLabels,
                reservedSize: 44,
                getTitlesWidget: (v, _) => Text(_fmtShort(v),
                    style: const TextStyle(
                        fontSize: 10, color: OpticsColors.textMuted)),
              ),
            ),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: _widget.showLabels,
                reservedSize: 36,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= data.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _truncate(data[i].label, 10),
                      style: const TextStyle(
                          fontSize: 10, color: OpticsColors.textMuted),
                    ),
                  );
                },
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              barWidth: 2,
              color: color,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: area ? 0.35 : 0.15),
              ),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => OpticsColors.surfaceElevated,
              getTooltipItems: (touched) => touched
                  .map((t) => LineTooltipItem(
                        '${data[t.x.toInt()].label}\n${_fmt(t.y)}',
                        const TextStyle(color: Colors.white, fontSize: 11),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hBarChart(List<_Aggregated> data, List<Color> palette) {
    final maxV = data.fold<double>(0, (m, d) => d.value > m ? d.value : m);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: ListView.builder(
        itemCount: data.length,
        itemBuilder: (_, i) {
          final color = palette[i % palette.length];
          final pct = maxV == 0 ? 0.0 : data[i].value / maxV;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(
                width: 80,
                child: Text(
                  _truncate(data[i].label, 14),
                  style: const TextStyle(
                      fontSize: 11, color: OpticsColors.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Stack(children: [
                  Container(
                    height: 14,
                    decoration: BoxDecoration(
                      color: OpticsColors.border.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: pct.clamp(0.0, 1.0),
                    child: Container(
                      height: 14,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 56,
                child: Text(_fmtShort(data[i].value),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 11, color: OpticsColors.textMuted)),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _comboChart(List<_Aggregated> data, List<Color> palette) {
    // Bars + overlaid line using the same Y series — gives the dual-axis
    // visual treatment without requiring a second measure column.
    final maxY = data.fold<double>(0, (m, d) => d.value > m ? d.value : m);
    final spots = List.generate(
        data.length, (i) => FlSpot(i.toDouble(), data[i].value));
    final barColor = palette.first;
    final lineColor =
        palette.length > 1 ? palette[1] : palette.first;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Stack(children: [
        BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxY * 1.15,
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: _widget.showLabels,
                  reservedSize: 44,
                  getTitlesWidget: (v, _) => Text(_fmtShort(v),
                      style: const TextStyle(
                          fontSize: 10, color: OpticsColors.textMuted)),
                ),
              ),
              rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false)),
              topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: _widget.showLabels,
                  reservedSize: 36,
                  getTitlesWidget: (v, _) {
                    final i = v.toInt();
                    if (i < 0 || i >= data.length) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(_truncate(data[i].label, 10),
                          style: const TextStyle(
                              fontSize: 10,
                              color: OpticsColors.textMuted)),
                    );
                  },
                ),
              ),
            ),
            gridData: FlGridData(
              show: _widget.showGrid,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (_) => FlLine(
                color: OpticsColors.border.withValues(alpha: 0.6),
                strokeWidth: 0.5,
              ),
            ),
            borderData: FlBorderData(show: false),
            barGroups: List.generate(data.length, (i) {
              return BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: data[i].value,
                  color: barColor.withValues(alpha: 0.55),
                  width: _previewBarWidth(data.length),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4)),
                ),
              ]);
            }),
          ),
        ),
        // Overlay line — disable its own axes so it lines up with the bars.
        IgnorePointer(
          child: LineChart(
            LineChartData(
              maxY: maxY * 1.15,
              minY: 0,
              titlesData: const FlTitlesData(show: false),
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  barWidth: 2.5,
                  color: lineColor,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _gaugeChart(List<_Aggregated> data, List<Color> palette) {
    final total = data.fold<double>(0, (a, b) => a + b.value);
    final max = data.fold<double>(0, (m, d) => d.value > m ? d.value : m);
    // Gauge fills 0..(target) where target = max * 1.25 (gives headroom).
    final target = max == 0 ? 1 : max * 1.25;
    final pct = (total / target).clamp(0.0, 1.0).toDouble();
    final color = palette.first;
    return LayoutBuilder(builder: (ctx, c) {
      final dia = (c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight) * 0.85;
      return Center(
        child: SizedBox(
          width: dia,
          height: dia,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: pct,
                strokeWidth: 14,
                backgroundColor:
                    OpticsColors.border.withValues(alpha: 0.25),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_fmt(total),
                    style: TextStyle(
                      fontSize: dia * 0.18,
                      fontWeight: FontWeight.w800,
                      color: color,
                    )),
                const SizedBox(height: 4),
                Text('${(pct * 100).toStringAsFixed(0)}% of target',
                    style: const TextStyle(
                        fontSize: 11,
                        color: OpticsColors.textMuted)),
              ],
            ),
          ]),
        ),
      );
    });
  }

  Widget _tableChart(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty || _columns.isEmpty) {
      return const Center(
        child: Text('No rows to display.',
            style: TextStyle(
                fontSize: 12, color: OpticsColors.textMuted)),
      );
    }
    final cols = _columns;
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          child: DataTable(
            headingRowHeight: 30,
            dataRowMinHeight: 26,
            dataRowMaxHeight: 32,
            columnSpacing: 18,
            headingTextStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: OpticsColors.textSecondary),
            dataTextStyle: const TextStyle(
                fontSize: 11, color: OpticsColors.textPrimary),
            columns: cols
                .map((c) => DataColumn(label: Text(c.label)))
                .toList(),
            rows: rows.take(50).map((r) {
              return DataRow(
                cells: cols.map((c) {
                  final v = r[c.column];
                  return DataCell(Text(v == null ? '—' : v.toString()));
                }).toList(),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _pieChart(List<_Aggregated> data, List<Color> palette,
      {required bool donut}) {
    final total =
        data.fold<double>(0, (a, b) => a + b.value);
    return Row(
      children: [
        Expanded(
          child: PieChart(
            PieChartData(
              centerSpaceRadius: donut ? 60 : 0,
              sectionsSpace: 2,
              sections: List.generate(data.length, (i) {
                final color = palette[i % palette.length];
                final v = data[i].value;
                final pct = total == 0 ? 0 : (v / total) * 100;
                return PieChartSectionData(
                  color: color,
                  value: v,
                  radius: donut ? 50 : 80,
                  title: _widget.showLabels
                      ? '${pct.toStringAsFixed(0)}%'
                      : '',
                  titleStyle: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white),
                );
              }),
            ),
          ),
        ),
        if (_widget.showLegend)
          SizedBox(
            width: 180,
            child: ListView.builder(
              itemCount: data.length,
              itemBuilder: (_, i) {
                final color = palette[i % palette.length];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_truncate(data[i].label, 18),
                          style: const TextStyle(
                              fontSize: 11,
                              color: OpticsColors.textPrimary),
                          overflow: TextOverflow.ellipsis),
                    ),
                    Text(_fmtShort(data[i].value),
                        style: const TextStyle(
                            fontSize: 11,
                            color: OpticsColors.textMuted)),
                  ]),
                );
              },
            ),
          ),
      ],
    );
  }

  String _fmt(double v) {
    if (v == v.roundToDouble()) return NumberFormat('#,##0').format(v.toInt());
    return NumberFormat('#,##0.00').format(v);
  }

  String _fmtShort(double v) {
    if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v.abs() >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1)}…';
}

class _Aggregated {
  final String label;
  final double value;
  const _Aggregated(this.label, this.value);
}

// Color palettes mirror widget_renderer.dart so charts here look identical to
// the published dashboard widgets.
List<Color> _paletteFor(String scheme) {
  switch (scheme) {
    case 'cool':
      return const [
        Color(0xFF3DB8FF), Color(0xFF7DD3FC), Color(0xFF9B7BFF),
        Color(0xFF818CF8), Color(0xFF34D399), Color(0xFF6EE7B7),
        Color(0xFF67E8F9), Color(0xFFA5F3FC), Color(0xFFE879F9),
      ];
    case 'warm':
      return const [
        Color(0xFFFFA850), Color(0xFFFBBF24), Color(0xFFFF7AC6),
        Color(0xFFFF6B6B), Color(0xFFFCA5A5), Color(0xFFFDE68A),
        Color(0xFFF9A8D4), Color(0xFFFB923C), Color(0xFFEF4444),
      ];
    case 'mono':
      return const [
        Color(0xFFE6E8F0), Color(0xFF9CA3B5), Color(0xFF6B7280),
        Color(0xFF4B5563), Color(0xFF374151), Color(0xFF1F2937),
        Color(0xFFD1D5DB), Color(0xFF9CA3AF), Color(0xFF111827),
      ];
    case 'neon':
      return const [
        Color(0xFF00FF87), Color(0xFF00D4FF), Color(0xFFFF00FF),
        Color(0xFFFFFF00), Color(0xFFFF4500), Color(0xFF7B68EE),
        Color(0xFF00FFFF), Color(0xFFFF1493), Color(0xFF39FF14),
      ];
    default:
      return OpticsColors.chartPalette;
  }
}
