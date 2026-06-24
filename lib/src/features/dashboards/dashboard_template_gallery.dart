import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/supabase_repo.dart';
import '../../design/theme.dart';

/// Result returned from the gallery dialog.
/// - [DashboardGalleryResult.blank] -> user picked "Start from scratch"
/// - [DashboardGalleryResult.template] -> user picked a specific template
class DashboardGalleryResult {
  final bool blank;
  final String? templateId;
  final String? templateName;
  const DashboardGalleryResult.blank()
      : blank = true,
        templateId = null,
        templateName = null;
  const DashboardGalleryResult.template(
      {required this.templateId, required this.templateName})
      : blank = false;
}

/// Shows the Dashboard Template Gallery modal. Returns null if the user
/// cancelled, or a [DashboardGalleryResult] describing their choice.
Future<DashboardGalleryResult?> showDashboardTemplateGallery(
    BuildContext context, WidgetRef ref) {
  return showDialog<DashboardGalleryResult>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => const _DashboardTemplateGalleryDialog(),
  );
}

class _DashboardTemplateGalleryDialog extends ConsumerStatefulWidget {
  const _DashboardTemplateGalleryDialog();
  @override
  ConsumerState<_DashboardTemplateGalleryDialog> createState() =>
      _DashboardTemplateGalleryDialogState();
}

class _DashboardTemplateGalleryDialogState
    extends ConsumerState<_DashboardTemplateGalleryDialog> {
  bool _loading = true;
  List<Map<String, dynamic>> _templates = const [];
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(repoProvider).listDashboardTemplates();
      if (!mounted) return;
      setState(() {
        _templates = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString();
        _loading = false;
      });
    }
  }

  void _pickBlank() {
    Navigator.of(context).pop(const DashboardGalleryResult.blank());
  }

  void _pickTemplate(Map<String, dynamic> t) {
    Navigator.of(context).pop(DashboardGalleryResult.template(
      templateId: t['id'] as String,
      templateName: t['name'] as String,
    ));
  }

  Future<void> _preview(Map<String, dynamic> t) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TemplatePreviewDialog(
        templateId: t['id'] as String,
        templateName: t['name'] as String,
        description: t['description'] as String?,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: OpticsColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('NEW DASHBOARD',
                      style: OpticsTextStyles.headingMd
                          .copyWith(letterSpacing: 1.4, fontSize: 16)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: OpticsColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: OpticsSpacing.xs),
              const Text(
                'Choose a starting point. You can fully customize anything you pick.',
                style: TextStyle(
                  color: OpticsColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w300,
                ),
              ),
              const SizedBox(height: OpticsSpacing.lg),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(
              color: OpticsColors.accentCyan, strokeWidth: 2));
    }
    if (_err != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                color: OpticsColors.accentRed, size: 32),
            const SizedBox(height: 8),
            const Text('Could not load templates.',
                style: TextStyle(color: OpticsColors.textPrimary)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    // Compute a responsive grid: 1 column under 520, 2 under 760, 3 above.
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        final crossAxisCount = w >= 760 ? 3 : (w >= 520 ? 2 : 1);
        // +1 to include the "Start from scratch" tile
        final tiles = <Widget>[
          _BlankCard(onTap: _pickBlank),
          for (final t in _templates)
            _TemplateCard(
              template: t,
              onUse: () => _pickTemplate(t),
              onPreview: () => _preview(t),
            ),
        ];
        return GridView.count(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: OpticsSpacing.md,
          crossAxisSpacing: OpticsSpacing.md,
          childAspectRatio: 1.05,
          children: tiles,
        );
      },
    );
  }
}

// ─── Cards ─────────────────────────────────────────────────────────────────

