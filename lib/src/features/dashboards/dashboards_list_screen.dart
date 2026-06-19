import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/canvas_zoom.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';
import '../../shared/secure_error.dart';
import '../reports/report_viewer_screen.dart' show restDataSourceIdProvider;
import 'time_range_options.dart';
import 'time_range_picker.dart';
import 'widget_grid.dart';
import 'widget_settings_panel.dart';

// ignore: unused_import

/// The active dashboard ID — persists across navigation.
final activeDashboardIdProvider = StateProvider<String?>((ref) => null);

class DashboardsListScreen extends ConsumerStatefulWidget {
  const DashboardsListScreen({super.key});
  @override
  ConsumerState<DashboardsListScreen> createState() =>
      _DashboardsListScreenState();
}

class _DashboardsListScreenState extends ConsumerState<DashboardsListScreen> {
  WidgetModel? _selected;

  /// Snapshot of the widget BEFORE the settings panel was opened — used to
  /// revert on Cancel (live preview updates _widgets in place, so we need this).
  WidgetModel? _selectedOriginal;

  /// Snapshot of ALL widgets BEFORE the global dashboard settings dialog was
  /// opened — used to revert on Cancel (live preview updates _widgets in place).
  List<WidgetModel>? _globalSettingsOriginalWidgets;

  /// Preview override for theme — when non-null, overrides currentDash.settings['theme']
  /// for live preview while the global settings dialog is open.
  String? _themePreviewOverride;

  /// The widget list is held DIRECTLY in State — no providers, no caching,
  /// no timing issues. `setState` triggers an immediate rebuild.
  List<WidgetModel> _widgets = [];
  String? _loadedDashId;

  /// Per-widget debounce timers so high-frequency drag/resize events coalesce
  /// into a single DB write at the end of the gesture.
  final Map<String, Timer> _persistTimers = {};

  /// Auto-refresh timer driven by the dashboard-level `refreshInterval` setting.
  Timer? _autoRefreshTimer;

