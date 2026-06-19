import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';
import '../../shared/secure_error.dart';
import '../dashboards/widget_renderer.dart';
import 'custom_builder/custom_report_query_v2.dart';
import 'custom_builder/v2_report_view.dart';
import 'single_widget_viewer.dart';

/// Read-only renderer for a canned or custom report. Pulls the report by id
/// (canned ids are prefixed `lib:<library_item_id>`), then renders each
/// page's widgets via [WidgetRenderer] — automatically inheriting Bryzos
/// live-data fetching by injecting the active tenant's REST data source id
/// into each widget's binding.
class ReportViewerScreen extends ConsumerWidget {
  final String reportId;
  const ReportViewerScreen({super.key, required this.reportId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_reportByIdProvider(reportId));
    return Padding(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: SecureErrorText(
            genericMessage: 'Could not load report.',
            error: e,
          ),
        ),
        data: (report) {
          if (report == null) {
            return _emptyState(
              context,
              icon: Icons.error_outline,
              title: 'Report not found',
              body: 'This report may have been deleted.',
            );
          }
          final pages =
              (report.layout['pages'] as List?)?.cast<Map>().toList() ?? [];
          // v2 wizard reports persist their query under layout.builder.query_v2.
          final builder = (report.layout['builder'] as Map?)
                  ?.cast<String, dynamic>() ??
              const {};
          final queryV2Raw =
              (builder['query_v2'] as Map?)?.cast<String, dynamic>();
          final dsAsync = ref.watch(restDataSourceIdProvider);
          if (queryV2Raw != null) {
            final query = CustomReportQueryV2.fromJson(queryV2Raw);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context, report),
                const SizedBox(height: OpticsSpacing.lg),
                Expanded(
                  child: dsAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => _emptyState(
                      context,
                      icon: Icons.warning_amber_outlined,
                      title: 'Data source unavailable',
                      body: '$e',
                    ),
                    data: (dsId) => dsId == null
                        ? _emptyState(
                            context,
                            icon: Icons.warning_amber_outlined,
                            title: 'No connected data source',
                            body:
                                'Connect a data source to render this report.',
                          )
                        : V2ReportView(query: query, dataSourceId: dsId),
                  ),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(context, report),
              const SizedBox(height: OpticsSpacing.lg),
              Expanded(
                child: pages.isEmpty
                    ? _emptyState(
                        context,
                        icon: Icons.description_outlined,
                        title: 'This report has no pages yet',
                        body: 'Clone it and add widgets to start customizing.',
                      )
                    : dsAsync.when(
                        loading: () => const Center(
                            child: CircularProgressIndicator()),
                        error: (e, _) => _emptyState(
                          context,
                          icon: Icons.warning_amber_outlined,
                          title: 'Data source unavailable',
                          body: '$e',
                        ),
                        data: (dsId) {
                          bool isSingleWidget = pages.length == 1 &&
                              (pages[0]['widgets'] as List?)?.length == 1;
                          if (isSingleWidget) {
                            return SingleWidgetViewer(
                              report: report,
                              widgetData: (pages[0]['widgets'] as List).first.cast<String, dynamic>(),
                              tenantId: report.tenantId,
                              dataSourceId: dsId,
                            );
                          }
                          return ListView.separated(
                            itemCount: pages.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: OpticsSpacing.xl),
                            itemBuilder: (_, i) => _PageBlock(
                              page: pages[i].cast<String, dynamic>(),
                              pageIndex: i + 1,
                              pageCount: pages.length,
                              tenantId: report.tenantId,
                              dataSourceId: dsId,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, Report report) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back, size: 18),
          tooltip: 'Back to Reports',
          onPressed: () => context.go('/reports'),
        ),
        const SizedBox(width: 4),
        if (report.isCanned)
          Container(
            margin: const EdgeInsets.only(right: 10),
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: OpticsColors.accentCyan.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'CANNED',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: OpticsColors.accentCyan,
                letterSpacing: 0.8,
              ),
            ),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(report.name.toUpperCase(), style: OpticsTextStyles.headingXl),
              if (report.description != null &&
                  report.description!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  report.description!,
                  style: OpticsTextStyles.bodySm.copyWith(
                    color: OpticsColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _emptyState(BuildContext context,
      {required IconData icon,
      required String title,
      required String body}) {
    return Center(
      child: OpticsCard(
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: OpticsColors.textMuted),
              const SizedBox(height: 12),
              Text(title.toUpperCase(), style: OpticsTextStyles.headingMd),
              const SizedBox(height: 6),
              Text(body,
                  textAlign: TextAlign.center,
                  style: OpticsTextStyles.bodySm),
            ],
          ),
        ),
      ),
    );
  }
}

/// One page of a report. Renders a title + a vertically-stacked column of
/// widgets. Each widget is sized into a fixed-height container so charts have
/// room to breathe and KPIs stay compact.
class _PageBlock extends StatelessWidget {
  final Map<String, dynamic> page;
  final int pageIndex;
  final int pageCount;
  final String tenantId;
  final String? dataSourceId;

  const _PageBlock({
    required this.page,
    required this.pageIndex,
    required this.pageCount,
    required this.tenantId,
    required this.dataSourceId,
  });