class _BlankCard extends StatelessWidget {
  final VoidCallback onTap;
  const _BlankCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      onTap: onTap,
      borderColor: OpticsColors.accentCyan.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: OpticsColors.accentCyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.add,
                color: OpticsColors.accentCyan, size: 22),
          ),
          const Spacer(),
          Text('START FROM SCRATCH',
              style: OpticsTextStyles.headingMd.copyWith(
                color: OpticsColors.accentCyan,
                letterSpacing: 1.2,
                fontSize: 13,
              )),
          const SizedBox(height: 6),
          const Text(
            'Create an empty dashboard and add widgets one by one.',
            style: TextStyle(
              color: OpticsColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w300,
              height: 1.35,
            ),
          ),
          const SizedBox(height: OpticsSpacing.md),
          Row(
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: OpticsColors.accentCyan,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('CREATE BLANK',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    )),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  final Map<String, dynamic> template;
  final VoidCallback onUse;
  final VoidCallback onPreview;
  const _TemplateCard({
    required this.template,
    required this.onUse,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final name = (template['name'] as String?) ?? 'Template';
    final desc = (template['description'] as String?) ?? '';
    return _CardShell(
      onTap: onUse,
      borderColor: OpticsColors.border,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: OpticsColors.accentViolet.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.dashboard_outlined,
                color: OpticsColors.accentViolet, size: 20),
          ),
          const SizedBox(height: OpticsSpacing.md),
          Text(name.toUpperCase(),
              style: OpticsTextStyles.headingMd
                  .copyWith(letterSpacing: 1.2, fontSize: 13)),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              desc,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: OpticsColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w300,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: OpticsSpacing.md),
          Row(
            children: [
              OutlinedButton(
                onPressed: onPreview,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: OpticsColors.border),
                  foregroundColor: OpticsColors.textPrimary,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text('PREVIEW',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: onUse,
                style: ElevatedButton.styleFrom(
                  backgroundColor: OpticsColors.accentCyan,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                ),
                child: const Text('USE TEMPLATE',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final Color borderColor;
  const _CardShell({
    required this.child,
    required this.onTap,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: OpticsColors.surfaceElevated,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: child,
        ),
      ),
    );
  }
}

// ─── Preview Dialog ────────────────────────────────────────────────────────

class _TemplatePreviewDialog extends ConsumerStatefulWidget {
  final String templateId;
  final String templateName;
  final String? description;
  const _TemplatePreviewDialog({
    required this.templateId,
    required this.templateName,
    required this.description,
  });
  @override
  ConsumerState<_TemplatePreviewDialog> createState() =>
      _TemplatePreviewDialogState();
}

class _TemplatePreviewDialogState
    extends ConsumerState<_TemplatePreviewDialog> {
  bool _loading = true;
  List<Map<String, dynamic>> _widgets = const [];
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await ref
          .read(repoProvider)
          .listDashboardTemplateWidgets(widget.templateId);
      if (!mounted) return;
      setState(() {
        _widgets = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: OpticsColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 800),
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'PREVIEW · ${widget.templateName.toUpperCase()}',
                            style: OpticsTextStyles.headingMd
                                .copyWith(letterSpacing: 1.4, fontSize: 16)),
                        if (widget.description != null &&
                            widget.description!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            widget.description!,
                            style: const TextStyle(
                              color: OpticsColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: OpticsColors.textSecondary),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: OpticsSpacing.lg),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
            color: OpticsColors.accentCyan, strokeWidth: 2),
      );
    }
    if (_err != null) {
      return const Center(
        child: Text('Could not load preview.',
            style: TextStyle(color: OpticsColors.textPrimary)),
      );
    }
    if (_widgets.isEmpty) {
      return const Center(
        child: Text('No widgets in this template.',
            style: TextStyle(color: OpticsColors.textSecondary)),
      );
    }

    // Compute layout extent. Layouts use a 48-column grid (matches the
    // canvas elsewhere in the app), each row ~ a fixed height unit.
    const int gridCols = 48;
    const double cellH = 14.0; // visual scale only
    int maxX2 = 0;
    int maxY2 = 0;
    for (final w in _widgets) {
      final l = (w['layout'] as Map?)?.cast<String, dynamic>() ?? const {};
      final x = (l['x'] as num?)?.toInt() ?? 0;
      final y = (l['y'] as num?)?.toInt() ?? 0;
      final ww = (l['w'] as num?)?.toInt() ?? 0;
      final hh = (l['h'] as num?)?.toInt() ?? 0;
      if (x + ww > maxX2) maxX2 = x + ww;
      if (y + hh > maxY2) maxY2 = y + hh;
    }
    if (maxX2 < gridCols) maxX2 = gridCols;
    final canvasHeight = maxY2 * cellH;

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final cellW = constraints.maxWidth / gridCols;
        return SingleChildScrollView(
          child: Container(
            width: constraints.maxWidth,
            height: canvasHeight,
            decoration: BoxDecoration(
              color: OpticsColors.canvas,
              border: Border.all(color: OpticsColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                for (final w in _widgets) _previewTile(w, cellW, cellH),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _previewTile(Map<String, dynamic> w, double cellW, double cellH) {
    final l = (w['layout'] as Map?)?.cast<String, dynamic>() ?? const {};
    final x = (l['x'] as num?)?.toInt() ?? 0;
    final y = (l['y'] as num?)?.toInt() ?? 0;
    final ww = (l['w'] as num?)?.toInt() ?? 1;
    final hh = (l['h'] as num?)?.toInt() ?? 1;
    final title = (w['title'] as String?) ?? '';
    final type = (w['type'] as String?) ?? 'tile';

    IconData icon;
    Color color;
    switch (type) {
      case 'kpi':
        icon = Icons.tag;
        color = OpticsColors.accentCyan;
        break;
      case 'bar':
        icon = Icons.bar_chart;
        color = OpticsColors.accentViolet;
        break;
      case 'line':
        icon = Icons.show_chart;
        color = OpticsColors.accentGreen;
        break;
      case 'donut':
      case 'pie':
        icon = Icons.donut_large;
        color = OpticsColors.accentOrange;
        break;
      case 'table':
        icon = Icons.table_rows;
        color = OpticsColors.textSecondary;
        break;
      default:
        icon = Icons.widgets;
        color = OpticsColors.textSecondary;
    }

    return Positioned(
      left: x * cellW + 2,
      top: y * cellH + 2,
      width: ww * cellW - 4,
      height: hh * cellH - 4,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: OpticsColors.surface,
          border: Border.all(color: OpticsColors.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: OpticsColors.textPrimary,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
