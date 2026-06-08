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
    // Column order is driven by query.columns (the payload's explicit list).
    // Postgres jsonb always returns keys in alphabetical order, so we MUST NOT
    // use rows.first.keys for ordering.
    //
    // headers[i]    = display label shown in the header row  (alias, e.g. "Source")
    // lookupKeys[i] = actual row-key used to read the value  (column, e.g. "source")
    final List<String> headers;
    final List<String> lookupKeys;

    if (query.columns.isNotEmpty) {
      // rds_execute_query returns rows keyed by alias (e.g. "Source", "Buyer")
      // because the SQL uses: SELECT t.source as "Source", ...
      // So both the display header AND the lookup key must use c.alias.
      final available = rows.first.keys.toSet();
      final cols = query.columns
          .where((c) => available.contains(c.alias))
          .toList();
      if (cols.isNotEmpty) {
        headers    = cols.map((c) => c.alias).toList();
        lookupKeys = cols.map((c) => c.alias).toList();
      } else {
        // Fallback: no alias matches — use raw row key order
        final keys = rows.first.keys.toList();
        headers    = keys;
        lookupKeys = keys;
      }
    } else {
      // Legacy reports with no columns spec — fall back to row key order.
      final keys = rows.first.keys.toList();
      headers    = keys;
      lookupKeys = keys;
    }

    // Identify numeric columns using lookupKeys (the actual row keys).
    // numericCols stores the DISPLAY HEADER name so the header row can check it.
    final numericCols = <String>{};
    for (int i = 0; i < lookupKeys.length; i++) {
      final key = lookupKeys[i];
      var hasValue = false;
      var allNum = true;
      for (final r in rows) {
        final v = r[key];
        if (v == null) continue;
        hasValue = true;
        if (_toDouble(v) == null) {
          allNum = false;
          break;
        }
      }
      if (hasValue && allNum) numericCols.add(headers[i]);
    }

    // primaryNumeric = display header of first numeric column.
    // primaryNumericKey = lookup key for that column (used to read row values).
    final primaryNumeric =
        headers.firstWhere(numericCols.contains, orElse: () => '');
    final primaryNumericKey = primaryNumeric.isNotEmpty
        ? lookupKeys[headers.indexOf(primaryNumeric)]
        : '';
    double grandTotal = 0;
    if (primaryNumericKey.isNotEmpty) {
      for (final r in rows) {
        grandTotal += _toDouble(r[primaryNumericKey]) ?? 0;
      }
    }
    final showShare = query.showShare && primaryNumericKey.isNotEmpty && grandTotal > 0;

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
                    child: headerCell(headers[i]),
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
                            _formatCellValue(headers[i], row[lookupKeys[i]]),
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
                      _formatCellValue(headers[i], row[lookupKeys[i]]),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: OpticsColors.textPrimary,
                      ),
                      textAlign: TextAlign.left,
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

/// Columns that should be rendered as $xx,xxx.xx currency values.
const _moneyHeaders = {'AOV', 'Total Purchases', 'Total Sales'};

/// Maps raw DB values to display-friendly labels for specific columns.
String _formatCellValue(String header, dynamic value) {
  final raw = value?.toString() ?? '';
  if (header == 'Dispute Type') {
    const eventLabels = {
      'edit_line':    'Qty Change',
      'cancel_order': 'Order Cancel',
      'cancel_line':  'Line Cancel',
      'add_line':     'Line Added',
      'deliver_by':   'Delivery Date Change',
      'deliver_to':   'Destination Change',
      'destination':  'Destination Change',
    };
    return eventLabels[raw] ?? raw;
  }
  if (_moneyHeaders.contains(header)) {
    final n = double.tryParse(raw.replaceAll(RegExp(r'[^\d.]'), ''));
    if (n != null) {
      final parts = n.toStringAsFixed(2).split('.');
      final intPart = parts[0];
      final decPart = parts[1];
      final buffer = StringBuffer();
      int count = 0;
      for (int j = intPart.length - 1; j >= 0; j--) {
        if (count > 0 && count % 3 == 0) buffer.write(',');
        buffer.write(intPart[j]);
        count++;
      }
      return '\${buffer.toString().split('').reversed.join()}.$decPart';
    }
  }
  return raw;
}

/// Returns the flex weight for a table column.
int _colFlex(String header, int index) {
  const flexMap = {
    // Price Search Live Feed
    'Source':           2,
    'Searched Product': 8,
    'Price':            2,
    'Date':             2,
    // Unclaimed Orders
    'Purchase Date':    4,
    'Delivery Date':    4,
    'Order#':           3,
    'Company':          6,
    'Buyer':            4,
    'Deliver To':       6,
    'Order Value':      3,
    // Orders in Dispute
    'Dispute Type':     6,
    'Buyer Company':    6,
    'Seller Company':   6,
    'Seller':           3,
    'Status':           7,
    // All Buyers
    'Buyer':            5,
    'Purchases':        3,
    'AOV':              4,
    'Total Purchases':  5,
    // All Sellers
    'Seller':           5,
    'Seller Company':   6,
    'Sales':            3,
    'Total Sales':      5,
    // Generic fallbacks for other reports
    'Product':          8,
    'Description':      8,
    'Item Description': 8,
    'Notes':            6,
    'Comment':          6,
  };
  return flexMap[header] ?? (index == 0 ? 2 : 2);
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}
