import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';
import '../../shared/secure_error.dart';
import '../dashboards/widget_renderer.dart';
import 'reports_list_screen.dart';

class SingleWidgetViewer extends ConsumerStatefulWidget {
  final Report report;
  final Map<String, dynamic> widgetData;
  final String tenantId;
  final String? dataSourceId;

  const SingleWidgetViewer({
    super.key,
    required this.report,
    required this.widgetData,
    required this.tenantId,
    required this.dataSourceId,
  });

  @override
  ConsumerState<SingleWidgetViewer> createState() => _SingleWidgetViewerState();
}

class _SingleWidgetViewerState extends ConsumerState<SingleWidgetViewer> {
  bool _isTableView = true;

  String? _resolveDataSourceId(Map<String, dynamic> w) {
    final binding = Map<String, dynamic>.from((w['binding'] as Map?) ?? const {});
    final brz = binding['brz'] is Map ? Map<String, dynamic>.from(binding['brz'] as Map) : null;
    final widgetBindingDsId = brz?['data_source_id'] as String?;

    final dsList = ref.watch(dataSourcesProvider).asData?.value ?? const <DataSource>[];
    final firstRestId = dsList.where((d) => d.kind == 'rest').map((d) => d.id).cast<String?>().firstWhere(
      (v) => v != null,
      orElse: () => null,
    );
    final firstAnyId = dsList.isNotEmpty ? dsList.first.id : null;

    return widgetBindingDsId ?? widget.dataSourceId ?? firstRestId ?? firstAnyId;
  }

  @override
  Widget build(BuildContext context) {
    final wTop = Map<String, dynamic>.from(widget.widgetData);
    final bindingTop = Map<String, dynamic>.from((wTop['binding'] as Map?) ?? const {});
    final brzTop = bindingTop['brz'] is Map ? Map<String, dynamic>.from(bindingTop['brz'] as Map) : null;
    final metricTop = brzTop?['metric'] as String? ?? '';
    final isTableOnly = wTop['type'] == 'table' && (
      metricTop.endsWith('_table') || 
      metricTop.endsWith('_list') || 
      metricTop.endsWith('_detail') || 
      metricTop.endsWith('_feed') || 
      metricTop.endsWith('_log')
    );
    final effectiveIsTableView = _isTableView || isTableOnly;
    final effectiveDataSourceId = _resolveDataSourceId(wTop);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Toolbar
        Row(
          children: [
            // Toggle
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
                    icon: Icons.table_chart_outlined,
                    label: 'Table View',
                    active: _isTableView,
                    onTap: () => setState(() => _isTableView = true),
                  ),
                  _toggleBtn(
                    icon: Icons.bar_chart,
                    label: 'Widget View',
                    active: !_isTableView,
                    onTap: () => setState(() => _isTableView = false),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // Export — available to all users (viewers can export)
            _toolbarBtn(
              icon: Icons.file_download_outlined,
              label: 'Export',
              onTap: () {
                exportReportHelper(context, ref, widget.report, 'xlsx');
              },
            ),
            // Share — Editors+ only (Guests/Viewers cannot share).
            // Hidden for canned reports (system-wide by default).
            if (!widget.report.isCanned && ref.watch(canEditProvider)) ...[
              const SizedBox(width: OpticsSpacing.sm),
              _toolbarBtn(
                icon: Icons.share_outlined,
                label: 'Share',
                onTap: () {
                  shareReportHelper(context, ref, widget.report);
                },
              ),
            ],
            // Add to Dashboard — Editors+ only (Guests/Viewers cannot add)
            if (!effectiveIsTableView && ref.watch(canEditProvider)) ...[
              const SizedBox(width: OpticsSpacing.sm),
              _AddToDashboardBtn(
                widgetData: widget.widgetData,
                report: widget.report,
                dataSourceId: effectiveDataSourceId,
              ),
            ],
          ],
        ),
        const SizedBox(height: OpticsSpacing.md),
        
        // Content Area
        Expanded(
          child: OpticsCard(
            padding: const EdgeInsets.all(0),
            child: _buildWidgetRenderer(),
          ),
        ),
      ],
    );
  }

  Widget _toggleBtn({required IconData icon, required String label, required bool active, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? OpticsColors.accentCyan.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? OpticsColors.accentCyan : OpticsColors.textSecondary),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? OpticsColors.accentCyan : OpticsColors.textPrimary,
            )),
          ],
        ),
      ),
    );
  }

  Widget _toolbarBtn({required IconData icon, required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: OpticsColors.surfaceElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: OpticsColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: OpticsColors.textSecondary),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: OpticsColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  Widget _buildWidgetRenderer() {
    final w = Map<String, dynamic>.from(widget.widgetData);
    final binding = Map<String, dynamic>.from((w['binding'] as Map?) ?? const {});
    final effectiveDataSourceId = _resolveDataSourceId(w);
    final brz = binding['brz'] is Map ? Map<String, dynamic>.from(binding['brz'] as Map) : null;
    final metric = brz?['metric'] as String? ?? '';
    final isTableOnly = w['type'] == 'table' && (
      metric.endsWith('_table') || 
      metric.endsWith('_list') || 
      metric.endsWith('_detail') || 
      metric.endsWith('_feed') || 
      metric.endsWith('_log')
    );
    final effectiveIsTableView = _isTableView || isTableOnly;

    
    String type = w['type'] as String? ?? 'kpi';
    if (effectiveIsTableView) {
      type = 'table';
    } else {
      if (metric == 'avg_order_price_trend') {
        type = 'line';
      } else if (type == 'table' || type == 'kpi') {
        type = 'barVertical';
      }
    }

    final kind = WidgetKind.fromString(type);
    final settings = Map<String, dynamic>.from((w['settings'] as Map?) ?? const {});
    if (metric == 'avg_order_price_trend') {
      settings['sortBy'] = 'None';
      settings['barOrientation'] = 'Vertical';
      settings['maxItems'] = 12;
    }

    if (binding['brz'] is Map && effectiveDataSourceId != null) {
      final brz = Map<String, dynamic>.from(binding['brz'] as Map);
      brz['data_source_id'] = effectiveDataSourceId;
      binding['brz'] = brz;
    }

    final model = WidgetModel(
      id: 'report-single-${w['title'] ?? type}',
      tenantId: widget.tenantId,
      dashboardId: '',
      title: w['title'] as String? ?? widget.report.name,
      kind: kind,
      x: 0,
      y: 0,
      w: 12,
      h: 6,
      binding: binding,
      settings: settings,
    );

    return WidgetRenderer(model: model);
  }
}