  @override
  void dispose() {
    for (final t in _persistTimers.values) {
      t.cancel();
    }
    _persistTimers.clear();
    _progressTimer?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  /// Persist a widget mutation (move/resize/settings) to the backing repo.
  /// Debounced ~400 ms per widget id so drag/resize fires one final write.
  void _persistWidget(WidgetModel w) {
    _persistTimers[w.id]?.cancel();
    _persistTimers[w.id] = Timer(const Duration(milliseconds: 400), () async {
      _persistTimers.remove(w.id);
      try {
        await ref.read(repoProvider).updateWidget(w);
      } catch (e, st) {
        debugPrint('[Optics] Error persisting widget ${w.id}: $e\n$st');
        if (!mounted) return;
        showSecureErrorSnackBar(context, ref, 'Could not save widget changes.', e);
      }
    });
  }

  /// Whether a manual tenant-wide sync is currently in flight (UI spinner state).
  bool _syncing = false;

  /// Aggregated live progress across all data sources currently syncing.
  /// {total, completed, errored, elapsed_ms, eta_ms}. Null when not syncing.
  Map<String, dynamic>? _syncProgress;

  /// Polls etl_runs every 2 s to update _syncProgress while syncing.
  Timer? _progressTimer;

  /// Trigger a manual data refresh for every data source in the active tenant.
  /// Each source's sync runs in the background; we poll their state and
  /// reload widgets once everything settles. The refresh icon on the
  /// dashboard header drives this — no need to navigate to Settings.
  Future<void> _manualSync(String dashId) async {
    if (_syncing) return;
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(repoProvider);

    setState(() {
      _syncing = true;
      _syncProgress = null;
    });
    try {
      final sources = await repo.listDataSources();
      if (sources.isEmpty) {
        messenger.showSnackBar(const SnackBar(
          content: Text('No data sources connected for this tenant.', style: const TextStyle(color: Colors.white)),
        ));
        return;
      }
      // Kick off all syncs in parallel (each returns immediately).
      final failures = <String>[];
      await Future.wait(sources.map((s) async {
        try {
          await repo.requestDataSourceSync(s.id);
        } catch (e) {
          failures.add('${s.name}: $e');
        }
      }));
      if (failures.isNotEmpty) {
        messenger.showSnackBar(SnackBar(
          backgroundColor: OpticsColors.danger,
          content: Text('Could not start data sync. Please try again.', style: const TextStyle(color: Colors.white)),
        ));
      } else {
        messenger.showSnackBar(SnackBar(
          content: Text(
              'Refreshing ${sources.length} data source${sources.length == 1 ? '' : 's'} (incremental — only new/changed rows)…'),
        ));
      }

      // Begin polling progress every 2 s. Aggregates across all sources so
      // the inline counter shows e.g. "12/72 · 0:34 elapsed · ~1:22 left".
      _progressTimer?.cancel();
      _progressTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (!mounted) return;
        try {
          final progs = await Future.wait(
              sources.map((s) => repo.getSyncProgress(s.id)));
          int total = 0, completed = 0, errored = 0, elapsed = 0;
          int? etaMax;
          for (final p in progs) {
            total += (p['total'] as int? ?? 0);
            completed += (p['completed'] as int? ?? 0);
            errored += (p['errored'] as int? ?? 0);
            final e = p['elapsed_ms'] as int? ?? 0;
            if (e > elapsed) elapsed = e;
            final eta = p['eta_ms'] as int?;
            if (eta != null && (etaMax == null || eta > etaMax)) etaMax = eta;
          }
          if (!mounted) return;
          setState(() {
            _syncProgress = {
              'total': total,
              'completed': completed,
              'errored': errored,
              'elapsed_ms': elapsed,
              'eta_ms': etaMax,
            };
          });
        } catch (_) {/* swallow — next tick will retry */}
      });

      // Poll each source until none are "running", then reload widgets.
      final deadline = DateTime.now().add(const Duration(minutes: 4));
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 5));
        if (!mounted) return;
        final states = await Future.wait(
            sources.map((s) => repo.getDataSourceSync(s.id)));
        final stillRunning = states
            .where((st) => (st?['last_sync_status'] as String?) == 'running')
            .length;
        // Invalidate per-source sync providers so the Settings UI also updates.
        for (final s in sources) {
          ref.invalidate(dataSourceSyncProvider(s.id));
        }
        if (stillRunning == 0) break;
      }
      if (!mounted) return;
      _loadWidgets(dashId);
      messenger.showSnackBar(const SnackBar(content: Text('Data refresh complete.', style: TextStyle(color: Colors.white))));
    } catch (e) {
      if (mounted) {
        showSecureErrorSnackBar(context, ref, 'Data refresh failed.', e);
      }
    } finally {
      _progressTimer?.cancel();
      _progressTimer = null;
      if (mounted) {
        setState(() {
          _syncing = false;
          _syncProgress = null;
        });
      }
    }
  }

  /// Format milliseconds as "M:SS" (or "H:MM:SS" for ≥1 h).
  String _fmtDuration(int ms) {
    final s = (ms / 1000).round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final pad = (int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${pad(m)}:${pad(sec)}';
    return '$m:${pad(sec)}';
  }

  /// Load widgets for a dashboard into local state.
  void _loadWidgets(String dashId) {
    debugPrint('[Optics] _loadWidgets START dashId=$dashId');
    ref.read(repoProvider).listWidgets(dashId).then((list) {
      debugPrint('[Optics] _loadWidgets OK dashId=$dashId count=${list.length}');
      if (!mounted) return;
      setState(() {
        _widgets = List<WidgetModel>.from(list);
        _loadedDashId = dashId;
        _selected = null;
      });
    }).catchError((e, st) {
      debugPrint('[Optics] _loadWidgets ERR dashId=$dashId: $e\n$st');
      if (mounted) {
        showSecureErrorSnackBar(context, ref, 'Failed to load widgets.', e);
      }
    });
  }

  /// Apply global dashboard settings to all widgets for live preview.
  /// Does NOT persist — just updates local _widgets state.
  void _applyGlobalSettingsPreview(Map<String, dynamic> settings) {
    debugPrint('[GlobalSettings] _applyGlobalSettingsPreview called with: $settings');
    final colorScheme = settings['colorScheme'] as String?;
    final timeRange = settings['timeRange'] as String?;
    final showGridLines = settings['showGridLines'] as bool?;
    final theme = settings['theme'] as String?;

    debugPrint('[GlobalSettings] Applying: colorScheme=$colorScheme, timeRange=$timeRange, showGridLines=$showGridLines, theme=$theme');
    debugPrint('[GlobalSettings] Widget count before: ${_widgets.length}');

    setState(() {
      // Update theme preview override (affects background/chrome)
      if (theme != null) _themePreviewOverride = theme;

      // Update widget-level settings (including theme for WidgetThemeColors)
      _widgets = _widgets.map((w) {
        final updatedSettings = Map<String, dynamic>.from(w.settings);
        if (colorScheme != null) updatedSettings['colorScheme'] = colorScheme;
        if (timeRange != null) updatedSettings['timeRange'] = timeRange;
        if (showGridLines != null) updatedSettings['gridLines'] = showGridLines;
        if (theme != null) updatedSettings['theme'] = theme;
        return w.copyWith(settings: updatedSettings);
      }).toList();
    });
    debugPrint('[GlobalSettings] Widget count after setState: ${_widgets.length}');
  }

  /// Called when the user picks a canned widget from the library dialog.
  Future<void> _addWidgetFromLibrary(LibraryItem item, String dashId) async {
    final typeStr = item.payload['type'] as String? ?? 'kpi';
    final kind = WidgetKind.fromString(typeStr);

    // ── Find the next available slot on the grid ──
    // Grid is 48 cols wide (see WidgetGrid.columns). New widget dimensions:
    final newW = (kind == WidgetKind.kpi ? 12 : 24).toDouble();
    final newH = (kind == WidgetKind.kpi ? 8 : 12).toDouble();
    const gridCols = 48;
    final slot = _findNextSlot(newW, newH, gridCols);

    // Resolve binding + settings from the preset payload. If the preset
    // carries a `binding.brz` block (live Bryzos metric), inject the active
    // tenant's REST data source id and use the authored binding/settings.
    // Otherwise fall back to demo binding so the tile renders immediately.
    final payloadBinding =
        (item.payload['binding'] as Map?)?.cast<String, dynamic>();
    final payloadSettings =
        (item.payload['settings'] as Map?)?.cast<String, dynamic>() ?? {};

    Map<String, dynamic> binding;
    Map<String, dynamic> settings;
    if (payloadBinding != null && payloadBinding['brz'] is Map) {
      final dataSourceId =
          await ref.read(restDataSourceIdProvider.future);
      final brz = Map<String, dynamic>.from(payloadBinding['brz'] as Map);
      if (dataSourceId != null) brz['data_source_id'] = dataSourceId;
      binding = {'brz': brz};
      settings = Map<String, dynamic>.from(payloadSettings);
    } else {
      binding = _demoBindingForWidget(item.name, kind);
      settings = Map<String, dynamic>.from(payloadSettings);
    }

    try {
      final saved = await ref.read(repoProvider).createWidget(
            dashboardId: dashId,
            title: item.name,
            kind: kind,
            x: slot.dx,
            y: slot.dy,
            w: newW,
            h: newH,
            binding: binding,
            settings: settings,
          );
      if (!mounted) return;
      setState(() {
        _widgets = [..._widgets, saved];
      });
      debugPrint(
          '[Optics] Added widget "${item.name}" (${kind.name})');
    } catch (e) {
      debugPrint('[Optics] Error creating widget: $e');
    }
  }

  /// Finds the first available grid position for a widget of size (w, h)
  /// that doesn't overlap any existing widget. Scans top-to-bottom,
  /// left-to-right with 1-cell granularity. Falls back to placing the new
  /// widget at (0, maxY) below all existing widgets if no in-grid slot fits.
  Offset _findNextSlot(double newW, double newH, int gridCols) {
    if (_widgets.isEmpty) return const Offset(0, 0);

    // Compute current footprint
    double maxBottom = 0;
    for (final w in _widgets) {
      final b = w.y + w.h;
      if (b > maxBottom) maxBottom = b;
    }

    // Scan within current canvas first.
    final scanRows = (maxBottom + newH).ceil();
    for (int y = 0; y <= scanRows; y++) {
      for (int x = 0; x + newW <= gridCols; x++) {
        final candidate = Rect.fromLTWH(
          x.toDouble(), y.toDouble(), newW, newH,
        );
        bool overlaps = false;
        for (final w in _widgets) {
          final existing = Rect.fromLTWH(w.x, w.y, w.w, w.h);
          if (candidate.overlaps(existing)) {
            overlaps = true;
            break;
          }
        }
        if (!overlaps) return Offset(x.toDouble(), y.toDouble());
      }
    }
    // Fallback — append at the bottom-left.
    return Offset(0, maxBottom);
  }

  // ── Constants for demo data generation ──
  static const _months12 = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _shapes = [
    'Angle', 'Bar', 'Beam', 'Channel', 'Coil', 'HSS', 'Pipe', 'Plate', 'Sheet',
  ];

  /// Generates realistic metals-procurement demo binding data.
  ///
  /// CRITICAL DESIGN: Every binding includes BOTH `_data`/`_labels` (single-series)
  /// AND `_multiSeries` (multi-series) when applicable. This means the widget
  /// renders correctly regardless of which chart type the user switches to.
  /// The title determines WHAT data (shapes, grades, companies, brackets, etc.)
  /// and the chart type determines HOW it's displayed.
  Map<String, dynamic> _demoBindingForWidget(String name, WidgetKind kind) {
    final n = name.toLowerCase();

    // ═══════════════════════════════════════════════════════════
    // ── KPI WIDGETS ──────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('revenue') && (n.contains('kpi') || kind == WidgetKind.kpi)) {
      return {
        '_data': [1.8, 2.1, 2.4, 2.3, 2.7, 3.0, 2.9, 3.2, 3.1, 3.5, 3.7, 3.9],
        '_unit': '\$M',
        '_timeRange': 'Last 12 months',
      };
    }
    if (n.contains('total orders') ||
        (n.contains('order') && n.contains('kpi') && kind == WidgetKind.kpi)) {
      return {'_data': [312, 328, 345, 361, 378, 402, 415, 438], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('active user') || (n.contains('user') && kind == WidgetKind.kpi)) {
      return {'_data': [412, 428, 445, 460, 478, 495, 510, 532], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('active compan')) {
      return {'_data': [142, 148, 155, 161, 167, 174, 180, 187], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('quote') && n.contains('created') && kind == WidgetKind.kpi) {
      return {'_data': [245, 268, 289, 312, 335, 348, 362, 381], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('conversion') && kind == WidgetKind.kpi) {
      return {'_data': [62, 64, 61, 66, 68, 65, 69, 71], '_unit': '%', '_timeRange': 'Last 12 months'};
    }
    if (n.contains('cancellation') && kind == WidgetKind.kpi) {
      return {'_data': [4.8, 4.5, 5.1, 4.2, 3.9, 4.1, 3.6, 3.4], '_unit': '%', '_timeRange': 'Last 12 months'};
    }
    if ((n.contains('on-time') || n.contains('otd') || n.contains('delivery rate')) &&
        kind == WidgetKind.kpi) {
      return {'_data': [91, 92, 90, 93, 94, 92, 95, 94], '_unit': '%', '_timeRange': 'Last 12 months'};
    }
    if (n.contains('weight') && kind == WidgetKind.kpi) {
      return {'_data': [245, 268, 280, 295, 310, 325, 340, 358], '_unit': 'K lbs', '_timeRange': 'Last 12 months'};
    }
    if (n.contains('avg item') && kind == WidgetKind.kpi) {
      return {'_data': [3.2, 3.4, 3.1, 3.6, 3.5, 3.8, 3.7, 4.0], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('search') && n.contains('volume') && kind == WidgetKind.kpi) {
      return {'_data': [12400, 13200, 14100, 14800, 15600, 16200, 17100, 18200], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('po count') || (n.contains('purchase') && kind == WidgetKind.kpi)) {
      return {'_data': [198, 212, 225, 238, 252, 268, 280, 295], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('open order') && kind == WidgetKind.kpi) {
      return {'_data': [142, 135, 148, 138, 155, 145, 162, 158], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('chat') && kind == WidgetKind.kpi) {
      if (n.contains('response')) {
        return {'_data': [4.2, 3.8, 3.5, 3.9, 3.2, 3.0, 2.8, 2.6], '_unit': ' hrs', '_timeRange': 'Last 12 months'};
      }
      return {'_data': [285, 298, 312, 325, 340, 355, 368, 382], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('bpn') && kind == WidgetKind.kpi) {
      return {'_data': [2800, 2950, 3100, 3280, 3450, 3620, 3800, 3980], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('bom') && kind == WidgetKind.kpi) {
      return {'_data': [42, 48, 55, 52, 60, 65, 70, 78], '_timeRange': 'Last 12 months'};
    }
    if (n.contains('retention') && kind == WidgetKind.kpi) {
      return {'_data': [82, 84, 83, 86, 88, 87, 89, 91], '_unit': '%', '_timeRange': 'Last 12 months'};
    }
    if (kind == WidgetKind.kpi) {
      return {'_data': [145, 152, 138, 167, 159, 172, 180, 194], '_timeRange': 'Last 12 months'};
    }

    // ═══════════════════════════════════════════════════════════
    // ── SHAPE-BASED WIDGETS (multi-series by metal shape) ────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('shape')) {
      final isDollar = n.contains('revenue') || n.contains('\$');
      return {
        '_multiSeries': [
          {'name': 'Bar',     'data': [120, 135, 128, 142, 150, 158, 162, 170, 175, 182, 188, 195]},
          {'name': 'Plate',   'data': [95, 108, 102, 115, 120, 125, 130, 138, 142, 148, 155, 162]},
          {'name': 'Sheet',   'data': [68, 72, 80, 85, 90, 88, 95, 100, 105, 110, 115, 120]},
          {'name': 'Pipe',    'data': [52, 58, 55, 62, 65, 70, 68, 74, 78, 82, 85, 90]},
          {'name': 'Coil',    'data': [40, 45, 42, 48, 52, 55, 58, 62, 65, 68, 72, 76]},
          {'name': 'Beam',    'data': [35, 38, 40, 42, 45, 48, 50, 54, 56, 60, 62, 66]},
          {'name': 'HSS',     'data': [28, 30, 32, 35, 38, 40, 42, 46, 48, 50, 54, 58]},
          {'name': 'Channel', 'data': [22, 25, 24, 28, 30, 32, 35, 38, 40, 42, 45, 48]},
          {'name': 'Angle',   'data': [18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 42]},
        ],
        '_labels': _months12,
        '_yLabel': isDollar ? 'Revenue (\$K)' : 'Orders',
        '_col1': 'Shape',
        '_col2': isDollar ? 'Revenue' : 'Orders',
        '_unit': isDollar ? '\$K' : '',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── GRADE-BASED WIDGETS (multi-series by alloy grade) ────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('grade') || n.contains('alloy')) {
      final isDollar = n.contains('revenue') || n.contains('\$');
      return {
        '_multiSeries': [
          {'name': 'A36',      'data': [180, 195, 188, 210, 225, 238, 245, 260, 270, 282, 295, 310]},
          {'name': 'A572-50',  'data': [85, 92, 88, 98, 105, 110, 115, 122, 128, 135, 140, 148]},
          {'name': 'A992',     'data': [42, 48, 45, 52, 55, 58, 62, 65, 68, 72, 76, 80]},
          {'name': 'A500-B/C', 'data': [35, 38, 40, 42, 45, 48, 50, 54, 56, 60, 62, 66]},
          {'name': '304/304L', 'data': [28, 30, 32, 35, 38, 40, 42, 45, 48, 50, 52, 55]},
          {'name': 'A1011',    'data': [22, 25, 24, 28, 30, 32, 34, 36, 38, 40, 42, 45]},
          {'name': '6061-T6',  'data': [15, 18, 16, 20, 22, 24, 25, 28, 30, 32, 34, 36]},
        ],
        '_labels': _months12,
        '_yLabel': isDollar ? 'Revenue (\$K)' : 'Orders',
        '_col1': 'Grade',
        '_col2': isDollar ? 'Revenue' : 'Orders',
        '_unit': isDollar ? '\$K' : '',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── COMPANY-BASED WIDGETS (multi-series by buyer) ────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('company') || n.contains('buyer') || n.contains('customer')) {
      final isDollar = n.contains('revenue') || n.contains('sales') || n.contains('spend');
      return {
        '_multiSeries': [
          {'name': 'Precision Metal Works', 'data': [85, 92, 88, 98, 105, 110, 115, 122, 128, 135, 140, 148]},
          {'name': 'Summit Steel Fab.',     'data': [72, 78, 75, 82, 88, 92, 95, 100, 105, 110, 115, 120]},
          {'name': 'Coastal Mfg Group',     'data': [55, 60, 58, 65, 68, 72, 75, 80, 84, 88, 92, 96]},
          {'name': 'Allied Machining',      'data': [42, 45, 48, 50, 54, 56, 58, 62, 65, 68, 70, 74]},
          {'name': 'Metro Industrial',      'data': [35, 38, 36, 40, 42, 45, 48, 50, 52, 55, 58, 62]},
          {'name': 'Pacific Fabrication',   'data': [28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50]},
          {'name': 'Titan Metals',          'data': [20, 22, 24, 25, 28, 30, 32, 34, 36, 38, 40, 42]},
          {'name': 'Westside Welding',      'data': [15, 16, 18, 20, 22, 24, 25, 28, 30, 32, 34, 36]},
        ],
        '_labels': _months12,
        '_yLabel': isDollar ? 'Revenue (\$K)' : 'Orders',
        '_col1': 'Company',
        '_col2': isDollar ? 'Revenue' : 'Orders',
        '_unit': isDollar ? '\$K' : '',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── BRACKET-BASED WIDGETS (pricing brackets 1–6) ─────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('bracket')) {
      return {
        '_multiSeries': [
          {'name': 'Bracket 1', 'data': [180, 195, 188, 210, 225, 238, 245, 260, 270, 282, 295, 310]},
          {'name': 'Bracket 2', 'data': [120, 128, 125, 135, 142, 148, 155, 162, 168, 175, 182, 190]},
          {'name': 'Bracket 3', 'data': [85, 92, 88, 95, 100, 105, 110, 115, 120, 125, 130, 138]},
          {'name': 'Bracket 4', 'data': [55, 58, 60, 62, 65, 68, 72, 75, 78, 82, 85, 90]},
          {'name': 'Bracket 5', 'data': [32, 35, 34, 38, 40, 42, 45, 48, 50, 52, 55, 58]},
          {'name': 'Bracket 6', 'data': [15, 18, 16, 20, 22, 24, 25, 28, 30, 32, 34, 36]},
        ],
        '_labels': _months12,
        '_yLabel': 'Orders',
        '_col1': 'Bracket',
        '_col2': 'Orders',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── SEARCH WIDGETS ───────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('search')) {
      if (n.contains('most') || n.contains('top')) {
        return {
          '_labels': ['A36 Flat Bar', 'A572 Plate', 'A500 HSS', '304L Sheet', 'A36 Angle', 'A992 Beam', 'A36 Channel', '6061 Plate', 'A1011 Coil'],
          '_data': [3420, 2815, 2340, 1980, 1750, 1520, 1280, 1050, 890],
          '_yLabel': 'Searches',
          '_col1': 'Product',
          '_col2': 'Searches',
          '_timeRange': 'Last 12 months',
        };
      }
      if (n.contains('least')) {
        return {
          '_labels': ['316L Pipe 6"', '6061 Bar 3"', 'A653 Sheet 20ga', '3003 Plate 1/2"', 'A500 HSS 8x8', '304L Coil 16ga', 'A572 Bar 4"', 'A36 Beam W4x13'],
          '_data': [12, 18, 24, 32, 38, 45, 52, 68],
          '_yLabel': 'Searches',
          '_col1': 'Product',
          '_col2': 'Searches',
          '_timeRange': 'Last 12 months',
        };
      }
      // Search volume by company — multi-series
      return {
        '_multiSeries': [
          {'name': 'Precision Metal Works', 'data': [420, 445, 460, 480, 510, 535, 560, 585, 610, 640, 668, 700]},
          {'name': 'Summit Steel Fab.',     'data': [320, 335, 350, 368, 385, 400, 418, 435, 455, 472, 490, 510]},
          {'name': 'Coastal Mfg Group',     'data': [245, 258, 270, 285, 298, 312, 325, 340, 355, 368, 382, 398]},
          {'name': 'Allied Machining',      'data': [180, 192, 200, 212, 225, 235, 248, 260, 272, 285, 298, 312]},
          {'name': 'Metro Industrial',      'data': [145, 152, 160, 168, 178, 188, 195, 205, 215, 225, 235, 245]},
        ],
        '_labels': _months12,
        '_yLabel': 'Searches',
        '_col1': 'Company',
        '_col2': 'Searches',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── QUOTE WIDGETS ────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('quote')) {
      if (n.contains('conversion') || n.contains('rate')) {
        return {
          '_labels': _months12,
          '_data': [62, 64, 61, 66, 68, 65, 69, 71, 73, 70, 74, 76],
          '_yLabel': 'Conversion %',
          '_unit': '%',
          '_col1': 'Month',
          '_col2': 'Conversion Rate',
          '_timeRange': 'Last 12 months',
        };
      }
      if (n.contains('aging') || n.contains('expired') || n.contains('lost')) {
        return {
          '_labels': ['0-7 days', '8-14 days', '15-30 days', '31-60 days', '60+ days'],
          '_data': [145, 98, 72, 45, 28],
          '_yLabel': 'Quotes',
          '_col1': 'Age Bucket',
          '_col2': 'Count',
          '_timeRange': 'Last 12 months',
        };
      }
      // Quotes by company — multi-series
      return {
        '_multiSeries': [
          {'name': 'Precision Metal Works', 'data': [32, 35, 38, 40, 42, 45, 48, 50, 52, 55, 58, 62]},
          {'name': 'Summit Steel Fab.',     'data': [25, 28, 26, 30, 32, 34, 36, 38, 40, 42, 44, 48]},
          {'name': 'Coastal Mfg Group',     'data': [18, 20, 22, 24, 25, 28, 30, 32, 34, 35, 38, 40]},
          {'name': 'Allied Machining',      'data': [14, 15, 16, 18, 20, 22, 24, 25, 26, 28, 30, 32]},
          {'name': 'Metro Industrial',      'data': [10, 12, 11, 14, 15, 16, 18, 20, 22, 24, 25, 28]},
        ],
        '_labels': _months12,
        '_yLabel': 'Quotes',
        '_col1': 'Company',
        '_col2': 'Quotes',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── PURCHASE / PO WIDGETS ────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('purchase') || n.contains('po ')) {
      if (n.contains('conversion') || n.contains('rate')) {
        return {
          '_labels': _months12,
          '_data': [82, 84, 80, 86, 88, 85, 89, 90, 87, 91, 92, 93],
          '_yLabel': 'Conversion %',
          '_unit': '%',
          '_col1': 'Month',
          '_col2': 'Conversion Rate',
          '_timeRange': 'Last 12 months',
        };
      }
      return {
        '_multiSeries': [
          {'name': 'Precision Metal Works', 'data': [22, 25, 24, 28, 30, 32, 34, 36, 38, 40, 42, 45]},
          {'name': 'Summit Steel Fab.',     'data': [18, 20, 19, 22, 24, 25, 28, 30, 32, 34, 35, 38]},
          {'name': 'Coastal Mfg Group',     'data': [14, 15, 16, 18, 20, 22, 24, 25, 26, 28, 30, 32]},
          {'name': 'Allied Machining',      'data': [10, 12, 11, 14, 15, 16, 18, 20, 22, 24, 25, 28]},
          {'name': 'Metro Industrial',      'data': [8, 9, 10, 11, 12, 14, 15, 16, 18, 20, 22, 24]},
        ],
        '_labels': _months12,
        '_yLabel': 'POs',
        '_col1': 'Company',
        '_col2': 'Purchase Orders',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── ORDER MANAGEMENT WIDGETS ─────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('order')) {
      if (n.contains('cancel')) {
        return {
          '_multiSeries': [
            {'name': 'Precision Metal Works', 'data': [2, 1, 3, 1, 2, 1, 2, 3, 1, 2, 1, 2]},
            {'name': 'Summit Steel Fab.',     'data': [1, 2, 1, 2, 1, 3, 1, 2, 2, 1, 2, 1]},
            {'name': 'Coastal Mfg Group',     'data': [1, 0, 1, 1, 2, 1, 1, 0, 1, 2, 1, 1]},
            {'name': 'Allied Machining',      'data': [0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1]},
          ],
          '_labels': _months12,
          '_yLabel': 'Cancellations',
          '_col1': 'Company',
          '_col2': 'Cancelled Orders',
          '_timeRange': 'Last 12 months',
        };
      }
      if (n.contains('status')) {
        return {
          '_labels': ['Processing', 'Shipped', 'Delivered', 'Partial Ship', 'Back-ordered', 'Cancelled'],
          '_data': [45, 82, 210, 18, 12, 8],
          '_yLabel': 'Orders',
          '_col1': 'Status',
          '_col2': 'Count',
          '_timeRange': 'Last 12 months',
        };
      }
      if (n.contains('volume') || n.contains('trend')) {
        return {
          '_labels': _months12,
          '_data': [312, 328, 345, 361, 378, 402, 415, 438, 455, 472, 490, 510],
          '_yLabel': 'Orders',
          '_col1': 'Month',
          '_col2': 'Orders',
          '_timeRange': 'Last 12 months',
        };
      }
      return {
        '_labels': _months12,
        '_data': [312, 328, 345, 361, 378, 402, 415, 438, 455, 472, 490, 510],
        '_yLabel': 'Orders',
        '_col1': 'Month',
        '_col2': 'Orders',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── CHAT WIDGETS ─────────────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('chat')) {
      if (n.contains('response') || n.contains('duration')) {
        return {
          '_labels': _months12,
          '_data': [4.2, 3.8, 3.5, 3.9, 3.2, 3.0, 2.8, 2.6, 2.5, 2.3, 2.2, 2.0],
          '_yLabel': 'Avg Hours',
          '_unit': 'hrs',
          '_col1': 'Month',
          '_col2': 'Avg Response Time',
          '_timeRange': 'Last 12 months',
        };
      }
      return {
        '_labels': _months12,
        '_data': [285, 298, 312, 325, 340, 355, 368, 382, 395, 410, 425, 440],
        '_yLabel': 'Chats',
        '_col1': 'Month',
        '_col2': 'Orders with Chat',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── BPN (BUYER PART NUMBER) WIDGETS ──────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('bpn') || n.contains('buyer part')) {
      return {
        '_multiSeries': [
          {'name': 'Precision Metal Works', 'data': [120, 135, 148, 162, 178, 195, 210, 228, 245, 262, 280, 298]},
          {'name': 'Summit Steel Fab.',     'data': [85, 92, 100, 110, 118, 128, 138, 148, 158, 168, 178, 190]},
          {'name': 'Coastal Mfg Group',     'data': [62, 68, 75, 82, 88, 95, 102, 110, 118, 125, 132, 140]},
          {'name': 'Allied Machining',      'data': [45, 50, 55, 60, 65, 70, 76, 82, 88, 94, 100, 108]},
          {'name': 'Metro Industrial',      'data': [30, 34, 38, 42, 46, 50, 55, 60, 65, 70, 75, 80]},
        ],
        '_labels': _months12,
        '_yLabel': 'BPNs Added',
        '_col1': 'Company',
        '_col2': 'Buyer Part Numbers',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── BOM (BILL OF MATERIALS) WIDGETS ──────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('bom') || n.contains('bill of material')) {
      return {
        '_labels': _months12,
        '_data': [42, 48, 55, 52, 60, 65, 70, 78, 82, 88, 92, 98],
        '_yLabel': 'BOM Uploads',
        '_col1': 'Month',
        '_col2': 'Uploads',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── PRICING & MARGIN WIDGETS ─────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('price') || n.contains('margin') || n.contains('asp')) {
      if (n.contains('margin') && n.contains('shape')) {
        return {
          '_labels': _shapes,
          '_data': [22.5, 18.8, 24.2, 20.1, 19.5, 21.8, 23.4, 17.2, 25.1],
          '_yLabel': 'Margin %',
          '_unit': '%',
          '_col1': 'Shape',
          '_col2': 'Margin %',
          '_timeRange': 'Last 12 months',
        };
      }
      return {
        '_labels': _months12,
        '_data': [2.45, 2.52, 2.48, 2.58, 2.65, 2.72, 2.68, 2.78, 2.85, 2.92, 2.88, 2.95],
        '_yLabel': 'ASP (\$/lb)',
        '_unit': '\$/lb',
        '_col1': 'Month',
        '_col2': 'Avg Selling Price',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── FULFILLMENT & DELIVERY WIDGETS ───────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('delivery') || n.contains('fulfillment') || n.contains('otd') ||
        n.contains('lead time') || n.contains('return') || n.contains('claim')) {
      if (n.contains('lead time')) {
        return {
          '_labels': _months12,
          '_data': [5.2, 4.8, 5.0, 4.5, 4.2, 4.0, 3.8, 3.5, 3.2, 3.0, 2.8, 2.5],
          '_yLabel': 'Days',
          '_unit': 'days',
          '_col1': 'Month',
          '_col2': 'Avg Lead Time',
          '_timeRange': 'Last 12 months',
        };
      }
      if (n.contains('return') || n.contains('claim')) {
        return {
          '_labels': _months12,
          '_data': [8, 6, 9, 5, 7, 4, 6, 3, 5, 4, 3, 2],
          '_yLabel': 'Claims',
          '_col1': 'Month',
          '_col2': 'Returns/Claims',
          '_timeRange': 'Last 12 months',
        };
      }
      return {
        '_labels': _months12,
        '_data': [91, 92, 90, 93, 94, 92, 95, 94, 96, 95, 97, 96],
        '_yLabel': 'OTD %',
        '_unit': '%',
        '_col1': 'Month',
        '_col2': 'On-Time Rate',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── ENGAGEMENT / ADOPTION WIDGETS ────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('engagement') || n.contains('adoption') ||
        n.contains('retention') || n.contains('scorecard')) {
      return {
        '_multiSeries': [
          {'name': 'Precision Metal Works', 'data': [85, 88, 90, 92, 94, 95, 96, 97, 98, 98, 99, 99]},
          {'name': 'Summit Steel Fab.',     'data': [72, 75, 78, 80, 82, 84, 86, 88, 90, 91, 92, 94]},
          {'name': 'Coastal Mfg Group',     'data': [60, 62, 65, 68, 70, 72, 75, 78, 80, 82, 84, 86]},
          {'name': 'Allied Machining',      'data': [45, 48, 50, 52, 55, 58, 60, 62, 65, 68, 70, 72]},
          {'name': 'Metro Industrial',      'data': [30, 32, 35, 38, 40, 42, 45, 48, 50, 52, 55, 58]},
        ],
        '_labels': _months12,
        '_yLabel': 'Engagement Score',
        '_col1': 'Company',
        '_col2': 'Score',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── REVENUE / SALES — general (single-series over time) ──
    // ═══════════════════════════════════════════════════════════
    if (n.contains('revenue') || n.contains('sales')) {
      return {
        '_labels': _months12,
        '_data': [1800, 2100, 2400, 2300, 2700, 3000, 2900, 3200, 3100, 3500, 3700, 3900],
        '_yLabel': 'Revenue (\$K)',
        '_unit': '\$K',
        '_col1': 'Month',
        '_col2': 'Revenue',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── USER / LOGIN WIDGETS ─────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('user') || n.contains('login') || n.contains('registration')) {
      return {
        '_labels': _months12,
        '_data': [412, 428, 445, 460, 478, 495, 510, 532, 548, 565, 582, 600],
        '_yLabel': 'Users',
        '_col1': 'Month',
        '_col2': 'Active Users',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── CREDIT LINE WIDGETS ──────────────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('credit')) {
      return {
        '_labels': ['Available', '75-90% Used', '90-100% Used', 'Over Limit'],
        '_data': [120, 28, 12, 5],
        '_yLabel': 'Companies',
        '_col1': 'Status',
        '_col2': 'Companies',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── PRODUCT RUNNING LIST (table) ─────────────────────────
    // ═══════════════════════════════════════════════════════════
    if (n.contains('product') && (n.contains('list') || n.contains('running'))) {
      return {
        '_labels': ['A36 Flat Bar 1/4x2', 'A572 Plate 1/2', 'A500 HSS 4x4x1/4', '304L Sheet 16ga', 'A36 Angle 2x2x1/4', 'A992 Beam W8x31', 'A36 Channel C6x8.2'],
        '_data': [3420, 2815, 2340, 1980, 1750, 1520, 1280],
        '_yLabel': 'Count',
        '_col1': 'Product',
        '_col2': 'Total Activity',
        '_timeRange': 'Last 12 months',
      };
    }

    // ═══════════════════════════════════════════════════════════
    // ── FALLBACK — generic time series ───────────────────────
    // ═══════════════════════════════════════════════════════════
    return {
      '_labels': _months12,
      '_data': [145, 152, 138, 167, 159, 172, 180, 194, 205, 218, 230, 245],
      '_yLabel': 'Count',
      '_col1': 'Month',
      '_col2': 'Value',
      '_timeRange': 'Last 12 months',
    };
  }

  Future<void> _showAddWidgetDialog(String dashId) async {
    // Always re-fetch the library directly from Supabase when the dialog
    // opens. The FutureProvider cache can hold stale data after server-side
    // migrations (e.g. category renames), so we bypass it here to guarantee
    // the chip row and widget list reflect the current DB state.
    List<LibraryItem> items;
    try {
      items = await ref.read(repoProvider).listLibrary();
      // Refresh the shared provider so other screens benefit from the
      // updated payload too.
      ref.invalidate(libraryProvider);
    } catch (e) {
      debugPrint('[Optics] Error loading library: $e');
      items = ref.read(libraryProvider).valueOrNull ?? const [];
    }
    final widgetPresets = items.where((i) => i.kind == 'widget').toList();

    if (!mounted) return;
    final selected = await showDialog<LibraryItem>(
      context: context,
      builder: (_) => _AddWidgetDialog(presets: widgetPresets),
    );
    if (selected != null && mounted) {
      _addWidgetFromLibrary(selected, dashId);
    }
  }

  Future<void> _confirmRemoveWidget(WidgetModel w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: Text('Remove "${w.title}"?',
            style: const TextStyle(color: OpticsColors.textPrimary)),
        content: const Text(
          'This will remove the widget from this dashboard. You can re-add it any time from the Widget Library.',
          style: TextStyle(color: OpticsColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: OpticsColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Optimistically remove from local state.
    final previous = _widgets;
    setState(() {
      _widgets = _widgets.where((x) => x.id != w.id).toList();
      if (_selected?.id == w.id) _selected = null;
    });
    try {
      await ref.read(repoProvider).deleteWidget(w.id);
    } catch (e, st) {
      debugPrint('[Optics] Error deleting widget ${w.id}: $e\n$st');
      // Roll back the optimistic removal so the UI matches the DB.
      if (!mounted) return;
      setState(() {
        _widgets = previous;
      });
      showSecureErrorSnackBar(context, ref, 'Could not remove widget.', e);
    }
  }

  Future<void> _shareDashboard(String dashId, String dashName) async {
    final email = await _promptEmail(context, dashName);
    if (email == null || email.isEmpty) return;

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      messenger.showSnackBar(SnackBar(content: Text('Sharing dashboard with $email...', style: const TextStyle(color: Colors.white))));
      await ref.read(repoProvider).shareDashboard(dashId, email);
      messenger.showSnackBar(SnackBar(content: Text('Dashboard shared successfully with $email.', style: const TextStyle(color: Colors.white))));
    } catch (e) {
      if (mounted) showSecureErrorSnackBar(context, ref, 'Failed to share dashboard.', e);
    }
  }

  Future<String?> _promptEmail(BuildContext context, String dashName) {
    String val = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: Text('SHARE "${dashName.toUpperCase()}"', style: OpticsTextStyles.headingMd),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the email address of the user you want to share this dashboard with. They must already be an invited member of another tenant on the platform.',
              style: TextStyle(color: OpticsColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              autofocus: true,
              style: const TextStyle(color: OpticsColors.textPrimary),
              decoration: const InputDecoration(
                labelText: 'Email Address',
                hintText: 'user@example.com',
                border: OutlineInputBorder(),
              ),
              onChanged: (s) => val = s,
              onSubmitted: (_) => Navigator.pop(ctx, val),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, val),
            child: const Text('Share'),
          ),
        ],
      ),
    );
  }

  Future<void> _createDashboard() async {
    final name = await _promptName(context, 'New dashboard');
    if (name == null || name.isEmpty) return;
    try {
      final d = await ref.read(repoProvider).createDashboard(name);
      // Reset local widget state BEFORE switching so the new dashboard
      // doesn't briefly inherit the previous board's tiles during the
      // refetch round-trip.
      setState(() {
        _widgets = const [];
        _selected = null;
        _loadedDashId = d.id;
      });
      ref.read(activeDashboardIdProvider.notifier).state = d.id;
      ref.invalidate(dashboardsListProvider);
      debugPrint('[Optics] Created dashboard "$name" (${d.id})');
    } catch (e, st) {
      debugPrint('[Optics] Error creating dashboard: $e\n$st');
      if (!mounted) return;
      showSecureErrorSnackBar(context, ref, 'Could not create dashboard.', e);
    }
  }

  void _switchDashboard(String dashId) {
    ref.read(activeDashboardIdProvider.notifier).state = dashId;
    _loadWidgets(dashId);
    _configureAutoRefresh(dashId);
  }

  /// Read the dashboard's saved `refreshInterval` and start/stop a periodic
  /// timer that re-fetches all widgets at the chosen cadence.
  Future<void> _configureAutoRefresh(String dashId) async {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    try {
      final d = await ref.read(repoProvider).getDashboard(dashId);
      final interval = d.settings['refreshInterval'] as String? ?? 'off';
      final dur = _parseRefreshInterval(interval);
      if (dur != null) {
        _autoRefreshTimer = Timer.periodic(dur, (_) {
          if (!mounted) return;
          _loadWidgets(dashId);
        });
      }
    } catch (_) {}
  }

  /// Convert a refresh interval string to a Duration, or null for 'off'.
  static Duration? _parseRefreshInterval(String s) {
    switch (s) {
      case '1m':  return const Duration(minutes: 1);
      case '5m':  return const Duration(minutes: 5);
      case '15m': return const Duration(minutes: 15);
      case '30m': return const Duration(minutes: 30);
      default:    return null; // 'off' or unknown
    }
  }

  Future<void> _deleteDashboard(Dashboard d, List<Dashboard> allDashboards) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: const Text('Delete dashboard?',
            style: TextStyle(color: OpticsColors.textPrimary)),
        content: Text(
          'This will permanently delete "${d.name}" and all of its widgets. '
          'This cannot be undone.',
          style: const TextStyle(color: OpticsColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: OpticsColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx, rootNavigator: true).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: OpticsColors.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(repoProvider).deleteDashboard(d.id);
      // If we just deleted the active board, switch to another (or clear).
      final activeId = ref.read(activeDashboardIdProvider);
      if (activeId == d.id) {
        final next = allDashboards.firstWhere(
          (x) => x.id != d.id,
          orElse: () => d,
        );
        if (next.id != d.id) {
          ref.read(activeDashboardIdProvider.notifier).state = next.id;
          _loadWidgets(next.id);
        } else {
          setState(() {
            _widgets = const [];
            _selected = null;
            _loadedDashId = null;
          });
          ref.read(activeDashboardIdProvider.notifier).state = null;
        }
      }
      ref.invalidate(dashboardsListProvider);
    } catch (e, st) {
      debugPrint('[Optics] Error deleting dashboard: $e\n$st');
      if (!mounted) return;
      showSecureErrorSnackBar(context, ref, 'Could not delete dashboard.', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Whenever the active tenant changes, drop our cached per-dashboard
    // widget state so we don't end up showing widgets that belong to the
    // previous tenant (or pointing `dashId` at a dashboard the new tenant
    // can't see under RLS).
    ref.listen<String?>(activeTenantProvider, (prev, next) {
      if (prev == next) return;
      setState(() {
        _widgets = const [];
        _selected = null;
        _loadedDashId = null;
      });
      ref.read(activeDashboardIdProvider.notifier).state = null;
      ref.invalidate(dashboardsListProvider);
    });

    // `unwrapPrevious` keeps the last successful list visible while a
    // refresh / invalidate is in flight, so the screen never blanks out
    // to a bare spinner mid-create.
    final dashboards = ref.watch(dashboardsListProvider).unwrapPrevious();

    return dashboards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: SecureErrorText(
          genericMessage: 'Failed to load dashboards.',
          error: e,
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return _EmptyState(onCreate: _createDashboard);
        }

        // Pick active dashboard — but only if the stored id still exists
        // in the current tenant's dashboard list. Otherwise fall back to
        // the first dashboard so we never try to load widgets for a
        // dashboard that belongs to a different tenant.
        var activeDashId = ref.watch(activeDashboardIdProvider);
        final activeStillValid =
            activeDashId != null && items.any((d) => d.id == activeDashId);
        if (!activeStillValid) activeDashId = null;
        final dashId = activeDashId ?? items.first.id;

        // SYNCHRONOUSLY load widgets if we haven't loaded this dashboard yet
        if (_loadedDashId != dashId) {
          // Set provider synchronously (don't use post-frame callback)
          if (activeDashId == null) {
            // Schedule the provider update for after build
            Future.microtask(() {
              ref.read(activeDashboardIdProvider.notifier).state = dashId;
            });
          }
          // Load widgets into local state. Mark as loaded *before* awaiting
          // so we don't re-enter the fetch on every rebuild while the request
          // is in flight.
          _loadedDashId = dashId;
          _selected = null;
          _widgets = const [];
          _loadWidgets(dashId);
          _configureAutoRefresh(dashId);
        }

        final currentDash =
            items.firstWhere((d) => d.id == dashId, orElse: () => items.first);

        // IRONCLAD PERMISSION CHECK: Use the dashboard-specific provider
        // that checks BOTH tenant role AND dashboard ownership.
        // Shared dashboards are ALWAYS view-only.
        // Default to FALSE while loading — never allow edit access during async check.
        final canEdit = ref.watch(canEditDashboardProvider(currentDash)).valueOrNull ?? false;

        // Use preview override if set (during global settings dialog), else use saved setting
        final effectiveTheme = _themePreviewOverride ?? currentDash.settings['theme'];
        final isLightTheme = effectiveTheme == 'light';
        final chromeMuted = isLightTheme ? const Color(0xFF333333) : OpticsColors.textMuted;

        return Row(
          children: [
            // Main content area
            Expanded(
              child: ColoredBox(
                color: isLightTheme ? WidgetThemeColors.lightCanvasBg : Colors.transparent,
                child: Padding(
                padding: const EdgeInsets.all(OpticsSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header row
                    _HeaderBar(
                      dashboards: items,
                      current: currentDash,
                      isLightTheme: isLightTheme,
                      onSelect: (d) => _switchDashboard(d.id),
                      onCreate: _createDashboard,
                      onDelete: (d) => _deleteDashboard(d, items),
                      onSettings: () {
                        // Snapshot all widgets before opening dialog for Cancel revert
                        _globalSettingsOriginalWidgets = _widgets.map((w) => w.copyWith()).toList();
                        showDialog<bool>(
                          context: context,
                          builder: (_) => _DashboardSettingsDialog(
                            dashboardId: dashId,
                            onPreview: (settings) => _applyGlobalSettingsPreview(settings),
                          ),
                        ).then((applied) {
                          if (applied == true) {
                            // User clicked Apply — reload from DB and reconfigure
                            _loadWidgets(dashId);
                            _configureAutoRefresh(dashId);
                          } else {
                            // User clicked Cancel or closed dialog — revert to original
                            if (_globalSettingsOriginalWidgets != null) {
                              setState(() {
                                _widgets = _globalSettingsOriginalWidgets!;
                              });
                            }
                          }
                          // Clear preview overrides
                          setState(() {
                            _globalSettingsOriginalWidgets = null;
                            _themePreviewOverride = null;
                          });
                        });
                      },
                      onAddWidget: () => _showAddWidgetDialog(dashId),
                      onShare: () => _shareDashboard(dashId, currentDash.name),
                    ),
                    const SizedBox(height: OpticsSpacing.md),
                    // Widget count for debugging — tap to force-reload
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Text(
                            '${_widgets.length} widget${_widgets.length == 1 ? '' : 's'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: chromeMuted,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: _syncing
                                ? 'Incremental refresh in progress — only new/changed rows are pulled from the source'
                                : 'Refresh data from source (incremental)',
                            child: InkWell(
                              onTap: _syncing
                                  ? null
                                  : () => _manualSync(dashId),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                child: _syncing
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: OpticsColors.accentCyan,
                                        ),
                                      )
                                    : Icon(
                                        Icons.refresh,
                                        size: 14,
                                        color: chromeMuted,
                                      ),
                              ),
                            ),
                          ),
                          if (_syncing) ...[
                            const SizedBox(width: 10),
                            _SyncProgressLabel(
                              progress: _syncProgress,
                              fmt: _fmtDuration,
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Widget grid
                    Expanded(
                      child: _widgets.isEmpty
                          ? _EmptyDashboard(
                              onAdd: () => _showAddWidgetDialog(dashId),
                              dashboard: currentDash)
                          : CanvasZoom(
                              child: GestureDetector(
                                onTap: () {
                                  // Tapping outside reverts any uncommitted preview changes
                                  if (_selectedOriginal != null) {
                                    final idx = _widgets.indexWhere((x) => x.id == _selectedOriginal!.id);
                                    if (idx >= 0) {
                                      _widgets = List<WidgetModel>.from(_widgets)..[idx] = _selectedOriginal!;
                                    }
                                  }
                                  setState(() {
                                    _selected = null;
                                    _selectedOriginal = null;
                                  });
                                },
                                child: WidgetGrid(
                                  canEdit: canEdit,
                                  widgets: _widgets,
                                  selectedId: _selected,
                                  onSelect: (w) =>
                                      setState(() {
                                        _selected = w;
                                        _selectedOriginal = w; // Snapshot for Cancel revert
                                      }),
                                  onDelete: (w) => _confirmRemoveWidget(w),
                                  onChanged: (w) {
                                    // Update the widget in the list
                                    final idx =
                                        _widgets.indexWhere((x) => x.id == w.id);
                                    if (idx >= 0) {
                                      setState(() {
                                        _widgets = List<WidgetModel>.from(
                                            _widgets)
                                          ..[idx] = w;
                                      });
                                    }
                                    _persistWidget(w);
                                  },
                                  onSwap: (updatedList) {
                                    setState(() {
                                      _widgets = updatedList;
                                    });
                                    for (final w in updatedList) {
                                      _persistWidget(w);
                                    }
                                  },
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              ),
            ),
            // Widget settings panel (right side)
            if (_selected != null)
              WidgetSettingsPanel(
                widget: _selected!,
                onPreview: (preview) {
                  // Live preview: update widget in list without persisting
                  final idx = _widgets.indexWhere((x) => x.id == preview.id);
                  if (idx >= 0) {
                    setState(() {
                      _widgets = List<WidgetModel>.from(_widgets)..[idx] = preview;
                      _selected = preview; // Keep panel in sync
                    });
                  }
                },
                onCancel: () {
                  // Revert to original widget (before settings panel opened)
                  if (_selectedOriginal != null) {
                    final idx = _widgets.indexWhere((x) => x.id == _selectedOriginal!.id);
                    if (idx >= 0) {
                      setState(() {
                        _widgets = List<WidgetModel>.from(_widgets)..[idx] = _selectedOriginal!;
                      });
                    }
                  }
                  setState(() {
                    _selected = null;
                    _selectedOriginal = null;
                  });
                },
                onApply: (w) {
                  final idx = _widgets.indexWhere((x) => x.id == w.id);
                  if (idx >= 0) {
                    setState(() {
                      _widgets = List<WidgetModel>.from(_widgets)..[idx] = w;
                    });
                  }
                  _persistWidget(w);
                  setState(() {
                    _selected = null;
                    _selectedOriginal = null;
                  });
                },
              ),
          ],
        );
      },
    );
  }
}

// ─── Header Bar ──────────────────────────────────────────────────

class _HeaderBar extends ConsumerWidget {
  final List<Dashboard> dashboards;
  final Dashboard current;
  final bool isLightTheme;
  final ValueChanged<Dashboard> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<Dashboard> onDelete;
  final VoidCallback onSettings;
  final VoidCallback onAddWidget;
  final VoidCallback onShare;

  const _HeaderBar({
    required this.dashboards,
    required this.current,
    this.isLightTheme = false,
    required this.onSelect,
    required this.onCreate,
    required this.onDelete,
    required this.onSettings,
    required this.onAddWidget,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // IRONCLAD PERMISSION CHECK: Use the dashboard-specific provider
    // that checks BOTH tenant role AND dashboard ownership.
    // Shared dashboards are ALWAYS view-only.
    // Default to FALSE while loading — never allow edit access during async check.
    final canEdit = ref.watch(canEditDashboardProvider(current)).valueOrNull ?? false;
    final fg = isLightTheme ? const Color(0xFF111111) : OpticsColors.textSecondary;
    return Row(
      children: [
        Text(
          'DASHBOARD',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: fg,
          ),
        ),
        const SizedBox(width: 12),
        Container(width: 1, height: 24, color: isLightTheme ? const Color(0xFF777777) : OpticsColors.border),
        const SizedBox(width: 12),
        _DashboardSwitcher(
          dashboards: dashboards,
          current: current,
          onSelect: onSelect,
          onCreate: onCreate,
          onDelete: onDelete,
          canEdit: canEdit,
          isLightTheme: isLightTheme,
        ),
        const Spacer(),
        if (canEdit) ...[
          // Share Dashboard — Owner-only until security pipeline is hardened.
          // The dashboard owner (created_by) can share; others (Admin/Editor) cannot.
          // This check is on top of the canEdit check above (which already requires
          // the user to own the dashboard).
          if (ref.watch(canOwnProvider)) ...[
            _ActionButton(
              icon: Icons.share_outlined,
              label: 'Share',
              onTap: onShare,
              isLightTheme: isLightTheme,
            ),
            const SizedBox(width: 8),
          ],
          _ActionButton(
            icon: Icons.tune_outlined,
            label: 'Settings',
            onTap: onSettings,
            isLightTheme: isLightTheme,
          ),
          const SizedBox(width: 8),
          _AddWidgetButton(onTap: onAddWidget),
        ],
      ],
    );
  }
}

// ─── Dashboard Switcher (dropdown) ────────────────────────────────

class _DashboardSwitcher extends StatelessWidget {
  final List<Dashboard> dashboards;
  final Dashboard current;
  final ValueChanged<Dashboard> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<Dashboard> onDelete;
  final bool canEdit;

  final bool isLightTheme;

  const _DashboardSwitcher({
    required this.dashboards,
    required this.current,
    required this.onSelect,
    required this.onCreate,
    required this.onDelete,
    this.canEdit = true,
    this.isLightTheme = false,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (id) {
        if (id == '__new__') {
          onCreate();
        } else if (id.startsWith('__del__:')) {
          final delId = id.substring('__del__:'.length);
          final d = dashboards.firstWhere((d) => d.id == delId);
          onDelete(d);
        } else {
          final d = dashboards.firstWhere((d) => d.id == id);
          onSelect(d);
        }
      },
      color: OpticsColors.surface,
      offset: const Offset(0, 36),
      itemBuilder: (_) => [
        for (final d in dashboards)
          PopupMenuItem(
            value: d.id,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            child: Row(
              children: [
                if (d.id == current.id)
                  const Icon(Icons.check,
                      size: 14, color: OpticsColors.accentCyan)
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    d.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: d.id == current.id
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: d.id == current.id
                          ? OpticsColors.accentCyan
                          : OpticsColors.textPrimary,
                    ),
                  ),
                ),
                // Inline delete affordance — pops the menu first, then
                // dispatches a "__del__:<id>" selection so the parent
                // surface can confirm + delete. Hidden for viewers.
                if (canEdit)
                  Tooltip(
                    message: 'Delete dashboard',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () {
                        Navigator.of(context).pop('__del__:${d.id}');
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(6),
                        child: Icon(Icons.delete_outline,
                            size: 14, color: OpticsColors.textMuted),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (canEdit) const PopupMenuDivider(),
        if (canEdit)
          const PopupMenuItem(
            value: '__new__',
            child: Row(
              children: [
                Icon(Icons.add, size: 14, color: OpticsColors.accentCyan),
                SizedBox(width: 8),
                Text('New dashboard',
                    style: TextStyle(
                        fontSize: 13, color: OpticsColors.accentCyan)),
              ],
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            current.name,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isLightTheme ? const Color(0xFF111111) : OpticsColors.textPrimary,
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.keyboard_arrow_down,
              size: 18, color: isLightTheme ? const Color(0xFF111111) : OpticsColors.textSecondary),
        ],
      ),
    );
  }
}

// ─── Small action button ──────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isLightTheme;
  const _ActionButton(
      {required this.icon, required this.label, required this.onTap, this.isLightTheme = false});

  @override
  Widget build(BuildContext context) {
    final fg = isLightTheme ? const Color(0xFF111111) : OpticsColors.textSecondary;
    final borderClr = isLightTheme ? const Color(0xFF777777) : OpticsColors.border;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: borderClr),
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12, color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Add Widget Button ────────────────────────────────────────────

class _AddWidgetButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddWidgetButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: OpticsColors.accentCyan,
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 14, color: Colors.black),
              SizedBox(width: 6),
              Text(
                'Add Widget',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Add Widget Dialog (Library Browser) ──────────────────────────

class _AddWidgetDialog extends StatefulWidget {
  final List<LibraryItem> presets;
  const _AddWidgetDialog({required this.presets});
  @override
  State<_AddWidgetDialog> createState() => _AddWidgetDialogState();
}

class _AddWidgetDialogState extends State<_AddWidgetDialog> {
  String _search = '';
  String _category = 'All';

  // Display labels for raw category ids (DB stores lowercase).
  // Acronyms are uppercased; everything else is Title Case.
  static const Map<String, String> _categoryLabels = {
    'executive':  'Executive',
    'engagement': 'Engagement',
    'users':      'Users',
    'searches':   'Searches',
    'quoting':    'Quoting',
    'orders':     'Orders',
    'bom':        'BOM',
    'part#':      'Part#',
    'custom':     'Custom',
  };

  // Display order — left to right as specified.
  static const List<String> _categoryOrder = [
    'executive', 'engagement', 'users', 'searches',
    'quoting', 'orders', 'bom', 'part#',
  ];

  String _labelFor(String raw) =>
      _categoryLabels[raw.toLowerCase()] ??
      (raw.isEmpty ? raw : '${raw[0].toUpperCase()}${raw.substring(1)}');

  List<String> get _categories {
    final raw = widget.presets.map((i) => i.category.toLowerCase()).toSet();
    final ordered = <String>[];
    for (final c in _categoryOrder) {
      if (raw.contains(c)) ordered.add(c);
    }
    // Append any unknown categories (alphabetical) so nothing is lost.
    final remaining = raw.difference(_categoryOrder.toSet()).toList()..sort();
    ordered.addAll(remaining);
    return ['All', ...ordered];
  }

  List<LibraryItem> get _filtered {
    var items = widget.presets;
    if (_category != 'All') {
      items = items
          .where((i) => i.category.toLowerCase() == _category.toLowerCase())
          .toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      items = items
          .where((i) =>
              i.name.toLowerCase().contains(q) ||
              (i.description ?? '').toLowerCase().contains(q) ||
              i.tags.any((t) => t.toLowerCase().contains(q)))
          .toList();
    }
    return items;
  }

  IconData _iconForType(String? type) => switch (type) {
        'kpi' => Icons.pin_outlined,
        'line' => Icons.show_chart,
        'barVertical' => Icons.bar_chart,
        'barHorizontal' => Icons.align_horizontal_left,
        'barStacked' => Icons.stacked_bar_chart,
        'barGrouped' => Icons.bar_chart_outlined,
        'combo' => Icons.stacked_line_chart,
        'pie' => Icons.pie_chart_outline,
        'donut' => Icons.donut_large,
        'table' => Icons.table_chart_outlined,
        'map' => Icons.map_outlined,
        'markdown' => Icons.text_fields,
        _ => Icons.widgets_outlined,
      };

  Color _colorForCategory(String cat) => switch (cat.toLowerCase()) {
        'executive'   => const Color(0xFFF43F5E),
        'engagement'  => const Color(0xFF818CF8),
        'users'       => const Color(0xFF38BDF8),
        'searches'    => const Color(0xFFA78BFA),
        'quoting'     => const Color(0xFFFBBF24),
        'orders'      => const Color(0xFF34D399),
        'bom'         => const Color(0xFFE879F9),
        'part#'       => const Color(0xFFF97316),
        'custom'      => OpticsColors.textSecondary,
        _ => OpticsColors.textSecondary,
      };

  String _typeLabel(String t) => switch (t) {
        'kpi' => 'KPI',
        'line' => 'Line',
        'barVertical' => 'Bar',
        'barHorizontal' => 'Bar (H)',
        'barStacked' => 'Stacked',
        'barGrouped' => 'Grouped',
        'combo' => 'Combo',
        'pie' => 'Pie',
        'donut' => 'Donut',
        'table' => 'Table',
        'map' => 'Map',
        'markdown' => 'Text',
        _ => t,
      };

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Dialog(
      backgroundColor: OpticsColors.surface,
      child: SizedBox(
        width: 680,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  const Icon(Icons.widgets_outlined,
                      size: 18, color: OpticsColors.accentCyan),
                  const SizedBox(width: 8),
                  const Text('ADD WIDGET',
                      style: OpticsTextStyles.sectionLabel),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Search bar
              TextField(
                onChanged: (v) => setState(() => _search = v),
                style: const TextStyle(
                    fontSize: 13, color: OpticsColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search widgets...',
                  hintStyle: const TextStyle(
                      color: OpticsColors.textMuted, fontSize: 13),
                  prefixIcon: const Icon(Icons.search,
                      size: 16, color: OpticsColors.textMuted),
                  filled: true,
                  fillColor: OpticsColors.canvas,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    borderSide:
                        const BorderSide(color: OpticsColors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    borderSide:
                        const BorderSide(color: OpticsColors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                    borderSide:
                        const BorderSide(color: OpticsColors.accentCyan),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Category chips
              SizedBox(
                height: 32,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final cat in _categories)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => setState(() => _category = cat),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: _category == cat
                                  ? OpticsColors.accentCyan
                                      .withValues(alpha: 0.15)
                                  : OpticsColors.surfaceElevated,
                              borderRadius:
                                  BorderRadius.circular(OpticsRadii.sm),
                              border: Border.all(
                                color: _category == cat
                                    ? OpticsColors.accentCyan
                                    : OpticsColors.border,
                              ),
                            ),
                            child: Text(
                              cat == 'All' ? 'All' : _labelFor(cat),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: _category == cat
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: _category == cat
                                    ? OpticsColors.accentCyan
                                    : OpticsColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${filtered.length} widget${filtered.length == 1 ? '' : 's'}',
                style: const TextStyle(
                    fontSize: 12, color: OpticsColors.textMuted),
              ),
              const SizedBox(height: 8),
              // Widget list
              Expanded(
                child: filtered.isEmpty
                    ? const Center(
                        child: Text(
                          'No matching widgets',
                          style: TextStyle(
                              color: OpticsColors.textMuted, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final item = filtered[i];
                          final typeStr =
                              item.payload['type'] as String? ?? 'kpi';
                          final catColor =
                              _colorForCategory(item.category);
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => Navigator.pop(context, item),
                              borderRadius:
                                  BorderRadius.circular(OpticsRadii.sm),
                              hoverColor: OpticsColors.accentCyan
                                  .withValues(alpha: 0.06),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    vertical: 8, horizontal: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: catColor
                                            .withValues(alpha: 0.12),
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: Icon(
                                        _iconForType(typeStr),
                                        size: 18,
                                        color: catColor,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  OpticsColors.textPrimary,
                                            ),
                                          ),
                                          if (item.description != null)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(
                                                      top: 2),
                                              child: Text(
                                                item.description!,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: OpticsColors
                                                      .textMuted,
                                                ),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: catColor
                                            .withValues(alpha: 0.10),
                                        borderRadius:
                                            BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _labelFor(item.category),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: catColor,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: OpticsColors.surfaceElevated,
                                        borderRadius:
                                            BorderRadius.circular(4),
                                        border: Border.all(
                                            color: OpticsColors.border),
                                      ),
                                      child: Text(
                                        _typeLabel(typeStr),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color:
                                              OpticsColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty states ─────────────────────────────────────────────────

class _EmptyState extends ConsumerWidget {
  final VoidCallback onCreate;
  const _EmptyState({required this.onCreate});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No dashboards exist yet, so we check tenant-level edit permission.
    // Guests and viewers can never create dashboards.
    final canEdit = ref.watch(canEditProvider);
    return Center(
      child: OpticsCard(
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.dashboard_outlined,
                  color: OpticsColors.textMuted, size: 28),
              const SizedBox(height: 12),
              Text('No Dashboards Yet'.toUpperCase(),
                  style: OpticsTextStyles.headingMd),
              const SizedBox(height: 6),
              Text(
                canEdit
                    ? 'Create your first dashboard to start building widgets.'
                    : 'Your administrator has not created any dashboards yet.',
                textAlign: TextAlign.center,
                style: OpticsTextStyles.bodySm,
              ),
              if (canEdit) ...[
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New dashboard'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDashboard extends ConsumerWidget {
  final VoidCallback onAdd;
  final Dashboard dashboard;
  const _EmptyDashboard({required this.onAdd, required this.dashboard});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // IRONCLAD PERMISSION CHECK: Use the dashboard-specific provider
    // that checks BOTH tenant role AND dashboard ownership.
    // Shared dashboards are ALWAYS view-only.
    // Default to FALSE while loading — never allow edit access during async check.
    final canEdit = ref.watch(canEditDashboardProvider(dashboard)).valueOrNull ?? false;
    return Center(
      child: OpticsCard(
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.widgets_outlined,
                  color: OpticsColors.textMuted, size: 28),
              const SizedBox(height: 12),
              Text('Empty Dashboard'.toUpperCase(),
                  style: OpticsTextStyles.headingMd),
              const SizedBox(height: 6),
              Text(
                canEdit
                    ? 'Add your first widget to start building this dashboard.'
                    : 'This shared dashboard is currently empty.',
                textAlign: TextAlign.center,
                style: OpticsTextStyles.bodySm,
              ),
              if (canEdit) ...[
                const SizedBox(height: 16),
                _AddWidgetButton(onTap: onAdd),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Dashboard Settings Dialog ────────────────────────────────────

Future<String?> _promptName(BuildContext ctx, String title) async {
  final c = TextEditingController();
  return showDialog<String>(
    context: ctx,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: OpticsColors.surface,
      title: Text(title),
      content: TextField(
          controller: c,
          decoration: const InputDecoration(hintText: 'Name')),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel')),
        ElevatedButton(
            onPressed: () => Navigator.pop(dialogCtx, c.text.trim()),
            child: const Text('Create')),
      ],
    ),
  );
}

class _DashboardSettingsDialog extends ConsumerStatefulWidget {
  final String dashboardId;
  /// Called on every setting change for live preview; receives current settings map.
  final void Function(Map<String, dynamic> settings)? onPreview;
  const _DashboardSettingsDialog({required this.dashboardId, this.onPreview});
  @override
  ConsumerState<_DashboardSettingsDialog> createState() =>
      _DashboardSettingsDialogState();
}

class _DashboardSettingsDialogState
    extends ConsumerState<_DashboardSettingsDialog> {
  Map<String, dynamic> _s = {};
  Map<String, dynamic> _original = {};
  /// Snapshot of each widget's settings BEFORE any global override was applied.
  /// Keyed by widget id. Used by "Back to Original Format" to restore.
  Map<String, Map<String, dynamic>> _widgetOriginalSettings = {};
  bool _busy = true;
  bool _saving = false;
  String? _err;
  /// True when a previous global override has been applied (persisted) and
  /// widget snapshots are available for revert.
  bool _hasAppliedOverride = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ref.read(repoProvider).getDashboard(widget.dashboardId);
      final client = ref.read(supabaseProvider);
      final hasOverride = d.settings['_hasGlobalOverride'] == true;

      Map<String, Map<String, dynamic>> snap;

      if (hasOverride) {
        // A global override was previously applied. Use the PERSISTED
        // snapshot (the widget settings from BEFORE the override), not the
        // current widget rows (which already reflect the override).
        final raw = d.settings['_widgetSnapshots'];
        if (raw is Map && raw.isNotEmpty) {
          snap = raw.map((k, v) => MapEntry(
              k as String,
              Map<String, dynamic>.from((v as Map).cast<String, dynamic>())));
        } else {
          // Fallback: snapshot current state (shouldn't happen if _save works)
          snap = await _snapshotCurrentWidgets(client);
        }
      } else {
        // No override yet — snapshot the current widget settings so we can
        // revert to them after an Apply.
        snap = await _snapshotCurrentWidgets(client);
      }

      // The "original" dashboard settings are the ones WITHOUT the override
      // markers. When an override is active, strip those markers to get the
      // clean baseline.
      final originalSettings = Map<String, dynamic>.from(d.settings)
        ..remove('_hasGlobalOverride')
        ..remove('_widgetSnapshots');

      setState(() {
        _s = Map<String, dynamic>.from(d.settings);
        _original = originalSettings;
        _widgetOriginalSettings = snap;
        _hasAppliedOverride = hasOverride;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _err = e.toString();
        _busy = false;
      });
    }
  }

  Future<Map<String, Map<String, dynamic>>> _snapshotCurrentWidgets(
      dynamic client) async {
    final rows = await client
        .from('widgets')
        .select('id, settings')
        .eq('dashboard_id', widget.dashboardId);
    final snap = <String, Map<String, dynamic>>{};
    for (final row in (rows as List)) {
      snap[row['id'] as String] = Map<String, dynamic>.from(
          (row['settings'] as Map?)?.cast<String, dynamic>() ?? {});
    }
    return snap;
  }

  Future<void> _saveAndClose() async {
    setState(() => _saving = true);
    final client = ref.read(supabaseProvider);
    try {
      // Mark that a global override is in effect (for "Back to Original" button).
      final toSave = Map<String, dynamic>.from(_s);
      toSave['_hasGlobalOverride'] = true;
      // Persist the widget-level snapshots so a future session can still revert.
      toSave['_widgetSnapshots'] = _widgetOriginalSettings;

      // 1. Save global_settings on the dashboard row.
      await client
          .from('dashboards')
          .update({'global_settings': toSave}).eq('id', widget.dashboardId);

      // 2. Propagate relevant global settings to every widget in this dashboard.
      final keysToWrite = <String, dynamic>{};
      if (_s['colorScheme'] != null) keysToWrite['colorScheme'] = _s['colorScheme'];
      if (_s['theme'] != null)       keysToWrite['theme'] = _s['theme'];
      if (_s['timeRange'] != null)   keysToWrite['timeRange'] = _s['timeRange'];
      if (_s['showGridLines'] != null) keysToWrite['gridLines'] = _s['showGridLines'];
      if (_s['crossFilter'] != null) keysToWrite['crossFilter'] = _s['crossFilter'];

      if (keysToWrite.isNotEmpty) {
        final rows = await client
            .from('widgets')
            .select('id, settings')
            .eq('dashboard_id', widget.dashboardId);

        for (final row in (rows as List)) {
          final existing = Map<String, dynamic>.from(
              (row['settings'] as Map?)?.cast<String, dynamic>() ?? {});
          final merged = {...existing, ...keysToWrite};
          await client
              .from('widgets')
              .update({'settings': merged})
              .eq('id', row['id'] as String);
        }
      }

      // 3. Invalidate widget provider so the grid rebuilds with the new settings.
      ref.invalidate(dashboardWidgetsProvider(widget.dashboardId));
      // 4. Invalidate dashboard list so the chrome (background, text colors) updates.
      ref.invalidate(dashboardsListProvider);
    } catch (_) {}

    if (mounted) {
      setState(() => _saving = false);
      Navigator.pop(context, true); // Return true to indicate Apply was clicked
    }
  }

  Future<void> _resetToOriginal() async {
    setState(() => _saving = true);
    final client = ref.read(supabaseProvider);
    try {
      // Restore each widget's settings to its pre-override snapshot.
      for (final entry in _widgetOriginalSettings.entries) {
        await client
            .from('widgets')
            .update({'settings': entry.value})
            .eq('id', entry.key);
      }

      // Reset the dashboard-level global_settings to original (clean, no override markers).
      final restored = Map<String, dynamic>.from(_original);
      await client
          .from('dashboards')
          .update({'global_settings': restored})
          .eq('id', widget.dashboardId);

      // Invalidate so widgets re-render.
      ref.invalidate(dashboardWidgetsProvider(widget.dashboardId));
      // Also invalidate dashboard list so chrome reverts (background, text colors).
      ref.invalidate(dashboardsListProvider);
    } catch (_) {}

    if (mounted) {
      setState(() {
        _s = Map<String, dynamic>.from(_original);
        _saving = false;
        _hasAppliedOverride = false;
      });
      Navigator.pop(context, true); // Return true — this is also a persisted change
    }
  }

  void _set(String k, dynamic v) {
    print('[GlobalSettings] _set called: $k = $v');
    setState(() => _s[k] = v);
    print('[GlobalSettings] Calling onPreview with: $_s');
    widget.onPreview?.call(Map<String, dynamic>.from(_s));
    print('[GlobalSettings] onPreview called');
  }

  Widget _section(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label.toUpperCase(), style: OpticsTextStyles.sectionLabel),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  /// Capitalise the first letter of each chip label for display.
  String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  Widget _chips(List<String> opts, String key, {String? defaultV}) {
    final v = (_s[key] as String?) ?? defaultV ?? opts.first;
    return Wrap(
      spacing: 6,
      children: [
        for (final o in opts)
          GestureDetector(
            onTap: () => _set(key, o),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: v == o
                    ? OpticsColors.accentCyan.withValues(alpha: 0.12)
                    : OpticsColors.surfaceElevated,
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
                border: Border.all(
                  color:
                      v == o ? OpticsColors.accentCyan : OpticsColors.border,
                ),
              ),
              child: Text(
                _cap(o),
                style: TextStyle(
                  fontSize: 12,
                  color: v == o
                      ? OpticsColors.accentCyan
                      : OpticsColors.textPrimary,
                  fontWeight: v == o ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _toggle(String key, String label, {bool defaultV = false}) {
    final v = (_s[key] as bool?) ?? defaultV;
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: OpticsTextStyles.body),
      value: v,
      activeTrackColor: OpticsColors.accentCyan,
      onChanged: (nv) => _set(key, nv),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showRevert = _hasAppliedOverride;
    return Dialog(
      backgroundColor: OpticsColors.surface,
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('DASHBOARD SETTINGS',
                      style: OpticsTextStyles.sectionLabel),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_err!,
                      style: const TextStyle(color: OpticsColors.danger)),
                ),
              if (!_busy && _err == null) ...[
                _section(
                    'Color Scheme',
                    _chips(
                      const ['default', 'cool', 'warm', 'mono', 'neon'],
                      'colorScheme',
                      defaultV: 'default',
                    )),
                _section(
                    'Theme',
                    _chips(const ['dark', 'light'], 'theme',
                        defaultV: 'dark')),
                _section(
                  'Default Time Range',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TimeRangePicker(
                      value: (_s['timeRange'] as String?) ?? kDefaultTimeRange,
                      onChanged: (v) => _set('timeRange', v),
                    ),
                  ),
                ),
                _section(
                    'Auto-Refresh',
                    _chips(
                      const ['off', '1m', '5m', '15m', '30m'],
                      'refreshInterval',
                      defaultV: 'off',
                    )),
                _toggle('crossFilter', 'Cross-Widget Filtering',
                    defaultV: true),
                _toggle('showGridLines', 'Show Grid Lines', defaultV: true),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (showRevert)
                    TextButton.icon(
                      icon: const Icon(Icons.undo, size: 14),
                      label: const Text('Back to Original Format'),
                      style: TextButton.styleFrom(
                        foregroundColor: OpticsColors.accentOrange,
                      ),
                      onPressed: _saving ? null : _resetToOriginal,
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: (_busy || _saving) ? null : _saveAndClose,
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline label that renders "12/72 tables (16%) · 0:34 elapsed · ~1:22 left"
/// next to the dashboard refresh spinner. When `progress` is null (sync just
/// kicked off, no rows yet) shows "Starting…".
class _SyncProgressLabel extends StatelessWidget {
  final Map<String, dynamic>? progress;
  final String Function(int ms) fmt;
  const _SyncProgressLabel({required this.progress, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final p = progress;
    String text;
    if (p == null || (p['total'] as int? ?? 0) == 0) {
      text = 'Starting…';
    } else {
      final total = p['total'] as int;
      final done = (p['completed'] as int) + (p['errored'] as int);
      final elapsed = p['elapsed_ms'] as int? ?? 0;
      final eta = p['eta_ms'] as int?;
      final pct = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
      final pctStr = ' (${(pct * 100).round()}%)';
      final etaStr = eta != null ? ' · ~${fmt(eta)} left' : '';
      text = '$done/$total tables$pctStr · ${fmt(elapsed)} elapsed$etaStr';
    }
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: OpticsColors.textMuted,
      ),
    );
  }
}
