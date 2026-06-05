// Optics — V2 report viewer (ADR-0013, Phase B).
//
// Runs a saved `custom_report_query_v2` JSON through the `rds_execute_query`
// RPC and renders the configured visualization. Read-only counterpart to
// the wizard's right-side preview panel.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/supabase_repo.dart';
import '../../../design/theme.dart';
import 'custom_report_query_v2.dart';

class _V2Args {
  final String dataSourceId;
  final Map<String, dynamic> queryJson;
  const _V2Args({required this.dataSourceId, required this.queryJson});

  @override
  bool operator ==(Object other) =>
      other is _V2Args &&
      other.dataSourceId == dataSourceId &&
      _mapEqual(other.queryJson, queryJson);

  @override
  int get hashCode => Object.hash(dataSourceId, queryJson.toString());
}

bool _mapEqual(Map a, Map b) => a.toString() == b.toString();

final _v2RowsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, _V2Args>((ref, args) async {
  return ref.read(repoProvider).rdsExecuteQuery(
        dataSourceId: args.dataSourceId,
        query: args.queryJson,
        preview: false,
      );
});

class V2ReportView extends ConsumerWidget {
  final CustomReportQueryV2 query;
  final String dataSourceId;
  const V2ReportView({
    super.key,
    required this.query,
    required this.dataSourceId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = _V2Args(
      dataSourceId: dataSourceId,
      queryJson: query.toJson(),
    );
    final rowsAsync = ref.watch(_v2RowsProvider(args));
    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('$e',
            style: const TextStyle(color: OpticsColors.danger)),
      ),
      data: (rows) => _render(rows),
    );
  }

  Widget _render(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: OpticsColors.surface,
          border: Border.all(color: OpticsColors.border),
          borderRadius: BorderRadius.circular(OpticsRadii.md),
        ),
        alignment: Alignment.center,
        child: const Text('No rows returned.',
            style: OpticsTextStyles.bodySm),
      );
    }
    switch (query.viz.chartType) {
      case 'kpi':
      case 'gauge':
        return _kpi(rows);
      case 'bar':
      case 'hbar':
      case 'combo':
        return _bar(rows, horizontal: query.viz.chartType == 'hbar');
      case 'line':
      case 'area':
        return _line(rows, area: query.viz.chartType == 'area');
      case 'pie':
      case 'donut':
        return _pie(rows, donut: query.viz.chartType == 'donut');
      default:
        return _table(rows);
    }
  }

  Widget _shell({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(OpticsSpacing.lg),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        border: Border.all(color: OpticsColors.border),
        borderRadius: BorderRadius.circular(OpticsRadii.md),
      ),
      child: child,
    );
  }

  Widget _table(List<Map<String, dynamic>> rows) {
    // Render the v2 "Table" viz with the same visual language used by the
    // dashboard widget table (see widget_renderer._singleSeriesTable):
    //   • Rank column ("#")
    //   • Label column with a colored palette dot
    //   • Numeric columns right-aligned, colored by the row's palette index
    //   • Trailing "Share" column derived from the first numeric column
    //   • Alternating row backgrounds, uppercase header row
    //
    // This keeps Table behavior consistent regardless of whether the report
    // came from the legacy widget pipeline or the v2 wizard.
    //
    // Column order: use query.columns to drive both the display order and the
    // header labels.  Postgres jsonb always returns keys alphabetically, so we
    // cannot rely on row key order.
    //
    // query.columns[i].column  = the actual row-key name  (e.g. "source")
    // query.columns[i].alias   = the display header label  (e.g. "Source")
    //
    // Build parallel lists: headers (display names) and rowKeys (lookup keys).
    final List<String> headers;      // display names shown in the header row
    final List<String> lookupKeys;   // keys used to read values from each row

    if (query.columns.isNotEmpty) {
      final available = rows.first.keys.toSet();
      final cols = query.columns
          .where((c) => available.contains(c.column))
          .toList();
      headers   = cols.map((c) => c.alias).toList();
      lookupKeys = cols.map((c) => c.column).toList();
      // Append any extra keys from the row that aren't in the payload columns
      // (e.g. internal sort helpers the view adds).
      for (final k in rows.first.keys) {
        if (!lookupKeys.contains(k)) {
          lookupKeys.add(k);
          headers.add(k);
        }
      }
    } else {
      // Legacy reports with no columns spec — fall back to row key order.
      final keys = rows.first.keys.toList();
      headers    = keys;
      lookupKeys = keys;
    }

    // Identify which columns are numeric so we can right-align them and pick
    // a "primary numeric" for the Share computation.
    final numericCols = <String>{};
    for (final h in headers) {
      // A column is numeric if every non-null value parses to a number.
      var hasValue = false;
      var allNum = true;
      for (final r in rows) {
        final v = r[h];
        if (v == null) continue;
        hasValue = true;
        if (_toDouble(v) == null) {
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
        grandTotal += _toDouble(r[primaryNumeric]) ?? 0;
      }
    }
    final showShare = primaryNumericKey.isNotEmpty && grandTotal > 0;

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

    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header bar
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
                    flex: _colFlex(headers[i], i),
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
                  for (int rank = 0; rank < rows.length; rank++)
                    _tableRow(
                      rank: rank,
                      row: rows[rank],
                      headers: headers,
                      lookupKeys: lookupKeys,
                      numericCols: numericCols,
                      primaryNumericKey: primaryNumericKey,
                      grandTotal: grandTotal,
                      showShare: showShare,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableRow({
    required int rank,
    required Map<String, dynamic> row,
    required List<String> headers,
    required List<String> lookupKeys,
    required Set<String> numericCols,
    required String primaryNumericKey,
    required double grandTotal,
    required bool showShare,
  }) {
    final palette = OpticsColors.chartPalette;
    final rowColor = palette[rank % palette.length];
    final isOdd = rank % 2 == 1;
    final share = showShare
        ? ((_toDouble(row[primaryNumericKey]) ?? 0) / grandTotal * 100)
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
              flex: _colFlex(headers[i], i),
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
                            row[lookupKeys[i]]?.toString() ?? '',
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
                      row[lookupKeys[i]]?.toString() ?? '',
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

  Widget _kpi(List<Map<String, dynamic>> rows) {
    final y = query.viz.y;
    final first = rows.first;
    final v = y != null && first.containsKey(y) ? first[y] : first.values.first;
    return _shell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text((y ?? '').toUpperCase(),
              style: OpticsTextStyles.sectionLabel),
          const SizedBox(height: OpticsSpacing.md),
          Text(v?.toString() ?? '—', style: OpticsTextStyles.kpiNumber),
        ],
      ),
    );
  }

  Widget _bar(List<Map<String, dynamic>> rows, {bool horizontal = false}) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null || y == null) return _table(rows);
    final bars = rows
        .map((r) {
          final yv = _toDouble(r[y]);
          if (yv == null) return null;
          return MapEntry(r[x]?.toString() ?? '', yv);
        })
        .whereType<MapEntry<String, double>>()
        .toList();
    if (bars.isEmpty) return _table(rows);
    return _shell(
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
                reservedSize: 44,
                getTitlesWidget: (v, _) => Text(
                  v.toStringAsFixed(0),
                  style: OpticsTextStyles.bodySm.copyWith(fontSize: 10),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= bars.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      bars[i].key.length > 12
                          ? '${bars[i].key.substring(0, 12)}…'
                          : bars[i].key,
                      style: OpticsTextStyles.bodySm.copyWith(fontSize: 10),
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

  Widget _line(List<Map<String, dynamic>> rows, {bool area = false}) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null || y == null) return _table(rows);
    final pts = <FlSpot>[];
    for (int i = 0; i < rows.length; i++) {
      final yv = _toDouble(rows[i][y]);
      if (yv != null) pts.add(FlSpot(i.toDouble(), yv));
    }
    if (pts.isEmpty) return _table(rows);
    return _shell(
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
                      color:
                          OpticsColors.accentCyan.withValues(alpha: 0.18),
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

  Widget _pie(List<Map<String, dynamic>> rows, {bool donut = false}) {
    final x = query.viz.x;
    final y = query.viz.y;
    if (x == null || y == null) return _table(rows);
    final slices = rows
        .map((r) {
          final yv = _toDouble(r[y]);
          if (yv == null) return null;
          return MapEntry(r[x]?.toString() ?? '', yv);
        })
        .whereType<MapEntry<String, double>>()
        .toList();
    if (slices.isEmpty) return _table(rows);
    return _shell(
      child: PieChart(
        PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: donut ? 60 : 0,
          sections: [
            for (int i = 0; i < slices.length; i++)
              PieChartSectionData(
                value: slices[i].value,
                color: OpticsColors.chartPalette[
                    i % OpticsColors.chartPalette.length],
                title: slices[i].key.length > 10
                    ? '${slices[i].key.substring(0, 10)}…'
                    : slices[i].key,
                radius: 100,
                titleStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Returns the flex weight for a table column.
/// "Searched Product" and similar long-text columns get extra width;
/// short fixed-format columns (Date, Price, Source, etc.) stay compact.
int _colFlex(String header, int index) {
  const wideColumns = {
    'Searched Product',
    'Product',
    'Description',
    'Item Description',
    'Notes',
    'Comment',
  };
  if (wideColumns.contains(header)) return 5;
  if (index == 0) return 3;
  return 2;
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
