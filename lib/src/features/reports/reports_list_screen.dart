// =====================================================================
// Reports Library
// ---------------------------------------------------------------------
// Consolidated destination that replaces the old card-based Reports +
// Library pages. Renders all reports — canned (system) and tenant-custom
// — in a single sortable, filterable, multi-selectable table with
// row-level actions (Preview, Edit, Share, Archive, Delete).
//
// • Preview      → right-side drawer (NOT a modal dialog).
// • Edit         → /explore?reportId=<id>; canned reports clone first.
// • Multi-select → bulk Archive / Delete from a top action bar.
// • Drag & drop  → drop report A onto report B to create a new
//                  "combined" custom report (combined_from = [A,B]).
//                  Drop further reports onto that combined row to
//                  append more sources. Originals are never deleted.
// • Share        → flips reports.shared_with_tenant.
// =====================================================================
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/feature_flags.dart';
import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/theme.dart';
import '../../shared/secure_error.dart';
import '../dashboards/widget_renderer.dart';
import 'custom_builder/custom_report_query_v2.dart';
import 'custom_builder/v2_report_view.dart';
import 'report_viewer_screen.dart' show restDataSourceIdProvider;

enum _Filter { all, mine, shared, canned, archived }

class ReportsListScreen extends ConsumerStatefulWidget {
  const ReportsListScreen({super.key});
  @override
  ConsumerState<ReportsListScreen> createState() => _ReportsListScreenState();
}

class _ReportsListScreenState extends ConsumerState<ReportsListScreen> {
  String _q = '';
  _Filter _filter = _Filter.all;
  int _sortCol = 3; // default sort by Created ↓
  bool _sortAsc = false;

