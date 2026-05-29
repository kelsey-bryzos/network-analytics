import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/canvas_zoom.dart';
import '../../design/theme.dart';
import 'time_range_options.dart';
import 'time_range_picker.dart';
import 'widget_grid.dart';
import 'widget_settings_panel.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  final String dashboardId;
  const DashboardScreen({super.key, required this.dashboardId});
  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  WidgetModel? _selected;

  void _refresh() {
    // ignore: unused_result
    ref.refresh(dashboardWidgetsProvider(widget.dashboardId));
  }

  Future<void> _addWidget(WidgetKind kind) async {
    await ref.read(repoProvider).createWidget(
          dashboardId: widget.dashboardId,
          title: _titleFor(kind),
          kind: kind,
          x: 0,
          y: 0,
          w: kind == WidgetKind.kpi ? 12 : 24,
          h: kind == WidgetKind.kpi ? 8 : 12,
        );
    _refresh();
  }

  String _titleFor(WidgetKind k) => switch (k) {
        WidgetKind.kpi => 'Key metric',
        WidgetKind.line => 'Trend',
        WidgetKind.barVertical => 'Bar chart',
        WidgetKind.barHorizontal => 'Bar (horizontal)',
        WidgetKind.barStacked => 'Bar (stacked)',
        WidgetKind.barGrouped => 'Bar (grouped)',
        WidgetKind.combo => 'Combo',
        WidgetKind.pie => 'Pie',
        WidgetKind.donut => 'Donut',
        WidgetKind.gauge => 'Gauge',
        WidgetKind.table => 'Table',
        WidgetKind.map => 'Map',
        WidgetKind.markdown => 'Note',
      };

  @override
  Widget build(BuildContext context) {
    final widgets = ref.watch(dashboardWidgetsProvider(widget.dashboardId));
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(OpticsSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('DASHBOARD', style: OpticsTextStyles.headingXl),
                    const Spacer(),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: const Text('Dashboard settings'),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _DashboardSettingsDialog(
                            dashboardId: widget.dashboardId),
                      ).then((_) => _refresh()),
                    ),
                    const SizedBox(width: 8),
                    _AddWidgetMenu(onAdd: _addWidget),
                  ],
                ),
                const SizedBox(height: OpticsSpacing.lg),
                Expanded(
                  child: widgets.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(
                      child: Text('$e',
                          style: const TextStyle(color: OpticsColors.danger)),
                    ),
                    data: (items) => CanvasZoom(
                      child: GestureDetector(
                        onTap: () => setState(() => _selected = null),
                        child: WidgetGrid(
                          widgets: items,
                          selectedId: _selected,
                          onSelect: (w) => setState(() => _selected = w),
                          onChanged: (w) async {
                            await ref.read(repoProvider).updateWidget(w);
                            _refresh();
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_selected != null)
          WidgetSettingsPanel(
            widget: _selected!,
            onCancel: () => setState(() => _selected = null),
            onApply: (w) async {
              await ref.read(repoProvider).updateWidget(w);
              setState(() => _selected = null);
              _refresh();
            },
          ),
      ],
    );
  }
}

class _DashboardSettingsDialog extends ConsumerStatefulWidget {
  final String dashboardId;
  const _DashboardSettingsDialog({required this.dashboardId});
  @override
  ConsumerState<_DashboardSettingsDialog> createState() =>
      _DashboardSettingsDialogState();
}