  @override
  Widget build(BuildContext context) {
    final title = page['title'] as String? ?? 'Page $pageIndex';
    final widgets =
        (page['widgets'] as List?)?.cast<Map>().toList() ?? [];
    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: OpticsTextStyles.sectionLabel.copyWith(fontSize: 13),
                ),
                const SizedBox(width: 10),
                Text(
                  'Page $pageIndex of $pageCount',
                  style: OpticsTextStyles.bodySm.copyWith(
                    color: OpticsColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: OpticsSpacing.md),
            if (widgets.isEmpty)
              Container(
                padding: const EdgeInsets.all(OpticsSpacing.lg),
                decoration: BoxDecoration(
                  color: OpticsColors.surface,
                  borderRadius: BorderRadius.circular(OpticsRadii.md),
                  border: Border.all(color: OpticsColors.border),
                ),
                child: const Text(
                  'No widgets on this page.',
                  style: OpticsTextStyles.bodySm,
                ),
              )
            else
              Wrap(
                spacing: OpticsSpacing.md,
                runSpacing: OpticsSpacing.md,
                children: widgets
                    .map((w) => _renderWidget(
                          w.cast<String, dynamic>(),
                          constraints.maxWidth,
                        ))
                    .toList(),
              ),
          ],
        );
      }
    );
  }

  Widget _renderWidget(Map<String, dynamic> w, double maxWidth) {
    final type = w['type'] as String? ?? 'kpi';
    final kind = WidgetKind.fromString(type);
    final binding =
        Map<String, dynamic>.from((w['binding'] as Map?) ?? const {});
    final settings =
        Map<String, dynamic>.from((w['settings'] as Map?) ?? const {});

    // Inject the active tenant's REST data source id into the brz binding
    // so WidgetRenderer can fetch live data.
    if (binding['brz'] is Map && dataSourceId != null) {
      final brz = Map<String, dynamic>.from(binding['brz'] as Map);
      brz['data_source_id'] = dataSourceId;
      binding['brz'] = brz;
    }

    // Sizing: KPIs are compact tiles; charts and tables get wider blocks.
    final isKpi = kind == WidgetKind.kpi;
    final isMarkdown = kind == WidgetKind.markdown;
    final isTable = kind == WidgetKind.table;
    final isChart = kind == WidgetKind.barVertical ||
                    kind == WidgetKind.barHorizontal ||
                    kind == WidgetKind.barStacked ||
                    kind == WidgetKind.barGrouped ||
                    kind == WidgetKind.line ||
                    kind == WidgetKind.combo;
    
    // Use an expansive width for tables and charts so they don't get squished.
    double width = isKpi
        ? 220.0
        : isMarkdown
            ? 540.0
            : (isTable || isChart)
                ? 1000.0
                : 460.0;
                
    if (width > maxWidth) {
      width = maxWidth;
    }
                
    final height = isKpi
        ? 130.0
        : isMarkdown
            ? 120.0
            : isTable
                ? 600.0
                : 400.0;

    final model = WidgetModel(
      id: 'report-${pageIndex}-${w['title'] ?? type}',
      tenantId: tenantId,
      dashboardId: '',
      title: w['title'] as String? ?? '',
      kind: kind,
      x: 0,
      y: 0,
      w: 12,
      h: 6,
      binding: binding,
      settings: settings,
    );

    return SizedBox(
      width: width,
      height: height,
      child: WidgetRenderer(model: model),
    );
  }
}

// ─── Providers ──────────────────────────────────────────────────────────────

/// Resolves a single report by id (either `lib:<library_item_id>` for canned
/// items or a real `reports.id` UUID for custom ones).
final _reportByIdProvider =
    FutureProvider.family<Report?, String>((ref, id) async {
  final client = ref.watch(supabaseProvider);
  if (id.startsWith('lib:')) {
    final libId = id.substring(4);
    final row = await client
        .from('library_items')
        .select()
        .eq('id', libId)
        .maybeSingle();
    if (row == null) return null;
    final m = row;
    final kind = m['kind'] as String? ?? 'report';
    final payload = (m['payload'] as Map?)?.cast<String, dynamic>() ?? {};
    
    Map<String, dynamic> layout;
    if (kind == 'widget') {
      layout = {
        'pages': [
          {
            'title': m['name'],
            'widgets': [
              {
                'title': m['name'],
                ...payload
              }
            ]
          }
        ]
      };
    } else {
      layout = (payload['layout'] as Map?)?.cast<String, dynamic>() ?? {'pages': []};
    }
    
    return Report(
      id: 'lib:${m['id']}',
      tenantId: '',
      name: m['name'] as String? ?? '',
      isCanned: true,
      category: m['category'] as String? ?? 'custom',
      description: m['description'] as String?,
      layout: layout,
    );
  }
  final row =
      await client.from('reports').select().eq('id', id).maybeSingle();
  if (row == null) return null;
  return Report.fromMap(row);
});

/// Resolves the active tenant's REST data source id (Bryzos / Tables API).
/// Returns null if none configured.
final restDataSourceIdProvider = FutureProvider<String?>((ref) async {
  final activeTenantId = ref.watch(activeTenantProvider);
  final all = await ref.watch(dataSourcesProvider.future);

  if (activeTenantId != null) {
    for (final ds in all) {
      if (ds.kind == 'rest' && ds.tenantId == activeTenantId) return ds.id;
    }
  }

  for (final ds in all) {
    if (ds.kind == 'rest') return ds.id;
  }
  return null;
});
