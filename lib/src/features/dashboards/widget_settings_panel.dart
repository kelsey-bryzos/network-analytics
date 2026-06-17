import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../design/theme.dart';
import 'time_range_options.dart';
import 'time_range_picker.dart';

/// The two-page per-widget settings panel that matches the spec mockups.
/// Page 1: Title · Chart Type · Color Scheme · Group By · Sort By · Time Range.
/// Page 2: Data Filters · Max Items · Display toggles · Auto-Refresh.
/// Footer: Reset / Cancel / Apply.
///
/// **Reset** restores the widget to its ORIGINAL state (when the panel was opened),
/// not to arbitrary defaults.
class WidgetSettingsPanel extends StatefulWidget {
  final WidgetModel widget;
  final void Function(WidgetModel updated) onApply;
  final VoidCallback onCancel;
  const WidgetSettingsPanel({
    super.key,
    required this.widget,
    required this.onApply,
    required this.onCancel,
  });

  @override
  State<WidgetSettingsPanel> createState() => _WidgetSettingsPanelState();
}

class _WidgetSettingsPanelState extends State<WidgetSettingsPanel> {
  late TextEditingController _title;
  late WidgetKind _kind;
  late String _colorScheme;
  late String _groupBy;
  late String _sortBy;
  late String _timeRange;
  late int _maxItems;
  late String _autoRefresh;
  late String _barOrientation;
  late Map<String, bool> _toggles;
  late Map<String, bool> _filters;
  int _page = 0;

  // ── Original values (for Reset) ──
  late final String _origTitle;
  late final WidgetKind _origKind;
  late final String _origColorScheme;
  late final String _origGroupBy;
  late final String _origSortBy;
  late final String _origTimeRange;
  late final int _origMaxItems;
  late final String _origAutoRefresh;
  late final String _origBarOrientation;
  late final Map<String, bool> _origToggles;
  late final Map<String, bool> _origFilters;

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
    _origAutoRefresh = s['autoRefresh'] as String? ?? 'Off';
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

    // Set current values
    _title = TextEditingController(text: _origTitle);
    _kind = _origKind;
    _colorScheme = _origColorScheme;
    _groupBy = _origGroupBy;
    _sortBy = _origSortBy;
    _timeRange = _origTimeRange;
    _maxItems = _origMaxItems;
    _autoRefresh = _origAutoRefresh;
    _barOrientation = _origBarOrientation;
    _toggles = Map<String, bool>.from(_origToggles);
    _filters = Map<String, bool>.from(_origFilters);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _apply() {
    final updated = widget.widget.copyWith(
      title: _title.text.trim().isEmpty ? widget.widget.title : _title.text.trim(),
      kind: _kind,
      settings: {
        ...widget.widget.settings,
        'colorScheme': _colorScheme,
        'groupBy': _groupBy,
        'sortBy': _sortBy,
        'timeRange': _timeRange,
        'maxItems': _maxItems,
        'autoRefresh': _autoRefresh,
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
    widget.onApply(updated);
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
      _maxItems = _origMaxItems;
      _autoRefresh = _origAutoRefresh;
      _barOrientation = _origBarOrientation;
      _toggles = Map<String, bool>.from(_origToggles);
      _filters = Map<String, bool>.from(_origFilters);
    });
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
          _PageTabs(page: _page, onChange: (p) => setState(() => _page = p)),
          Expanded(
            child: SingleChildScrollView(
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
          options: const [
            ('KPI', WidgetKind.kpi),
            ('Line', WidgetKind.line),
            ('Bar', WidgetKind.barVertical),
            ('Combo', WidgetKind.combo),
            ('Pie', WidgetKind.pie),
            ('Donut', WidgetKind.donut),
            ('Gauge', WidgetKind.gauge),
            ('Table', WidgetKind.table),
          ],
          value: _kind,
          onChanged: (v) => setState(() => _kind = v),
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
            onChanged: (v) => setState(() => _barOrientation = v),
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
          onChanged: (v) => setState(() => _colorScheme = v),
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
          onChanged: (v) => setState(() => _groupBy = v),
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
          onChanged: (v) => setState(() => _sortBy = v),
        ),
        _label('Default time range'),
        TimeRangePicker(
          value: _timeRange,
          onChanged: (v) => setState(() => _timeRange = v),
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
            onChanged: (v) => setState(() => _filters[entry.key] = v),
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
          onChanged: (v) => setState(() => _maxItems = v),
        ),
        _label('Display'),
        for (final entry in _toggles.entries)
          _ToggleRow(
            label: entry.key,
            value: entry.value,
            onChanged: (v) => setState(() => _toggles[entry.key] = v),
          ),
        _label('Auto-refresh'),
        _ChipGroup<String>(
          options: const [
            ('Off', 'Off'),
            ('1 m', '1 m'),
            ('5 m', '5 m'),
            ('15 m', '15 m'),
            ('30 m', '30 m'),
          ],
          value: _autoRefresh,
          onChanged: (v) => setState(() => _autoRefresh = v),
        ),
      ],
    );
  }
}

class _PageTabs extends StatelessWidget {
  final int page;
  final ValueChanged<int> onChange;
  const _PageTabs({required this.page, required this.onChange});
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
      child: Row(children: [tab(0, 'Basics'), tab(1, 'Data & Display')]),
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