class _DashboardSettingsDialogState
    extends ConsumerState<_DashboardSettingsDialog> {
  Map<String, dynamic> _s = {};
  Map<String, dynamic> _original = {};
  bool _busy = true;
  String? _err;
  bool _modified = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ref.read(repoProvider).getDashboard(widget.dashboardId);
      setState(() {
        _s = Map<String, dynamic>.from(d.settings);
        _original = Map<String, dynamic>.from(d.settings);
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _err = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _save() async {
    final client = ref.read(supabaseProvider);
    // 1. Save dashboard-level settings.
    await client
        .from('dashboards')
        .update({'settings': _s})
        .eq('id', widget.dashboardId);

    // 2. Apply global overrides to every widget so WidgetRenderer picks them up.
    final widgets = ref
        .read(dashboardWidgetsProvider(widget.dashboardId))
        .asData
        ?.value ?? [];
    final repo = ref.read(repoProvider);
    for (final w in widgets) {
      final patched = Map<String, dynamic>.from(w.settings);
      // Always write chosen values (even defaults), never skip.
      patched['colorScheme'] = _s['colorScheme'] ?? 'default';
      patched['timeRange']   = _s['timeRange']   ?? kDefaultTimeRange;
      if (_s['theme'] != null)         patched['theme'] = _s['theme'];
      if (_s['showGridLines'] != null) patched['gridLines'] = _s['showGridLines'];
      if (_s['crossFilter'] != null)   patched['crossFilter'] = _s['crossFilter'];
      await repo.updateWidget(w.copyWith(settings: patched));
    }
    // Invalidate provider so dashboard immediately re-renders with new settings.
    ref.invalidate(dashboardWidgetsProvider(widget.dashboardId));
    ref.invalidate(dashboardsListProvider);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _resetToOriginal() async {
    // Restore dashboard settings.
    final client = ref.read(supabaseProvider);
    await client
        .from('dashboards')
        .update({'settings': _original})
        .eq('id', widget.dashboardId);

    // Strip global overrides from every widget so they revert to their
    // individually-saved settings.
    final widgets = ref
        .read(dashboardWidgetsProvider(widget.dashboardId))
        .asData
        ?.value ?? [];
    final repo = ref.read(repoProvider);
    for (final w in widgets) {
      final patched = Map<String, dynamic>.from(w.settings)
        ..remove('colorScheme')
        ..remove('timeRange')
        ..remove('theme')
        ..remove('gridLines');
      await repo.updateWidget(w.copyWith(settings: patched));
    }
    // Invalidate so dashboard re-renders with restored settings.
    ref.invalidate(dashboardWidgetsProvider(widget.dashboardId));
    ref.invalidate(dashboardsListProvider);
    if (mounted) {
      setState(() {
        _s = Map<String, dynamic>.from(_original);
        _modified = false;
      });
      Navigator.pop(context);
    }
  }

  void _set(String k, dynamic v) => setState(() {
        _s[k] = v;
        _modified = true;
      });

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
                  color: v == o
                      ? OpticsColors.accentCyan
                      : OpticsColors.border,
                ),
              ),
              child: Text(
                o,
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
      activeColor: OpticsColors.accentCyan,
      onChanged: (nv) => _set(key, nv),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    'Color scheme',
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
                  'Default time range',
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TimeRangePicker(
                      value: (_s['timeRange'] as String?) ?? kDefaultTimeRange,
                      onChanged: (v) => _set('timeRange', v),
                    ),
                  ),
                ),
                _section(
                    'Auto-refresh',
                    _chips(
                      const ['off', '1m', '5m', '15m', '30m'],
                      'refreshInterval',
                      defaultV: 'off',
                    )),
                _toggle('crossFilter', 'Cross-widget filtering',
                    defaultV: true),
                _toggle('showGridLines', 'Show grid lines', defaultV: true),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_modified)
                    TextButton.icon(
                      icon: const Icon(Icons.undo, size: 14),
                      label: const Text('Back to Original Format'),
                      style: TextButton.styleFrom(
                        foregroundColor: OpticsColors.accentOrange,
                      ),
                      onPressed: _busy ? null : _resetToOriginal,
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Apply to All Widgets'),
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

class _AddWidgetMenu extends StatelessWidget {
  final void Function(WidgetKind) onAdd;
  const _AddWidgetMenu({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<WidgetKind>(
      onSelected: onAdd,
      color: OpticsColors.surface,
      itemBuilder: (_) => [
        for (final k in WidgetKind.values)
          PopupMenuItem(value: k, child: Text(_label(k))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: OpticsColors.accentCyan,
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: Colors.black),
            SizedBox(width: 6),
            Text(
              'Add Widget',
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _label(WidgetKind k) => switch (k) {
        WidgetKind.kpi => 'KPI Tile',
        WidgetKind.line => 'Line chart',
        WidgetKind.barVertical => 'Bar — vertical',
        WidgetKind.barHorizontal => 'Bar — horizontal',
        WidgetKind.barStacked => 'Bar — stacked',
        WidgetKind.barGrouped => 'Bar — grouped',
        WidgetKind.combo => 'Combo (dual-axis)',
        WidgetKind.pie => 'Pie',
        WidgetKind.donut => 'Donut',
        WidgetKind.gauge => 'Gauge',
        WidgetKind.table => 'Table',
        WidgetKind.map => 'Map',
        WidgetKind.markdown => 'Markdown / Text',
      };
}