  /// IDs of currently-selected rows for bulk actions.
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final reportsAsync = ref.watch(reportsProvider);
    final canEdit = ref.watch(canEditProvider);
    return Padding(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left: title + badge + search + filter chips stacked
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('REPORTS LIBRARY',
                            style: OpticsTextStyles.headingXl),
                        const SizedBox(width: 12),
                        _countBadge(reportsAsync),
                        const Spacer(),
                        SizedBox(
                          width: 280,
                          child: TextField(
                            decoration: const InputDecoration(
                              hintText: 'Search reports…',
                              prefixIcon: Icon(Icons.search, size: 16),
                              isDense: true,
                            ),
                            style: const TextStyle(fontSize: 13),
                            onChanged: (v) =>
                                setState(() => _q = v.toLowerCase()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: OpticsSpacing.md),
                    // ── Filter chips ────────────────────────────────
                    Row(
                      children: [
                        _chip(_Filter.all, 'All'),
                        const SizedBox(width: 8),
                        _chip(_Filter.mine, 'My Reports'),
                        const SizedBox(width: 8),
                        _chip(_Filter.shared, 'Shared with Me'),
                        const SizedBox(width: 8),
                        _chip(_Filter.canned, 'Canned'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Right: New Report + View Archives stacked, same width + height as search bar
              if (canEdit)
                SizedBox(
                  width: 176,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 36,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('New Report'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          onPressed: () {
                            if (OpticsFlags.customBuilderV2) {
                              context.go('/reports/new');
                            } else {
                              _createReport(context, ref);
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 36,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.archive_outlined, size: 16),
                          label: const Text('View Archives'),
                          onPressed: () =>
                              setState(() => _filter = _Filter.archived),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            foregroundColor: OpticsColors.textSecondary,
                            side: const BorderSide(
                                color: OpticsColors.border),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: OpticsSpacing.md),

          // ── Bulk action bar (visible only when rows are selected) ──
          if (_selected.isNotEmpty)
            _buildBulkActionBar(reportsAsync, canEdit),

          // ── Table ───────────────────────────────────────────────
          Expanded(
            child: reportsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: SecureErrorText(
                  genericMessage: 'Could not load reports.',
                  error: e,
                ),
              ),
              data: (allReports) {
                final visible = _applyFilters(allReports);
                if (visible.isEmpty) {
                  return _emptyState();
                }
                _sort(visible);
                return _ReportsTable(
                  rows: visible,
                  sortColumn: _sortCol,
                  sortAscending: _sortAsc,
                  canEdit: canEdit,
                  selected: _selected,
                  onToggleSelect: (id) => setState(() {
                    if (!_selected.add(id)) _selected.remove(id);
                  }),
                  onToggleSelectAll: (rows, on) => setState(() {
                    if (on) {
                      _selected.addAll(rows.map((r) => r.id));
                    } else {
                      _selected.removeWhere(
                          (id) => rows.any((r) => r.id == id));
                    }
                  }),
                  onSort: (i, asc) => setState(() {
                    _sortCol = i;
                    _sortAsc = asc;
                  }),
                  onPreview: _preview,
                  onEdit: (r) => _edit(context, ref, r),
                  onShare: (r) => _share(context, ref, r),
                  onArchive: (r) => _archive(context, ref, r),
                  onRestore: (r) => _restore(context, ref, r),
                  onDelete: (r) => _delete(context, ref, r),
                  onExport: (r, fmt) => _export(context, ref, r, fmt),
                  onSchedule: (r) => _schedule(context, ref, r),
                  onCombine: (src, dst) =>
                      _combine(context, ref, src, dst),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Bulk action bar ───────────────────────────────────────────
  Widget _buildBulkActionBar(
      AsyncValue<List<Report>> reportsAsync, bool canEdit) {
    final all = reportsAsync.asData?.value ?? const <Report>[];
    final picked = all.where((r) => _selected.contains(r.id)).toList();
    final allArchived =
        picked.every((r) => r.status == ReportStatus.archived);

    return Container(
      margin: const EdgeInsets.only(bottom: OpticsSpacing.md),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: OpticsColors.accentCyan.withValues(alpha: 0.08),
        border: Border.all(
            color: OpticsColors.accentCyan.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.check_box_outlined,
              size: 16, color: OpticsColors.accentCyan),
          const SizedBox(width: 8),
          Text(
            '${_selected.length} selected',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: OpticsColors.accentCyan,
            ),
          ),
          const SizedBox(width: 16),
          if (canEdit && !allArchived)
            _bulkBtn(
              icon: Icons.archive_outlined,
              label: 'Archive',
              onTap: () => _bulkArchive(context, ref, picked),
            ),
          if (canEdit && allArchived)
            _bulkBtn(
              icon: Icons.unarchive_outlined,
              label: 'Restore',
              onTap: () => _bulkRestore(context, ref, picked),
            ),
          if (canEdit) ...[
            const SizedBox(width: 8),
            _bulkBtn(
              icon: Icons.delete_outline,
              label: 'Delete',
              danger: true,
              onTap: () => _bulkDelete(context, ref, picked),
            ),
          ],
          const Spacer(),
          TextButton(
            onPressed: () => setState(_selected.clear),
            child: const Text('Clear', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _bulkBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? OpticsColors.danger : OpticsColors.textPrimary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(OpticsRadii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: color)),
          ],
        ),
      ),
    );
  }

  // ── Filtering / sorting ────────────────────────────────────────
  List<Report> _applyFilters(List<Report> reports) {
    final currentUserId = ref.read(currentUserIdProvider);
    return reports.where((r) {
      if (_filter == _Filter.archived) {
        if (r.status != ReportStatus.archived) return false;
      } else {
        if (r.status == ReportStatus.archived) return false;
      }
      switch (_filter) {
        case _Filter.canned:
          if (!r.isCanned) return false;
          break;
        case _Filter.mine:
          if (r.isCanned) return false;
          if (currentUserId != null && r.createdBy != currentUserId) {
            return false;
          }
          break;
        case _Filter.shared:
          if (r.isCanned) return false;
          if (currentUserId == null) return false;
          if (r.createdBy == currentUserId) return false;
          break;
        case _Filter.all:
        case _Filter.archived:
          break;
      }
      if (_q.isNotEmpty) {
        return r.name.toLowerCase().contains(_q) ||
            (r.description ?? '').toLowerCase().contains(_q) ||
            r.category.toLowerCase().contains(_q) ||
            (r.createdByName ?? '').toLowerCase().contains(_q);
      }
      return true;
    }).toList();
  }

  void _sort(List<Report> rows) {
    int cmp(Report a, Report b) {
      int r;
      switch (_sortCol) {
        case 0:
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case 1:
          r = (a.description ?? '')
              .toLowerCase()
              .compareTo((b.description ?? '').toLowerCase());
          break;
        case 2:
          r = a.status.index.compareTo(b.status.index);
          break;
        case 3:
          r = (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(
                  b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0));
          break;
        case 4:
          final aBy = a.isCanned ? 'Canned' : (a.createdByName ?? '');
          final bBy = b.isCanned ? 'Canned' : (b.createdByName ?? '');
          r = aBy.toLowerCase().compareTo(bBy.toLowerCase());
          break;
        case 5:
          r = (a.sharedWithTenant ? 1 : 0).compareTo(b.sharedWithTenant ? 1 : 0);
          break;
        default:
          r = 0;
      }
      return _sortAsc ? r : -r;
    }

    rows.sort(cmp);
  }

  // ── UI helpers ─────────────────────────────────────────────────
  Widget _countBadge(AsyncValue<List<Report>> reportsAsync) {
    final count = reportsAsync.whenOrNull(data: (d) => d.length) ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Text('$count reports',
          style: const TextStyle(
              fontSize: 12, color: OpticsColors.textSecondary)),
    );
  }

  Widget _chip(_Filter f, String label, {IconData? icon}) {
    final active = _filter == f;
    return GestureDetector(
      onTap: () => setState(() => _filter = f),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? OpticsColors.accentCyan.withValues(alpha: 0.12)
              : OpticsColors.surfaceElevated,
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
          border: Border.all(
            color: active ? OpticsColors.accentCyan : OpticsColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 12,
                  color: active
                      ? OpticsColors.accentCyan
                      : OpticsColors.textSecondary),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active
                    ? OpticsColors.accentCyan
                    : OpticsColors.textPrimary,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Container(
        width: 380,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: OpticsColors.surface,
          borderRadius: BorderRadius.circular(OpticsRadii.md),
          border: Border.all(color: OpticsColors.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.description_outlined,
                size: 28, color: OpticsColors.textMuted),
            const SizedBox(height: 12),
            Text('No Reports Match.'.toUpperCase(),
                style: OpticsTextStyles.headingMd),
            const SizedBox(height: 6),
            Text(
              _q.isNotEmpty
                  ? 'Try a different search term or filter.'
                  : 'Clone a canned report, or start a new custom one.',
              textAlign: TextAlign.center,
              style: OpticsTextStyles.bodySm,
            ),
          ],
        ),
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────────
  void _preview(Report r) {
    final allReports =
        ref.read(reportsProvider).asData?.value ?? const <Report>[];
    final canEdit = ref.read(canEditProvider);
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close preview',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
        final slide = Tween<Offset>(
          begin: const Offset(1.0, 0.0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return Align(
          alignment: Alignment.centerRight,
          child: SlideTransition(
            position: slide,
            child: _PreviewDrawer(
              report: r,
              allReports: allReports,
              canEdit: canEdit,
              onEdit: () {
                Navigator.pop(ctx);
                _edit(context, ref, r);
              },
              onShare: () {
                Navigator.pop(ctx);
                _share(context, ref, r);
              },
              onExportPdf: () {
                Navigator.pop(ctx);
                _export(context, ref, r, 'pdf');
              },
              onExportExcel: () {
                Navigator.pop(ctx);
                _export(context, ref, r, 'xlsx');
              },
              onSchedule: () {
                Navigator.pop(ctx);
                _schedule(context, ref, r);
              },
              onArchive: () {
                Navigator.pop(ctx);
                _archive(context, ref, r);
              },
              onRestore: () {
                Navigator.pop(ctx);
                _restore(context, ref, r);
              },
              onDelete: () {
                Navigator.pop(ctx);
                _delete(context, ref, r);
              },
            ),
          ),
        );
      },
    );
  }

  /// "Clone & Edit" for *both* canned and custom reports.
  /// - Canned   → clone via the `clone-canned-report` Edge Function
  ///              (the new row is named "Copy of <X>" by the function).
  /// - Custom   → clone into a new tenant row named "Copy of <X>" (or
  ///              "<X> 2"/"<X> 3"… if a "Copy of …" already exists).
  /// Then redirect to the Report Builder with the new id so the user can
  /// immediately tweak the name and contents.
  Future<void> _edit(BuildContext ctx, WidgetRef ref, Report r) async {
    // Every non-canned report opens in the new explicit-join wizard
    // (ADR-0013). Canned reports clone first (to protect the system
    // template), and the clone — which is itself a tenant-scoped custom
    // report — also opens in the wizard.
    if (r.isCanned) {
      final cloned = await _cloneReport(ctx, ref, r, purpose: 'edit');
      if (cloned == null || !ctx.mounted) return;
      // ignore: unused_result
      ref.refresh(reportsProvider);
      if (OpticsFlags.customBuilderV2) {
        ctx.go('/reports/${Uri.encodeComponent(cloned)}/edit');
      } else {
        ctx.go('/explore?reportId=${Uri.encodeComponent(cloned)}');
      }
      return;
    }
    if (OpticsFlags.customBuilderV2) {
      ctx.go('/reports/${Uri.encodeComponent(r.id)}/edit');
      return;
    }
    ctx.go('/explore?reportId=${Uri.encodeComponent(r.id)}');
  }

  /// Invoke `clone-canned-report`. The `purpose` switch decides whether
  /// the function creates a new user-visible "Copy of <X>" row
  /// (`purpose: 'edit'`) or returns the singleton hidden operational
  /// handle (`purpose: 'operational'`) used for Schedule / Export of
  /// canned reports.
  Future<String?> _cloneReport(
      BuildContext ctx, WidgetRef ref, Report r,
      {required String purpose}) async {
    final client = ref.read(supabaseProvider);
    final tid =
        client.auth.currentUser?.appMetadata['active_tenant_id'] as String?;
    final body = <String, dynamic>{'purpose': purpose};
    if (r.id.startsWith('lib:')) {
      body['library_item_id'] = r.id.substring(4);
    } else {
      body['report_id'] = r.id;
    }
    final res = await client.functions.invoke(
      'clone-canned-report',
      body: body,
      headers: tid == null ? {} : {'x-optics-tenant': tid},
    );
    final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
    return (data['report_id'] ?? data['id']) as String?;
  }

  Future<void> _share(BuildContext ctx, WidgetRef ref, Report r) async {
    await showDialog<void>(
      context: ctx,
      builder: (_) => ShareReportDialog(report: r),
    );
    // ignore: unused_result
    ref.refresh(reportsProvider);
  }

  /// Generate a PDF or XLSX export for the report and save it to the
  /// user's chosen location. Canned reports use a silent, deduped
  /// operational handle (one hidden row per tenant×canned-source) so the
  /// Reports list doesn't fill with spam clones.
  Future<void> _export(
      BuildContext ctx, WidgetRef ref, Report r, String format) async {
    final fmtLabel = format.toUpperCase();
    _toast(ctx, 'Generating $fmtLabel for "${r.name}"…');

    String reportId = r.id;
    try {
      if (r.isCanned) {
        final handle =
            await _cloneReport(ctx, ref, r, purpose: 'operational');
        if (handle == null) {
          if (ctx.mounted) _toast(ctx, '$fmtLabel export failed: handle');
          return;
        }
        reportId = handle;
      }
      final repo = ref.read(repoProvider);
      final path =
          await repo.exportReport(reportId: reportId, format: format);
      if (path == null) {
        if (ctx.mounted) _toast(ctx, '$fmtLabel export failed.');
        return;
      }
      final url =
          await repo.signedExportUrl(path, expiresInSeconds: 3600);
      if (url == null || url.isEmpty) {
        if (ctx.mounted) _toast(ctx, 'Could not sign download URL.');
        return;
      }
      await _downloadToDisk(ctx, url: url, report: r, format: format);
    } catch (e) {
      if (ctx.mounted) _toast(ctx, '$fmtLabel export failed: $e');
    }
  }

  /// Download the bytes from `url` and prompt the user (desktop) or save
  /// to the platform's downloads folder (mobile) — never opens a browser
  /// window for the artifact.
  Future<void> _downloadToDisk(
    BuildContext ctx, {
    required String url,
    required Report report,
    required String format,
  }) async {
    final fmtLabel = format.toUpperCase();
    final safeName =
        report.name.replaceAll(RegExp(r'[^A-Za-z0-9 _\-\.]'), '').trim();
    final defaultFileName =
        '${safeName.isEmpty ? 'optics-report' : safeName}.$format';

    // Fetch the artifact bytes from the signed URL.
    final resp = await HttpClient().getUrl(Uri.parse(url));
    final httpResp = await resp.close();
    if (httpResp.statusCode != 200) {
      if (ctx.mounted) {
        _toast(ctx, '$fmtLabel download failed (${httpResp.statusCode})');
      }
      return;
    }
    final bytes = <int>[];
    await for (final chunk in httpResp) {
      bytes.addAll(chunk);
    }

    // Ask the user where to save (desktop: native dialog; mobile: file_picker
    // returns null/unsupported → fall back to documents dir).
    String? savePath;
    try {
      savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save $fmtLabel',
        fileName: defaultFileName,
        type: format == 'pdf' ? FileType.custom : FileType.custom,
        allowedExtensions: [format],
      );
    } catch (_) {
      savePath = null;
    }
    if (savePath == null) {
      // User cancelled or platform doesn't support saveFile.
      if (ctx.mounted) _toast(ctx, '$fmtLabel save cancelled.');
      return;
    }
    if (!savePath.toLowerCase().endsWith('.$format')) {
      savePath = '$savePath.$format';
    }
    await File(savePath).writeAsBytes(bytes, flush: true);
    if (ctx.mounted) _toast(ctx, '$fmtLabel saved: $savePath');
  }

  /// Open the Schedule dialog for a report. For canned reports the
  /// scheduler needs a tenant-scoped row (schedules.report_id FK
  /// references reports.id), so we use the deduped operational handle —
  /// reused across every Schedule/Export action so the Reports list never
  /// accumulates spam clones.
  Future<void> _schedule(BuildContext ctx, WidgetRef ref, Report r) async {
    Report target = r;
    if (r.isCanned) {
      final handle =
          await _cloneReport(ctx, ref, r, purpose: 'operational');
      if (handle == null) {
        if (ctx.mounted) _toast(ctx, 'Could not open Schedule.');
        return;
      }
      final repo = ref.read(repoProvider);
      final fetched = await repo.getReport(handle);
      if (fetched == null) {
        if (ctx.mounted) _toast(ctx, 'Could not open Schedule.');
        return;
      }
      // Present the canned name to the user, not the [op] internal label.
      target = fetched.copyWith(name: r.name);
    }
    if (!ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (_) => _ScheduleDialog(report: target),
    );
    // ignore: unused_result
    ref.refresh(reportsProvider);
  }

  Future<void> _archive(BuildContext ctx, WidgetRef ref, Report r) async {
    await _archiveOne(r);
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Archived: ${r.name}');
  }

  Future<void> _restore(BuildContext ctx, WidgetRef ref, Report r) async {
    await _restoreOne(r);
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Restored: ${r.name}');
  }

  Future<void> _delete(BuildContext ctx, WidgetRef ref, Report r) async {
    final confirmed = await _confirmDelete(ctx,
        title: 'Delete report?',
        body:
            'This will permanently delete "${r.name}". This cannot be undone.');
    if (confirmed != true) return;
    await _deleteOne(r);
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Deleted: ${r.name}');
  }

  // ── Bulk ─────────────────────────────────────────────────────
  Future<void> _bulkArchive(
      BuildContext ctx, WidgetRef ref, List<Report> rows) async {
    // Canned reports archive per-user; custom reports archive tenant-wide.
    for (final r in rows) {
      await _archiveOne(r);
    }
    setState(_selected.clear);
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Archived ${rows.length} reports');
  }

  Future<void> _bulkRestore(
      BuildContext ctx, WidgetRef ref, List<Report> rows) async {
    for (final r in rows) {
      await _restoreOne(r);
    }
    setState(_selected.clear);
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Restored ${rows.length} reports');
  }

  Future<void> _bulkDelete(
      BuildContext ctx, WidgetRef ref, List<Report> rows) async {
    final n = rows.where((r) => !r.isCanned).length;
    if (n == 0) return;
    final confirmed = await _confirmDelete(
      ctx,
      title: 'Delete $n reports?',
      body:
          'This will permanently delete $n custom reports. This cannot be undone.',
    );
    if (confirmed != true) return;
    for (final r in rows.where((x) => !x.isCanned)) {
      await _deleteOne(r);
    }
    setState(_selected.clear);
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Deleted $n reports');
  }

  // ── Shared persistence primitives ────────────────────────────
  /// Archive a report. For custom reports this flips the row's status to
  /// 'archived' on the shared `reports` table. For canned reports it
  /// writes a per-user pref row instead — so archiving a canned report
  /// only hides it from *this* user, never from other users or tenants.
  Future<void> _archiveOne(Report r) async {
    if (r.isCanned) {
      final libId = r.id.startsWith('lib:') ? r.id.substring(4) : r.id;
      await ref.read(repoProvider).archiveCannedForUser(libId);
      return;
    }
    await ref.read(supabaseProvider).from('reports').update({
      'status': 'archived',
      'archived_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', r.id);
  }

  /// Restore a report. Canned restore is per-user; custom restore flips
  /// the shared row back to 'live'.
  Future<void> _restoreOne(Report r) async {
    if (r.isCanned) {
      final libId = r.id.startsWith('lib:') ? r.id.substring(4) : r.id;
      await ref.read(repoProvider).restoreCannedForUser(libId);
      return;
    }
    await ref.read(supabaseProvider).from('reports').update({
      'status': 'live',
      'archived_at': null,
    }).eq('id', r.id);
  }

  /// Delete a (custom) report. Canned reports can never be deleted —
  /// callers are expected to guard against this.
  Future<void> _deleteOne(Report r) async {
    if (r.isCanned) return; // belt-and-suspenders; UI dims the action.
    await ref.read(supabaseProvider).from('reports').delete().eq('id', r.id);
  }

  Future<bool?> _confirmDelete(BuildContext ctx,
      {required String title, required String body}) {
    return showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dctx, rootNavigator: true).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: OpticsColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () =>
                Navigator.of(dctx, rootNavigator: true).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext ctx, String msg) {
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _createReport(BuildContext ctx, WidgetRef ref) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: const Text('New report'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) =>
              Navigator.of(dctx, rootNavigator: true).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx, rootNavigator: true).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dctx, rootNavigator: true)
                .pop(c.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final inserted = await ref
        .read(supabaseProvider)
        .from('reports')
        .insert({
          'name': name,
          'layout': {'pages': []},
          'status': 'pending',
        })
        .select('id')
        .single();
    final String? newId = inserted['id'] as String?;
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (newId != null && ctx.mounted) {
      ctx.go('/explore?reportId=${Uri.encodeComponent(newId)}');
    }
  }

  // ── Drag-and-drop "combine" ───────────────────────────────────
  Future<void> _combine(
      BuildContext ctx, WidgetRef ref, Report src, Report dst) async {
    if (src.id == dst.id) return;
    final dstSources = _combinedSourcesOf(dst);

    // If the drop target is already a combined report, APPEND src to it.
    if (dstSources != null) {
      if (dstSources.contains(src.id)) {
        _toast(ctx, '"${src.name}" is already part of "${dst.name}".');
        return;
      }
      final nextSources = [...dstSources, src.id];
      await _updateLayout(dst, {
        ...dst.layout,
        'combined_from': nextSources,
      });
      // ignore: unused_result
      ref.refresh(reportsProvider);
      if (ctx.mounted) {
        _toast(ctx, 'Added "${src.name}" to "${dst.name}".');
      }
      return;
    }

    // Otherwise create a NEW combined custom report containing [dst, src].
    final combinedName = 'Combined: ${dst.name} + ${src.name}';
    final layout = <String, dynamic>{
      'pages': [],
      'combined_from': [dst.id, src.id],
    };

    await ref.read(supabaseProvider).from('reports').insert({
      'name': combinedName,
      'description': 'Combined from 2 reports.',
      'layout': layout,
      'status': 'pending',
    });
    // ignore: unused_result
    ref.refresh(reportsProvider);
    if (ctx.mounted) _toast(ctx, 'Created "$combinedName".');
  }

  Future<void> _updateLayout(
      Report r, Map<String, dynamic> nextLayout) async {
    await ref
        .read(supabaseProvider)
        .from('reports')
        .update({'layout': nextLayout}).eq('id', r.id);
  }
}

/// Returns the list of source-report IDs if [r] is a combined report,
/// otherwise null.
List<String>? _combinedSourcesOf(Report r) {
  final v = r.layout['combined_from'];
  if (v is List && v.isNotEmpty) return v.cast<String>();
  return null;
}

// ─────────────────────────────────────────────────────────────────
// Table  (custom, flex-based; supports multi-select + drag/drop)
// ─────────────────────────────────────────────────────────────────
class _ReportsTable extends StatelessWidget {
  final List<Report> rows;
  final int sortColumn;
  final bool sortAscending;
  final bool canEdit;
  final Set<String> selected;
  final void Function(String id) onToggleSelect;
  final void Function(List<Report> rows, bool on) onToggleSelectAll;
  final void Function(int col, bool asc) onSort;
  final void Function(Report) onPreview;
  final void Function(Report) onEdit;
  final void Function(Report) onShare;
  final void Function(Report) onArchive;
  final void Function(Report) onRestore;
  final void Function(Report) onDelete;
  final void Function(Report, String format) onExport;
  final void Function(Report) onSchedule;
  final void Function(Report src, Report dst) onCombine;

  const _ReportsTable({
    required this.rows,
    required this.sortColumn,
    required this.sortAscending,
    required this.canEdit,
    required this.selected,
    required this.onToggleSelect,
    required this.onToggleSelectAll,
    required this.onSort,
    required this.onPreview,
    required this.onEdit,
    required this.onShare,
    required this.onArchive,
    required this.onRestore,
    required this.onDelete,
    required this.onExport,
    required this.onSchedule,
    required this.onCombine,
  });

  @override
  Widget build(BuildContext context) {
    final allChecked =
        rows.isNotEmpty && rows.every((r) => selected.contains(r.id));
    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(color: OpticsColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _headerRow(allChecked),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: rows.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                thickness: 1,
                color: OpticsColors.border.withValues(alpha: 0.3),
              ),
              itemBuilder: (_, i) => _buildRow(context, rows[i]),
            ),
          ),
        ],
      ),
    );
  }