class _AddToDashboardBtn extends ConsumerStatefulWidget {
  final Map<String, dynamic> widgetData;
  final Report report;
  final String? dataSourceId;
  const _AddToDashboardBtn({
    required this.widgetData,
    required this.report,
    required this.dataSourceId,
  });
  @override
  ConsumerState<_AddToDashboardBtn> createState() => _AddToDashboardBtnState();
}

class _AddToDashboardBtnState extends ConsumerState<_AddToDashboardBtn> {
  bool _busy = false;

  void _add() async {
    final dashboards = await ref.read(dashboardsListProvider.future);
    if (!mounted) return;
    
    if (dashboards.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No dashboards found.')));
      return;
    }

    final selectedId = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: const Text('Add to Dashboard', style: TextStyle(color: OpticsColors.textPrimary)),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: dashboards.map((d) => ListTile(
              title: Text(d.name, style: const TextStyle(color: OpticsColors.textPrimary)),
              onTap: () => Navigator.pop(ctx, d.id),
            )).toList(),
          ),
        ),
      ),
    );

    if (selectedId == null) return;
    
    setState(() => _busy = true);
    try {
      final kindStr = widget.widgetData['type'] as String? ?? 'barVertical';
      final kind = WidgetKind.fromString(kindStr);
      final binding =
          Map<String, dynamic>.from((widget.widgetData['binding'] as Map?) ?? const {});
      if (binding['brz'] is Map && widget.dataSourceId != null) {
        final brz = Map<String, dynamic>.from(binding['brz'] as Map);
        brz['data_source_id'] = widget.dataSourceId;
        binding['brz'] = brz;
      }

      await ref.read(repoProvider).createWidget(
        dashboardId: selectedId,
        title: widget.widgetData['title'] as String? ?? widget.report.name,
        kind: kind,
        binding: binding,
        settings: widget.widgetData['settings'] as Map<String, dynamic>? ?? {},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to dashboard!')));
      }
    } catch (e) {
      if (mounted) {
        showSecureErrorSnackBar(context, ref, 'Failed to add widget.', e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _busy ? null : _add,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: OpticsColors.accentCyan,
          borderRadius: BorderRadius.circular(6),
        ),
        child: _busy
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
            : const Row(
                children: [
                  Icon(Icons.add, size: 14, color: Colors.black),
                  SizedBox(width: 6),
                  Text('Add to Dashboard', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black)),
                ],
              ),
      ),
    );
  }
}