  // ── Layout constants ─────────────────────────────────────────
  // Right-side widths are kept tight; remaining horizontal room
  // is distributed to Title / Description / Created By by flex.
  // Columns shift right (closer to Actions) by giving Title/Description
  // less flex weight relative to the fixed-width right columns.
  static const double _checkW = 36;
  static const double _statusW = 72;
  static const double _createdW = 90;
  static const double _createdByW = 140;
  static const double _sharedW = 80;
  static const double _actionsW = 220;
  static const double _gap = 12;

  Widget _headerRow(bool allChecked) {
    Widget sortable(int col, String label) {
      final active = sortColumn == col;
      return InkWell(
        onTap: () => onSort(col, !(active && sortAscending)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: OpticsTextStyles.sectionLabel.copyWith(fontSize: 10, letterSpacing: 1.2)),
            const SizedBox(width: 4),
            Icon(
              active && !sortAscending ? Icons.arrow_downward : Icons.arrow_upward,
              size: 9,
              color: active
                  ? OpticsColors.accentCyan
                  : OpticsColors.accentCyan.withValues(alpha: 0.35),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        border: Border(
          bottom: BorderSide(
            color: OpticsColors.border.withValues(alpha: 0.3),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: _checkW,
            child: Checkbox(
              value: allChecked,
              tristate: false,
              onChanged: (v) => onToggleSelectAll(rows, v ?? false),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: OpticsColors.accentCyan,
              side: const BorderSide(color: OpticsColors.textMuted),
            ),
          ),
          // TITLE header: offset by drag icon width + gap so it aligns with
          // the actual title text (not the column left edge).
          Expanded(flex: 4, child: Padding(
            padding: const EdgeInsets.only(left: 20), // drag icon (14) + gap (6)
            child: sortable(0, 'TITLE'),
          )),
          const SizedBox(width: _gap),
          Expanded(flex: 7, child: Align(alignment: Alignment.centerLeft, child: sortable(1, 'DESCRIPTION'))),
          const SizedBox(width: _gap),
          SizedBox(width: _statusW, child: Align(alignment: Alignment.centerLeft, child: sortable(2, 'STATUS'))),
          const SizedBox(width: _gap),
          SizedBox(width: _createdW, child: Align(alignment: Alignment.centerLeft, child: sortable(3, 'CREATED'))),
          const SizedBox(width: _gap),
          SizedBox(width: _createdByW, child: Align(alignment: Alignment.centerLeft, child: sortable(4, 'CREATED BY'))),
          const SizedBox(width: _gap),
          SizedBox(width: _sharedW, child: Align(alignment: Alignment.centerLeft, child: sortable(5, 'SHARED'))),
          const SizedBox(width: _gap),
          SizedBox(
              width: _actionsW,
              child: Text('ACTIONS',
                  textAlign: TextAlign.right,
                  style: OpticsTextStyles.sectionLabel.copyWith(fontSize: 10, letterSpacing: 1.2))),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, Report r) {
    final isSelected = selected.contains(r.id);
    final isCombined = _combinedSourcesOf(r) != null;

    final rowChild = _RowContent(
      report: r,
      isSelected: isSelected,
      isCombined: isCombined,
      canEdit: canEdit,
      onToggleSelect: () => onToggleSelect(r.id),
      onPreview: () => onPreview(r),
      onEdit: () => onEdit(r),
      onShare: () => onShare(r),
      onArchive: () => onArchive(r),
      onRestore: () => onRestore(r),
      onDelete: () => onDelete(r),
      onExport: (fmt) => onExport(r, fmt),
      onSchedule: () => onSchedule(r),
      checkW: _checkW,
      statusW: _statusW,
      createdW: _createdW,
      createdByW: _createdByW,
      sharedW: _sharedW,
      actionsW: _actionsW,
    );

    // The whole row is:
    //   • a Draggable (carries this Report) — drag fires on pointer-move
    //   • a DragTarget (accepts a Report to be combined with this one)
    //   • a GestureDetector for a stationary click → open Preview drawer
    // Cursor swaps from `click` to `grab` to telegraph the dual mode.
    return DragTarget<Report>(
      onWillAcceptWithDetails: (d) => d.data.id != r.id && canEdit,
      onAcceptWithDetails: (d) => onCombine(d.data, r),
      builder: (ctx, candidate, rejected) {
        final hovered = candidate.isNotEmpty;
        return MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Draggable<Report>(
            data: r,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: _DragFeedback(report: r),
            childWhenDragging: Opacity(opacity: 0.35, child: rowChild),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => onPreview(r),
              child: Container(
                decoration: BoxDecoration(
                  color: hovered
                      ? OpticsColors.accentCyan.withValues(alpha: 0.08)
                      : null,
                  border: hovered
                      ? Border.all(
                          color: OpticsColors.accentCyan, width: 1)
                      : null,
                ),
                child: rowChild,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RowContent extends StatelessWidget {
  final Report report;
  final bool isSelected;
  final bool isCombined;
  final bool canEdit;
  final VoidCallback onToggleSelect;
  final VoidCallback onPreview;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onArchive;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final void Function(String format) onExport;
  final VoidCallback onSchedule;
  final double checkW;
  final double statusW;
  final double createdW;
  final double createdByW;
  final double sharedW;
  final double actionsW;

  const _RowContent({
    required this.report,
    required this.isSelected,
    required this.isCombined,
    required this.canEdit,
    required this.onToggleSelect,
    required this.onPreview,
    required this.onEdit,
    required this.onShare,
    required this.onArchive,
    required this.onRestore,
    required this.onDelete,
    required this.onExport,
    required this.onSchedule,
    required this.checkW,
    required this.statusW,
    required this.createdW,
    required this.createdByW,
    required this.sharedW,
    required this.actionsW,
  });

  @override
  Widget build(BuildContext context) {
    final r = report;
    final isArchived = r.status == ReportStatus.archived;

    return Container(
      color: isSelected
          ? OpticsColors.accentCyan.withValues(alpha: 0.06)
          : Colors.transparent,
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: checkW,
            child: Checkbox(
              value: isSelected,
              onChanged: (_) => onToggleSelect(),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: OpticsColors.accentCyan,
              side: const BorderSide(color: OpticsColors.textMuted),
            ),
          ),
          Expanded(flex: 4, child: _titleCell(r, isCombined)),
          const SizedBox(width: 12),
          Expanded(flex: 7, child: _descriptionCell(r, isCombined)),
          const SizedBox(width: 12),
          SizedBox(width: statusW, child: _statusChip(r.status)),
          const SizedBox(width: 12),
          SizedBox(
            width: createdW,
            child: Text(
              _dateFmt(r.createdAt),
              style: const TextStyle(
                  fontSize: 12, color: OpticsColors.textSecondary),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: createdByW, child: _createdByCell(r)),
          const SizedBox(width: 12),
          SizedBox(width: sharedW, child: _sharedCell(r)),
          const SizedBox(width: 12),
          SizedBox(
              width: actionsW,
              child: _actionsCell(r, isArchived: isArchived)),
        ],
      ),
    );
  }

  Widget _titleCell(Report r, bool combined) {
    return Row(
      children: [
        Icon(
          combined ? Icons.merge_type : Icons.drag_indicator,
          size: 14,
          color: combined
              ? OpticsColors.accentViolet
              : OpticsColors.textMuted,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            r.name,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: OpticsColors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  Widget _descriptionCell(Report r, bool combined) {
    final base = r.description ?? '—';
    final sources = _combinedSourcesOf(r);
    final suffix = (combined && sources != null)
        ? ' · combined from ${sources.length} reports'
        : '';
    return Text(
      '$base$suffix',
      style: const TextStyle(
        color: OpticsColors.textSecondary,
        fontSize: 12,
        height: 1.4,
      ),
      softWrap: true,
    );
  }

  Widget _statusChip(ReportStatus s) {
    Color c;
    switch (s) {
      case ReportStatus.live:
        c = OpticsColors.success;
        break;
      case ReportStatus.pending:
        c = OpticsColors.warning;
        break;
      case ReportStatus.archived:
        c = OpticsColors.textMuted;
        break;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.withValues(alpha: 0.5)),
        ),
        child: Text(
          s.label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: c),
        ),
      ),
    );
  }

  Widget _createdByCell(Report r) {
    final text = r.isCanned ? 'Canned' : (r.createdByName ?? '—');
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: r.isCanned
            ? OpticsColors.textMuted
            : OpticsColors.textSecondary,
        fontStyle: r.isCanned ? FontStyle.italic : FontStyle.normal,
      ),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _sharedCell(Report r) {
    Widget wrap(Widget child) =>
        Align(alignment: Alignment.centerLeft, child: child);
    if (r.isCanned) {
      return wrap(const Tooltip(
        message: 'Available to all users (system)',
        child:
            Icon(Icons.public, size: 16, color: OpticsColors.textMuted),
      ));
    }
    if (r.sharedWithTenant) {
      return wrap(const Tooltip(
        message: 'Shared with tenant',
        child: Icon(Icons.groups_outlined,
            size: 16, color: OpticsColors.accentCyan),
      ));
    }
    return wrap(const Tooltip(
      message: 'Private',
      child:
          Icon(Icons.lock_outline, size: 16, color: OpticsColors.textMuted),
    ));
  }

  Widget _actionsCell(Report r, {required bool isArchived}) {
    // All five action slots are clickable for every report — canned or
    // custom. For canned rows the destructive/sharing actions effectively
    // operate on a tenant-scoped clone (Edit already clones first; Share /
    // Archive / Delete behave the same way at the repo layer).
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _iconBtn(Icons.visibility_outlined, 'Preview', onPreview),
        _iconBtn(
          Icons.edit_outlined,
          r.isCanned ? 'Clone & edit' : 'Edit',
          canEdit && !isArchived ? onEdit : null,
        ),
        _exportMenuBtn(r, isArchived),
        _iconBtn(
          Icons.schedule_outlined,
          'Schedule',
          canEdit && !isArchived ? onSchedule : null,
        ),
        _iconBtn(
          Icons.share_outlined,
          r.isCanned
              ? 'Canned reports are available to everyone by default'
              : 'Share with tenant',
          (canEdit && !isArchived && !r.isCanned) ? onShare : null,
        ),
        // Archive ↔ Restore — canned reports use a per-user toggle, so
        // both flavors are valid for them too.
        if (isArchived)
          _iconBtn(
            Icons.unarchive_outlined,
            'Restore',
            canEdit ? onRestore : null,
          )
        else
          _iconBtn(
            Icons.archive_outlined,
            r.isCanned ? 'Archive (only for you)' : 'Archive',
            canEdit ? onArchive : null,
          ),
        // Delete — canned reports cannot be deleted (you can only archive
        // them per-user). The icon stays in place but is dimmed + disabled.
        _iconBtn(
          Icons.delete_outline,
          r.isCanned
              ? 'Canned reports cannot be deleted (archive instead)'
              : 'Delete',
          (canEdit && !r.isCanned) ? onDelete : null,
          color: r.isCanned ? null : OpticsColors.danger,
        ),
      ],
    );
  }

  /// Export icon with a popup menu choosing PDF or Excel.
  Widget _exportMenuBtn(Report r, bool isArchived) {
    final enabled = !isArchived;
    return Tooltip(
      message: 'Export',
      child: PopupMenuButton<String>(
        tooltip: '',
        enabled: enabled,
        position: PopupMenuPosition.under,
        color: OpticsColors.surfaceElevated,
        onSelected: (fmt) => onExport(fmt),
        itemBuilder: (_) => const [
          PopupMenuItem<String>(
            value: 'pdf',
            child: Row(children: [
              Icon(Icons.picture_as_pdf_outlined,
                  size: 14, color: OpticsColors.textSecondary),
              SizedBox(width: 8),
              Text('Export PDF', style: TextStyle(fontSize: 12)),
            ]),
          ),
          PopupMenuItem<String>(
            value: 'xlsx',
            child: Row(children: [
              Icon(Icons.table_chart_outlined,
                  size: 14, color: OpticsColors.textSecondary),
              SizedBox(width: 8),
              Text('Export Excel', style: TextStyle(fontSize: 12)),
            ]),
          ),
        ],
        padding: EdgeInsets.zero,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          child: Icon(
            Icons.file_download_outlined,
            size: 16,
            color: enabled
                ? OpticsColors.textSecondary
                : OpticsColors.textMuted.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback? onTap,
      {Color? color}) {
    final enabled = onTap != null;
    final base = color ?? OpticsColors.textSecondary;
    return Tooltip(
      message: tip,
      child: IconButton(
        icon: Icon(
          icon,
          size: 16,
          color: enabled
              ? base
              : OpticsColors.textMuted.withValues(alpha: 0.35),
        ),
        onPressed: onTap,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        splashRadius: 16,
      ),
    );
  }

  String _dateFmt(DateTime? d) {
    if (d == null) return '—';
    final l = d.toLocal();
    final mm = l.month.toString().padLeft(2, '0');
    final dd = l.day.toString().padLeft(2, '0');
    return '$mm/$dd/${l.year}';
  }
}

/// Floating tile that follows the cursor while dragging a report.
class _DragFeedback extends StatelessWidget {
  final Report report;
  const _DragFeedback({required this.report});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: OpticsColors.surfaceElevated,
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
          border: Border.all(color: OpticsColors.accentCyan),
          boxShadow: [
            BoxShadow(
              color: OpticsColors.accentCyan.withValues(alpha: 0.3),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.merge_type,
                size: 14, color: OpticsColors.accentCyan),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                report.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: OpticsColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// Preview drawer (slides in from the right)
// ─────────────────────────────────────────────────────────────────
class _PreviewDrawer extends StatelessWidget {
  final Report report;
  final List<Report> allReports;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback onExportPdf;
  final VoidCallback onExportExcel;
  final VoidCallback onSchedule;
  final VoidCallback onArchive;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  const _PreviewDrawer({
    required this.report,
    required this.allReports,
    required this.canEdit,
    required this.onEdit,
    required this.onShare,
    required this.onExportPdf,
    required this.onExportExcel,
    required this.onSchedule,
    required this.onArchive,
    required this.onRestore,
    required this.onDelete,
  });

  Report? _lookup(String id) {
    for (final r in allReports) {
      if (r.id == id) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final pages = (report.layout['pages'] as List?) ?? const [];
    final combined = _combinedSourcesOf(report);
    final combinedReports = combined
        ?.map((id) => MapEntry(id, _lookup(id)))
        .toList();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 520,
        height: double.infinity,
        decoration: const BoxDecoration(
          color: OpticsColors.surface,
          border: Border(
            left: BorderSide(color: OpticsColors.border),
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Drawer header ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(
                  children: [
                    const Text('PREVIEW',
                        style: OpticsTextStyles.sectionLabel),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close preview',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(report.name.toUpperCase(),
                    style: OpticsTextStyles.headingLg),
              ),
              if (report.description != null &&
                  report.description!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                  child: Text(report.description!,
                      style: OpticsTextStyles.bodySm),
                ),
              const SizedBox(height: 16),

              // ── Meta strip ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 18,
                  runSpacing: 6,
                  children: [
                    _meta('Status', report.status.label),
                    _meta(
                      'Created',
                      report.createdAt == null
                          ? '—'
                          : _fmtDate(report.createdAt!),
                    ),
                    _meta(
                      'Created by',
                      report.isCanned
                          ? 'Canned'
                          : (report.createdByName ?? '—'),
                    ),
                    _meta('Category',
                        report.category.isEmpty ? '—' : report.category),
                    _meta(
                      'Shared',
                      report.isCanned
                          ? 'System (all users)'
                          : report.sharedWithTenant
                              ? 'With tenant'
                              : 'Private',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Divider(
                  color: OpticsColors.border.withValues(alpha: 0.3),
                  height: 1),

              // ── Body ──
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (combinedReports != null) ...[
                        const Text('COMBINED FROM',
                            style: OpticsTextStyles.sectionLabel),
                        const SizedBox(height: 8),
                        ...combinedReports.map((entry) {
                          final r = entry.value;
                          final title = r?.name ?? 'Unknown report';
                          final subtitle = r == null
                              ? '(no longer available)'
                              : (r.isCanned
                                  ? 'Canned · ${r.category}'
                                  : (r.createdByName ?? 'Custom'));
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding:
                                      EdgeInsets.only(top: 4, right: 8),
                                  child: Icon(Icons.fiber_manual_record,
                                      size: 6,
                                      color: OpticsColors.accentViolet),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(title,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: OpticsColors
                                                .textPrimary,
                                          )),
                                      Text(subtitle,
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: OpticsColors
                                                  .textMuted)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 18),
                      ],
                      _PagePreviewSurface(
                        report: report,
                        pages: pages,
                        combinedReports: combinedReports,
                      ),
                    ],
                  ),
                ),
              ),

              // ── Drawer footer ──
              Divider(
                  color: OpticsColors.border.withValues(alpha: 0.3),
                  height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: _drawerActions(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _drawerActions(BuildContext context) {
    final isArchived = report.status == ReportStatus.archived;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Edit (always present — clones canned reports automatically).
            _actionBtn(
              icon: Icons.edit_outlined,
              label: report.isCanned ? 'Clone & edit' : 'Edit',
              onPressed: canEdit ? onEdit : null,
            ),
            // Share with tenant — disabled for canned (already system-wide).
            _actionBtn(
              icon: Icons.group_outlined,
              label: 'Share',
              onPressed:
                  (canEdit && !report.isCanned) ? onShare : null,
            ),
            // Export menu (PDF / Excel).
            PopupMenuButton<String>(
              tooltip: 'Export',
              position: PopupMenuPosition.under,
              color: OpticsColors.surfaceElevated,
              onSelected: (v) {
                if (v == 'pdf') onExportPdf();
                if (v == 'xlsx') onExportExcel();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'pdf',
                  child: Row(children: [
                    Icon(Icons.picture_as_pdf_outlined,
                        size: 14, color: OpticsColors.textSecondary),
                    SizedBox(width: 8),
                    Text('Export as PDF',
                        style: TextStyle(fontSize: 12)),
                  ]),
                ),
                PopupMenuItem(
                  value: 'xlsx',
                  child: Row(children: [
                    Icon(Icons.table_chart_outlined,
                        size: 14, color: OpticsColors.textSecondary),
                    SizedBox(width: 8),
                    Text('Export as Excel',
                        style: TextStyle(fontSize: 12)),
                  ]),
                ),
              ],
              child: _actionBtnChild(
                  icon: Icons.download_outlined,
                  label: 'Export',
                  hasChevron: true,
                  enabled: true),
            ),
            // Schedule.
            _actionBtn(
              icon: Icons.schedule_outlined,
              label: 'Schedule',
              onPressed: canEdit ? onSchedule : null,
            ),
            // Archive / Restore.
            if (isArchived)
              _actionBtn(
                icon: Icons.unarchive_outlined,
                label: 'Restore',
                onPressed: canEdit ? onRestore : null,
              )
            else
              _actionBtn(
                icon: Icons.archive_outlined,
                label: 'Archive',
                onPressed: canEdit ? onArchive : null,
              ),
            // Delete — disabled for canned reports (archive instead).
            _actionBtn(
              icon: Icons.delete_outline,
              label: 'Delete',
              onPressed:
                  (canEdit && !report.isCanned) ? onDelete : null,
              danger: !report.isCanned,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('Open report'),
              onPressed: () {
                Navigator.pop(context);
                context.go(
                    '/reports/${Uri.encodeComponent(report.id)}');
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool danger = false,
  }) {
    final enabled = onPressed != null;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: _actionBtnChild(
        icon: icon,
        label: label,
        enabled: enabled,
        danger: danger,
      ),
    );
  }

  Widget _actionBtnChild({
    required IconData icon,
    required String label,
    required bool enabled,
    bool danger = false,
    bool hasChevron = false,
  }) {
    final color = !enabled
        ? OpticsColors.textMuted
        : danger
            ? OpticsColors.danger
            : OpticsColors.textPrimary;
    final borderColor = !enabled
        ? OpticsColors.border.withValues(alpha: 0.5)
        : danger
            ? OpticsColors.danger.withValues(alpha: 0.4)
            : OpticsColors.border;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            )),
        if (hasChevron) ...[
          const SizedBox(width: 4),
          Icon(Icons.expand_more, size: 14, color: color),
        ],
      ]),
    );
  }

  Widget _meta(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: OpticsColors.textMuted,
            )),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(
                fontSize: 12, color: OpticsColors.textPrimary)),
      ],
    );
  }

  static String _fmtDate(DateTime d) {
    final l = d.toLocal();
    final mm = l.month.toString().padLeft(2, '0');
    final dd = l.day.toString().padLeft(2, '0');
    return '$mm/$dd/${l.year}';
  }
}

// ─────────────────────────────────────────────────────────────────
// Share dialog (tenant-wide toggle; per-user share is a fast-follow)
// ─────────────────────────────────────────────────────────────────
class ShareReportDialog extends ConsumerStatefulWidget {
  final Report report;
  const ShareReportDialog({required this.report});
  @override
  ConsumerState<ShareReportDialog> createState() => ShareReportDialogState();
}

class ShareReportDialogState extends ConsumerState<ShareReportDialog> {
  late bool _tenantWide = widget.report.sharedWithTenant;
  bool _busy = false;
  String? _err;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await ref.read(supabaseProvider).from('reports').update({
        'shared_with_tenant': _tenantWide,
      }).eq('id', widget.report.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: OpticsColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        side: const BorderSide(color: OpticsColors.border),
      ),
      child: SizedBox(
        width: 460,
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('SHARE REPORT',
                      style: OpticsTextStyles.sectionLabel),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(widget.report.name.toUpperCase(),
                  style: OpticsTextStyles.headingMd),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _tenantWide,
                onChanged: (v) => setState(() => _tenantWide = v),
                title: const Text('Share with everyone in this tenant',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'All members will be able to preview and run this report. Only you (or an Owner) can edit, archive, or delete it.',
                  style: TextStyle(
                      fontSize: 11, color: OpticsColors.textSecondary),
                ),
                activeColor: OpticsColors.accentCyan,
              ),
              const SizedBox(height: 4),
              const Text(
                'Sharing with specific users (instead of the whole tenant) '
                'will be available once team management is added — coming soon.',
                style: TextStyle(
                    fontSize: 11, color: OpticsColors.textMuted),
              ),
              if (_err != null) ...[
                const SizedBox(height: 8),
                Text(_err!,
                    style: const TextStyle(
                        color: OpticsColors.danger, fontSize: 12)),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _busy ? null : _save,
                    child: _busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.black),
                          )
                        : const Text('Save'),
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

// ─────────────────────────────────────────────────────────────────
// Page preview surface
// ---------------------------------------------------------------
// Renders a faithful schematic of the report at small scale:
// • Page 1's actual widgets are laid out at their saved grid
//   positions, scaled to fit the preview area.
// • Each widget is rendered as a typed mini-tile (KPI shows the
//   title + a big number placeholder, line/bar charts show a
//   characteristic silhouette, tables show grid lines, etc.).
// • Additional pages are shown as collapsed strip thumbnails.
// ─────────────────────────────────────────────────────────────────
class _PagePreviewSurface extends ConsumerWidget {
  final Report report;
  final List pages;
  final List<MapEntry<String, Report?>>? combinedReports;

  const _PagePreviewSurface({
    required this.report,
    required this.pages,
    required this.combinedReports,
  });

  /// Detect a v2 wizard report by either the persisted query_version
  /// (authoritative) or the presence of layout.builder.query_v2 (fallback).
  Map<String, dynamic>? _v2QueryJson() {
    final builder = (report.layout['builder'] as Map?)
            ?.cast<String, dynamic>() ??
        const {};
    final q = (builder['query_v2'] as Map?)?.cast<String, dynamic>();
    if (q != null) return q;
    if (report.queryVersion == 2) return <String, dynamic>{};
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v2 = _v2QueryJson();
    if (v2 != null && v2.isNotEmpty) {
      return Container(
        constraints: const BoxConstraints(minHeight: 320),
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: OpticsColors.canvas,
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
          border: Border.all(
              color: OpticsColors.border.withValues(alpha: 0.3)),
        ),
        child: _v2Preview(ref, v2),
      );
    }
    final dsAsync = ref.watch(restDataSourceIdProvider);
    return Container(
      constraints: const BoxConstraints(minHeight: 240),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: OpticsColors.canvas,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        border: Border.all(
            color: OpticsColors.border.withValues(alpha: 0.3)),
      ),
      child: dsAsync.when(
        loading: () => const SizedBox(
          height: 240,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, __) => _buildBody(null),
        data: (dsId) => _buildBody(dsId),
      ),
    );
  }

  Widget _v2Preview(WidgetRef ref, Map<String, dynamic> v2Json) {
    final dsAsync = ref.watch(restDataSourceIdProvider);
    return dsAsync.when(
      loading: () => const SizedBox(
        height: 320,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => SizedBox(
        height: 320,
        child: Center(
          child: SecureErrorText(
            genericMessage: 'Data source unavailable.',
            error: e,
          ),
        ),
      ),
      data: (dsId) {
        if (dsId == null) {
          return const SizedBox(
            height: 320,
            child: Center(
              child: Text('No connected data source.',
                  style: TextStyle(
                      fontSize: 11, color: OpticsColors.textMuted)),
            ),
          );
        }
        final query = CustomReportQueryV2.fromJson(v2Json);
        return SizedBox(
          height: 360,
          child: V2ReportView(query: query, dataSourceId: dsId),
        );
      },
    );
  }

  Widget _buildBody(String? dataSourceId) {
    if (combinedReports != null && combinedReports!.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.merge_type,
                  size: 14, color: OpticsColors.accentViolet),
              const SizedBox(width: 6),
              Text(
                'Composite preview \u00b7 ${combinedReports!.length} sources',
                style: const TextStyle(
                  fontSize: 11,
                  color: OpticsColors.textMuted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final e in combinedReports!) _sourceMini(e.key, e.value),
        ],
      );
    }

    if (pages.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${pages.length} page${pages.length == 1 ? '' : 's'}',
            style: const TextStyle(
              fontSize: 11,
              color: OpticsColors.textMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 10),
          _LivePagePreview(
            page: pages.first as Map<String, dynamic>,
            tenantId: report.tenantId,
            dataSourceId: dataSourceId,
            isFirstPage: true,
          ),
          if (pages.length > 1) ...[
            const SizedBox(height: 12),
            for (var i = 1; i < pages.length; i++) ...[
              if (i > 1) const SizedBox(height: 6),
              _LivePagePreview(
                page: pages[i] as Map<String, dynamic>,
                tenantId: report.tenantId,
                dataSourceId: dataSourceId,
                isFirstPage: false,
              ),
            ],
          ],
        ],
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_chart_outlined,
              size: 28, color: OpticsColors.textMuted),
          const SizedBox(height: 8),
          Text(
            report.isCanned
                ? 'Canned report \u2014 open to render with live data.'
                : 'Empty layout \u2014 open in Data Explorer to add widgets.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 11, color: OpticsColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _sourceMini(String id, Report? r) {
    final title = r?.name ?? 'Unknown report';
    final kind =
        r == null ? 'missing' : (r.isCanned ? 'Canned' : 'Custom');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        border: Border.all(
            color: OpticsColors.border.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 28,
            decoration: BoxDecoration(
              color: OpticsColors.accentViolet,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: OpticsColors.textPrimary,
                    )),
                Text(
                  r?.description ?? id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, color: OpticsColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(kind,
              style: const TextStyle(
                  fontSize: 10, color: OpticsColors.textMuted)),
        ],
      ),
    );
  }
}

/// Live-data preview of a single report page. Renders each widget through
/// [WidgetRenderer] (the same path the report viewer uses) so the preview
/// panel shows actual charts/tables/KPIs instead of schematic silhouettes.
class _LivePagePreview extends StatelessWidget {
  final Map<String, dynamic> page;
  final String tenantId;
  final String? dataSourceId;
  final bool isFirstPage;

  const _LivePagePreview({
    required this.page,
    required this.tenantId,
    required this.dataSourceId,
    required this.isFirstPage,
  });

  @override
  Widget build(BuildContext context) {
    final title = page['title'] as String? ?? '';
    final widgets =
        (page['widgets'] as List?)?.cast<Map>().toList() ?? const [];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        border: Border.all(
            color: OpticsColors.border.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  color: OpticsColors.textMuted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (widgets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  '(empty page)',
                  style: TextStyle(
                    fontSize: 11,
                    color: OpticsColors.textMuted.withValues(alpha: 0.7),
                  ),
                ),
              ),
            )
          else
            if (widgets.length == 1)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _renderWidget(widgets.first.cast<String, dynamic>(), forceTable: true)),
                  const SizedBox(width: 10),
                  Expanded(child: _renderWidget(widgets.first.cast<String, dynamic>(), forceChart: true)),
                ],
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: widgets
                    .map((w) => _renderWidget(w.cast<String, dynamic>()))
                    .toList(),
              ),
        ],
      ),
    );
  }

  Widget _renderWidget(Map<String, dynamic> w, {bool forceTable = false, bool forceChart = false, double? widthOverride}) {
    String type = w['type'] as String? ?? 'kpi';
    if (forceTable) {
      type = 'table';
    } else if (forceChart) {
      if (type == 'table' || type == 'kpi') type = 'barVertical';
    }
    
    final kind = WidgetKind.fromString(type);
    final binding =
        Map<String, dynamic>.from((w['binding'] as Map?) ?? const {});
    final settings =
        Map<String, dynamic>.from((w['settings'] as Map?) ?? const {});

    if (binding['brz'] is Map && dataSourceId != null) {
      final brz = Map<String, dynamic>.from(binding['brz'] as Map);
      brz['data_source_id'] = dataSourceId;
      binding['brz'] = brz;
    }

    final isKpi = kind == WidgetKind.kpi;
    final isMarkdown = kind == WidgetKind.markdown;
    final width = widthOverride ?? (isFirstPage
        ? (isKpi ? 180.0 : (isMarkdown ? 420.0 : 360.0))
        : (isKpi ? 140.0 : 260.0));
    final height = isFirstPage
        ? (isKpi ? 110.0 : (isMarkdown ? 110.0 : 240.0))
        : (isKpi ? 80.0 : 160.0);

    final model = WidgetModel(
      id: 'preview-${w['title'] ?? type}',
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

/// Schematic small-scale render of a single report page.
/// Widgets are placed at their saved grid positions; their type drives
/// a characteristic mini-shape (KPI tile / line chart / bar chart / pie
/// slice / table grid / markdown block / etc.).
class _MiniPage extends StatelessWidget {
  final Map<String, dynamic> page;
  final bool isFirstPage;
  const _MiniPage({required this.page, required this.isFirstPage});

  @override
  Widget build(BuildContext context) {
    final widgets =
        (page['widgets'] as List?)?.cast<Map>().toList() ?? const [];
    final title = page['title'] as String? ?? '';
    final pageHeight = isFirstPage ? 240.0 : 96.0;

    // Compute a virtual canvas size from the widget bounding box so the
    // mini-page scales to its content. Falls back to a 24x16 grid.
    int maxX = 24, maxY = 16;
    for (final w in widgets) {
      final wm = w.cast<String, dynamic>();
      final x = (wm['x'] as num?)?.toInt() ?? 0;
      final y = (wm['y'] as num?)?.toInt() ?? 0;
      final ww = (wm['w'] as num?)?.toInt() ?? 6;
      final wh = (wm['h'] as num?)?.toInt() ?? 4;
      if (x + ww > maxX) maxX = x + ww;
      if (y + wh > maxY) maxY = y + wh;
    }
    if (maxX < 12) maxX = 12;
    if (maxY < 8) maxY = 8;

    return Container(
      height: pageHeight,
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        border: Border.all(
            color: OpticsColors.border.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: isFirstPage ? 10 : 9,
                  color: OpticsColors.textMuted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Expanded(
            child: widgets.isEmpty
                ? Center(
                    child: Text(
                      '(empty page)',
                      style: TextStyle(
                        fontSize: isFirstPage ? 11 : 9,
                        color: OpticsColors.textMuted
                            .withValues(alpha: 0.7),
                      ),
                    ),
                  )
                : LayoutBuilder(builder: (ctx, constraints) {
                    final cellW = constraints.maxWidth / maxX;
                    final cellH = constraints.maxHeight / maxY;
                    return Stack(
                      children: [
                        for (final w in widgets)
                          _placedMini(
                              w.cast<String, dynamic>(), cellW, cellH),
                      ],
                    );
                  }),
          ),
        ],
      ),
    );
  }

  Widget _placedMini(
      Map<String, dynamic> w, double cellW, double cellH) {
    final x = (w['x'] as num?)?.toInt() ?? 0;
    final y = (w['y'] as num?)?.toInt() ?? 0;
    final ww = (w['w'] as num?)?.toInt() ?? 6;
    final wh = (w['h'] as num?)?.toInt() ?? 4;
    return Positioned(
      left: x * cellW + 1,
      top: y * cellH + 1,
      width: (ww * cellW - 2).clamp(0, double.infinity),
      height: (wh * cellH - 2).clamp(0, double.infinity),
      child: _MiniWidget(
        type: w['type'] as String? ?? 'kpi',
        title: w['title'] as String? ?? '',
        compact: !isFirstPage,
      ),
    );
  }
}

/// Schematic render of a single widget. Each type gets a distinctive
/// silhouette so a glance at the preview tells you what the report
/// actually looks like.
class _MiniWidget extends StatelessWidget {
  final String type;
  final String title;
  final bool compact;
  const _MiniWidget({
    required this.type,
    required this.title,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final t = type.toLowerCase();
    return Container(
      padding: EdgeInsets.all(compact ? 3 : 5),
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
            color: OpticsColors.border.withValues(alpha: 0.55)),
      ),
      child: ClipRect(child: _buildSilhouette(t)),
    );
  }

  Widget _buildSilhouette(String t) {
    if (t == 'kpi' || t == 'tile') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (title.isNotEmpty && !compact)
            _titleStrip(width: 0.55, opacity: 0.4),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '\u2014',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color:
                        OpticsColors.accentCyan.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (t.startsWith('line') || t.startsWith('area') || t == 'trend' ||
        t == 'combo') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) _titleStrip(width: 0.5, opacity: 0.4),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _LinePainter(
                  color: OpticsColors.accentCyan, filled: t.contains('area')),
            ),
          ),
        ],
      );
    }
    if (t.startsWith('bar')) {
      final horizontal = t.contains('horizontal');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) _titleStrip(width: 0.5, opacity: 0.4),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _BarPainter(
                color: OpticsColors.accentCyan,
                horizontal: horizontal,
              ),
            ),
          ),
        ],
      );
    }
    if (t == 'pie' || t == 'donut') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) _titleStrip(width: 0.5, opacity: 0.4),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _PiePainter(donut: t == 'donut'),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (t == 'table') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) _titleStrip(width: 0.4, opacity: 0.4),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _TablePainter(),
            ),
          ),
        ],
      );
    }
    if (t == 'markdown' || t == 'text') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _titleStrip(width: 0.85, opacity: 0.45),
          const SizedBox(height: 3),
          _titleStrip(width: 0.7, opacity: 0.35),
          const SizedBox(height: 3),
          _titleStrip(width: 0.55, opacity: 0.3),
        ],
      );
    }
    if (t == 'map') {
      return CustomPaint(
        size: Size.infinite,
        painter: _MapPainter(),
      );
    }
    // Fallback — unknown type.
    return Center(
      child: Icon(Icons.widgets_outlined,
          size: compact ? 10 : 14,
          color: OpticsColors.textMuted.withValues(alpha: 0.6)),
    );
  }

  Widget _titleStrip({required double width, required double opacity}) {
    return FractionallySizedBox(
      widthFactor: width,
      child: Container(
        height: 3,
        margin: const EdgeInsets.only(bottom: 3),
        decoration: BoxDecoration(
          color: OpticsColors.textPrimary.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(1.5),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final Color color;
  final bool filled;
  _LinePainter({required this.color, this.filled = false});
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 4 || size.height < 4) return;
    final pts = <Offset>[
      Offset(0, size.height * 0.7),
      Offset(size.width * 0.18, size.height * 0.55),
      Offset(size.width * 0.36, size.height * 0.62),
      Offset(size.width * 0.54, size.height * 0.35),
      Offset(size.width * 0.72, size.height * 0.45),
      Offset(size.width * 0.88, size.height * 0.18),
      Offset(size.width, size.height * 0.28),
    ];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    if (filled) {
      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
          fill, Paint()..color = color.withValues(alpha: 0.18));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.color != color || old.filled != filled;
}

class _BarPainter extends CustomPainter {
  final Color color;
  final bool horizontal;
  _BarPainter({required this.color, this.horizontal = false});
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 6 || size.height < 6) return;
    const heights = [0.55, 0.8, 0.4, 0.65, 0.95, 0.5];
    final paint = Paint()..color = color.withValues(alpha: 0.78);
    if (horizontal) {
      final rowH = size.height / heights.length;
      for (var i = 0; i < heights.length; i++) {
        canvas.drawRect(
          Rect.fromLTWH(
              0, i * rowH + 1, size.width * heights[i], rowH - 2),
          paint,
        );
      }
    } else {
      final colW = size.width / heights.length;
      for (var i = 0; i < heights.length; i++) {
        final h = size.height * heights[i];
        canvas.drawRect(
          Rect.fromLTWH(
              i * colW + 1, size.height - h, colW - 2, h),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) =>
      old.color != color || old.horizontal != horizontal;
}

class _PiePainter extends CustomPainter {
  final bool donut;
  _PiePainter({this.donut = false});
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 8 || size.height < 8) return;
    final r = size.shortestSide / 2 - 1;
    final c = Offset(size.width / 2, size.height / 2);
    const slices = [0.45, 0.25, 0.18, 0.12];
    final colors = [
      OpticsColors.accentCyan,
      OpticsColors.accentViolet,
      OpticsColors.success,
      OpticsColors.warning,
    ];
    var start = -3.14159 / 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = slices[i] * 6.2832;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        start,
        sweep,
        true,
        Paint()..color = colors[i].withValues(alpha: 0.8),
      );
      start += sweep;
    }
    if (donut) {
      canvas.drawCircle(
        c,
        r * 0.55,
        Paint()..color = OpticsColors.surfaceElevated,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter old) => old.donut != donut;
}

class _TablePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 6 || size.height < 6) return;
    final paint = Paint()
      ..color = OpticsColors.border.withValues(alpha: 0.6)
      ..strokeWidth = 0.8;
    // Header strip
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * 0.18),
      Paint()
        ..color = OpticsColors.accentCyan.withValues(alpha: 0.18),
    );
    final rows = (size.height / 8).floor().clamp(3, 8);
    final cols = (size.width / 14).floor().clamp(2, 5);
    final rowH = size.height / rows;
    final colW = size.width / cols;
    for (var i = 1; i < rows; i++) {
      canvas.drawLine(
          Offset(0, i * rowH), Offset(size.width, i * rowH), paint);
    }
    for (var j = 1; j < cols; j++) {
      canvas.drawLine(
          Offset(j * colW, 0), Offset(j * colW, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TablePainter old) => false;
}

class _MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 6 || size.height < 6) return;
    final base = Paint()
      ..color = OpticsColors.accentCyan.withValues(alpha: 0.1);
    canvas.drawRect(Offset.zero & size, base);
    // Crosshair to suggest geographic view.
    final ln = Paint()
      ..color = OpticsColors.border.withValues(alpha: 0.6)
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(0, size.height / 2),
        Offset(size.width, size.height / 2), ln);
    canvas.drawLine(Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height), ln);
    final dot = Paint()
      ..color = OpticsColors.accentCyan.withValues(alpha: 0.85);
    for (final p in [
      Offset(size.width * 0.3, size.height * 0.4),
      Offset(size.width * 0.55, size.height * 0.65),
      Offset(size.width * 0.72, size.height * 0.3),
    ]) {
      canvas.drawCircle(p, 1.8, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) => false;
}

// ─────────────────────────────────────────────────────────────────
// Schedule dialog
// ---------------------------------------------------------------
// Lets the user create / disable / delete delivery schedules for a
// (tenant-scoped, non-canned) report. Backed by the `schedules`
// table + the `schedule-run` Edge Function.
// ─────────────────────────────────────────────────────────────────
class _ScheduleDialog extends ConsumerStatefulWidget {
  final Report report;
  const _ScheduleDialog({required this.report});
  @override
  ConsumerState<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends ConsumerState<_ScheduleDialog> {
  String _cadence = 'daily_8am';
  bool _pdf = true;
  bool _xlsx = false;
  final _recipientsCtl = TextEditingController();
  bool _saving = false;
  String? _err;

  Future<List<Map<String, dynamic>>>? _listFuture;

  @override
  void initState() {
    super.initState();
    _listFuture = ref.read(repoProvider).listSchedules(widget.report.id);
  }

  @override
  void dispose() {
    _recipientsCtl.dispose();
    super.dispose();
  }

  // Cadence presets → cron expressions (UTC).
  static const Map<String, ({String label, String cron})> _cadencePresets = {
    'hourly': (label: 'Every hour', cron: '0 * * * *'),
    'daily_8am': (label: 'Daily at 8:00 AM UTC', cron: '0 8 * * *'),
    'weekly_mon_8am':
        (label: 'Weekly — Monday 8:00 AM UTC', cron: '0 8 * * 1'),
    'monthly_1st_8am':
        (label: 'Monthly — 1st at 8:00 AM UTC', cron: '0 8 1 * *'),
  };

  Future<void> _save() async {
    final raw = _recipientsCtl.text.trim();
    final recipients = raw
        .split(RegExp(r'[\s,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final formats = <String>[
      if (_pdf) 'pdf',
      if (_xlsx) 'xlsx',
    ];
    if (recipients.isEmpty) {
      setState(() => _err = 'Add at least one email recipient.');
      return;
    }
    if (formats.isEmpty) {
      setState(() => _err = 'Pick at least one format (PDF / Excel).');
      return;
    }
    setState(() {
      _saving = true;
      _err = null;
    });
    try {
      final cron = _cadencePresets[_cadence]!.cron;
      await ref.read(repoProvider).createSchedule(
            reportId: widget.report.id,
            cron: cron,
            recipients: recipients,
            format: formats,
          );
      _recipientsCtl.clear();
      setState(() {
        _listFuture =
            ref.read(repoProvider).listSchedules(widget.report.id);
      });
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleEnabled(String id, bool v) async {
    await ref.read(repoProvider).setScheduleEnabled(id, v);
    setState(() {
      _listFuture =
          ref.read(repoProvider).listSchedules(widget.report.id);
    });
  }

  Future<void> _delete(String id) async {
    await ref.read(repoProvider).deleteSchedule(id);
    setState(() {
      _listFuture =
          ref.read(repoProvider).listSchedules(widget.report.id);
    });
  }

  String _cadenceLabelForCron(String cron) {
    for (final entry in _cadencePresets.entries) {
      if (entry.value.cron == cron) return entry.value.label;
    }
    return cron;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: OpticsColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        side: const BorderSide(color: OpticsColors.border),
      ),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Text('SCHEDULE REPORT',
                      style: OpticsTextStyles.sectionLabel),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(widget.report.name.toUpperCase(), style: OpticsTextStyles.headingMd),
              const SizedBox(height: 4),
              const Text(
                'Delivered by email as a PDF and/or Excel attachment. '
                'Cron times are UTC.',
                style: TextStyle(
                    fontSize: 11, color: OpticsColors.textMuted),
              ),
              const SizedBox(height: 16),
              const Text('CADENCE',
                  style: OpticsTextStyles.sectionLabel),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _cadence,
                isDense: true,
                items: _cadencePresets.entries
                    .map((e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value.label,
                              style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _cadence = v ?? _cadence),
              ),
              const SizedBox(height: 12),
              const Text('FORMATS',
                  style: OpticsTextStyles.sectionLabel),
              const SizedBox(height: 4),
              Row(
                children: [
                  _fmtCheck(
                      label: 'PDF',
                      value: _pdf,
                      onChanged: (v) =>
                          setState(() => _pdf = v ?? _pdf)),
                  const SizedBox(width: 16),
                  _fmtCheck(
                      label: 'Excel',
                      value: _xlsx,
                      onChanged: (v) =>
                          setState(() => _xlsx = v ?? _xlsx)),
                ],
              ),
              const SizedBox(height: 12),
              const Text('RECIPIENTS',
                  style: OpticsTextStyles.sectionLabel),
              const SizedBox(height: 6),
              TextField(
                controller: _recipientsCtl,
                decoration: const InputDecoration(
                  hintText: 'email@company.com, another@company.com',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              if (_err != null) ...[
                const SizedBox(height: 8),
                Text(_err!,
                    style: const TextStyle(
                        color: OpticsColors.danger, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Add schedule'),
                  onPressed: _saving ? null : _save,
                ),
              ),
              const SizedBox(height: 16),
              const Text('EXISTING SCHEDULES',
                  style: OpticsTextStyles.sectionLabel),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _listFuture,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(12),
                        child: Center(
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final rows = snap.data ?? const [];
                    if (rows.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'No schedules yet.',
                          style: TextStyle(
                              fontSize: 12,
                              color: OpticsColors.textMuted),
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: OpticsColors.border
                              .withValues(alpha: 0.3)),
                      itemBuilder: (_, i) {
                        final s = rows[i];
                        final cron = s['cron'] as String? ?? '';
                        final enabled = (s['enabled'] as bool?) ?? true;
                        final recipients =
                            (s['recipients'] as List?)?.join(', ') ?? '';
                        final fmts =
                            (s['format'] as List?)?.join(' · ') ?? '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(_cadenceLabelForCron(cron),
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600)),
                                    Text(
                                      '$recipients · $fmts',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: OpticsColors.textMuted),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: enabled,
                                onChanged: (v) =>
                                    _toggleEnabled(s['id'] as String, v),
                                activeColor: OpticsColors.accentCyan,
                              ),
                              IconButton(
                                tooltip: 'Delete schedule',
                                icon: const Icon(Icons.delete_outline,
                                    size: 16,
                                    color: OpticsColors.danger),
                                onPressed: () =>
                                    _delete(s['id'] as String),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fmtCheck({
    required String label,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            onChanged: onChanged,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            activeColor: OpticsColors.accentCyan,
            side: const BorderSide(color: OpticsColors.textMuted),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}



// ─────────────────────────────────────────────────────────────────
// Top-Level Helpers for Export and Share
// ─────────────────────────────────────────────────────────────────

void showToastHelper(BuildContext ctx, String msg) {
  if (!ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
}

Future<String?> cloneReportHelper(BuildContext ctx, WidgetRef ref, Report r, {required String purpose}) async {
  final client = ref.read(supabaseProvider);
  final tid = client.auth.currentUser?.appMetadata['active_tenant_id'] as String?;
  final body = <String, dynamic>{'purpose': purpose};
  if (r.id.startsWith('lib:')) {
    body['library_item_id'] = r.id.substring(4);
  } else {
    body['report_id'] = r.id;
  }
  final res = await client.functions.invoke(
    'clone-canned-report',
    body: body,
    headers: tid == null ? {} : {'x-optics-tenant': tid},
  );
  final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
  return (data['report_id'] ?? data['id']) as String?;
}

Future<void> downloadToDiskHelper(BuildContext ctx, {required String url, required Report report, required String format}) async {
  final fmtLabel = format.toUpperCase();
  final safeName = report.name.replaceAll(RegExp(r'[^A-Za-z0-9 _\-\.]'), '').trim();
  final defaultFileName = '${safeName.isEmpty ? 'optics-report' : safeName}.$format';

  // On web, use url_launcher to open the signed URL.
  if (kIsWeb) {
    final uri = Uri.parse(url);
    try {
      // By using platformDefault, it avoids strict popup blocking on some browsers.
      await launchUrl(uri);
      if (ctx.mounted) showToastHelper(ctx, '$fmtLabel download started.');
    } catch (e) {
      if (ctx.mounted) showToastHelper(ctx, '$fmtLabel download failed: $e');
    }
    return;
  }

  // Desktop/Mobile: Fetch bytes and save via FilePicker.
  final resp = await HttpClient().getUrl(Uri.parse(url));
  final httpResp = await resp.close();
  if (httpResp.statusCode != 200) {
    if (ctx.mounted) showToastHelper(ctx, '$fmtLabel download failed (${httpResp.statusCode})');
    return;
  }
  final bytes = <int>[];
  await for (final chunk in httpResp) { bytes.addAll(chunk); }

  String? savePath;
  try {
    savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save $fmtLabel',
      fileName: defaultFileName,
      type: format == 'pdf' ? FileType.custom : FileType.custom,
      allowedExtensions: [format],
    );
  } catch (_) { savePath = null; }
  
  if (savePath == null) {
    if (ctx.mounted) showToastHelper(ctx, '$fmtLabel save cancelled.');
    return;
  }
  if (!savePath.toLowerCase().endsWith('.$format')) savePath = '$savePath.$format';
  await File(savePath).writeAsBytes(bytes, flush: true);
  if (ctx.mounted) showToastHelper(ctx, '$fmtLabel saved: $savePath');
}

Future<void> exportReportHelper(BuildContext ctx, WidgetRef ref, Report r, String format) async {
  final fmtLabel = format.toUpperCase();
  showToastHelper(ctx, 'Generating $fmtLabel for "${r.name}"...');

  String reportId = r.id;
  try {
    if (r.isCanned) {
      final handle = await cloneReportHelper(ctx, ref, r, purpose: 'operational');
      if (handle == null) {
        if (ctx.mounted) showToastHelper(ctx, '$fmtLabel export failed: handle');
        return;
      }
      reportId = handle;
    }
    final repo = ref.read(repoProvider);
    final path = await repo.exportReport(reportId: reportId, format: format);
    if (path == null) {
      if (ctx.mounted) showToastHelper(ctx, '$fmtLabel export failed.');
      return;
    }
    final url = await repo.signedExportUrl(path, expiresInSeconds: 3600);
    if (url == null || url.isEmpty) {
      if (ctx.mounted) showToastHelper(ctx, 'Could not sign download URL.');
      return;
    }
    await downloadToDiskHelper(ctx, url: url, report: r, format: format);
  } catch (e) {
    if (ctx.mounted) showToastHelper(ctx, '$fmtLabel export failed: $e');
  }
}

Future<void> shareReportHelper(BuildContext ctx, WidgetRef ref, Report r) async {
  await showDialog<void>(
    context: ctx,
    builder: (_) => ShareReportDialog(report: r),
  );
  ref.refresh(reportsProvider);
}
