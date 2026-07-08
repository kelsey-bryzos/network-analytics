/// Optics — Canned Metric → query_v2 Translator
///
/// Pure-Dart translator that produces a `CustomReportQueryV2` faithful to
/// what a canned `binding.brz.metric` renders today via
/// `widget-data-bryzos`. Used by:
///
///   1. Clone & Edit — when a Bryzos user clones a canned library item,
///      the clone Edge Function hydrates `layout.builder.query_v2` with the
///      translator's output so the clone opens in the v2 builder / v2 report
///      view instead of the legacy widget path.
///
///   2. Widget SQL tab (Bryzos-only) — the raw-SQL editor pre-fills its
///      placeholder text with the generated SQL so a user can see exactly
///      what the canned metric is doing before they edit it.
///
/// **Path A scope:** first vertical slice ships `revenue_by_month` only.
/// Other metrics return `null` and callers must gracefully fall back to the
/// legacy `binding.brz.metric` path.
///
/// **Non-goals for slice #1:**
///   * Comparison window / "vs prior period" delta — the widget-data-bryzos
///     path emits `_meta.total/prior/delta` alongside the series; we render
///     only the current window here. Delta indicator returns in a follow-up
///     slice once `V2ReportView` learns the comparison_window response shape.
library;

import 'custom_report_query_v2.dart';

/// Result of a translation attempt.
class CannedTranslation {
  /// The equivalent query_v2 spec. Non-null when the metric is supported.
  final CustomReportQueryV2 query;

  /// Human-readable note describing anything the widget does *after* the
  /// RPC returns (e.g. rescaling to $M/$K). Informational only.
  final String? postFetchNote;

  const CannedTranslation({required this.query, this.postFetchNote});
}

/// Registry of supported canned metrics. Add entries here (alphabetically)
/// as slices land.
const Set<String> kSupportedCannedMetrics = {
  'bpns_by_company',
  'bpns_by_user',
  'cancelled_orders_by_company',
  'cancelled_orders_by_user',
  'cancelled_orders_list',
  'count_companies',
  'count_orders',
  'count_users',
  'credit_enabled_companies_kpi',
  'orders_by_month',
  'orders_by_status',
  'orders_recent_list',
  'quotes_by_company',
  'quotes_by_user',
  'revenue_by_month',
  'searches_by_company',
  'searches_by_user',
  'sum_po_price',
  'top_companies_orders',
  'top_companies_revenue',
  'users_by_type',
  'users_recent_list',
};

/// Default top-N size when a widget hasn't stored its own `max_items` /
/// `settings.maxItems`. Mirrors `widget-data-bryzos`'s default.
const int kDefaultTopN = 10;

/// Returns true when [metric] has a query_v2 translation available.
bool isCannedMetricTranslatable(String? metric) {
  if (metric == null) return false;
  return kSupportedCannedMetrics.contains(metric);
}

/// Translate a canned `binding.brz.metric` into a `CustomReportQueryV2`.
/// Returns null when the metric is not yet supported.
///
/// The [timeRange] argument mirrors the widget's stored `settings.timeRange`
/// / `brz.time_range`. It is preserved on the output as a viz hint but not
/// used to compute a fixed date filter — the v2 render path applies the
/// wizard's active time range at execution time.
CannedTranslation? translateCannedMetric({
  required String metric,
  String? timeRange,
  int? maxItems,
}) {
  switch (metric) {
    case 'bpns_by_company':
      return _bpnsByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'bpns_by_user':
      return _bpnsByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'cancelled_orders_by_company':
      return _cancelledOrdersByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'cancelled_orders_by_user':
      return _cancelledOrdersByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'cancelled_orders_list':
      return _cancelledOrdersList(maxItems: maxItems ?? kDefaultTopN);
    case 'count_companies':
      return _countCompanies();
    case 'count_orders':
      return _countOrders();
    case 'count_users':
      return _countUsers();
    case 'credit_enabled_companies_kpi':
      return _creditEnabledCompaniesKpi();
    case 'orders_by_month':
      return _ordersByMonth();
    case 'orders_by_status':
      return _ordersByStatus();
    case 'orders_recent_list':
      return _ordersRecentList(maxItems: maxItems ?? kDefaultTopN);
    case 'quotes_by_company':
      return _quotesByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'quotes_by_user':
      return _quotesByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'revenue_by_month':
      return _revenueByMonth();
    case 'searches_by_company':
      return _searchesByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'searches_by_user':
      return _searchesByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'sum_po_price':
      return _sumPoPrice();
    case 'top_companies_orders':
      return _topCompaniesOrders(maxItems: maxItems ?? kDefaultTopN);
    case 'top_companies_revenue':
      return _topCompaniesRevenue(maxItems: maxItems ?? kDefaultTopN);
    case 'users_by_type':
      return _usersByType();
    case 'users_recent_list':
      return _usersRecentList(maxItems: maxItems ?? kDefaultTopN);
    default:
      return null;
  }
}

// ─── Slice #1: revenue_by_month ──────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date`, `buyer_po_price` from user_purchase_order
//   • buckets by month, sums `buyer_po_price`
//   • scales total to $M / $K / $ based on magnitude
//   • emits `_data`, `_labels`, `_unit`, `_yLabel="Revenue"`,
//     `_meta.{total,prior,delta,totalFormatted}`
//
// query_v2 equivalent (Path A — current window only, no comparison_window):
//
//   SELECT date_trunc('month', t."created_date") AS "bucket_start",
//          to_char(date_trunc('month', t."created_date"), 'Mon YYYY')
//              AS "bucket_label",
//          SUM(t."buyer_po_price") AS "Revenue"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//   GROUP BY date_trunc('month', t."created_date")
//   ORDER BY "bucket_start" ASC;
//
// Rescaling ($M / $K) is intentionally NOT applied server-side — the widget
// today rescales for display only; keeping raw dollars in the RPC output
// makes the number editable in the wizard and matches the schema mirror.
CannedTranslation _revenueByMonth() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression: 'date_trunc(\'month\', t."created_date")',
        alias: 'bucket_start',
      ),
      ComputedColumn(
        expression:
            'to_char(date_trunc(\'month\', t."created_date"), \'Mon YYYY\')',
        alias: 'bucket_label',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        fn: 'sum',
        alias: 'Revenue',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('bucket_start'),
    ],
    orderBy: [
      OrderBySpec(alias: 'bucket_start', dir: 'ASC'),
    ],
    viz: VizSpec(
      chartType: 'line',
      x: 'bucket_label',
      y: 'Revenue',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally rescales the total to \$M/\$K for '
        'display and emits a prior-period delta in _meta. Both are display-'
        'only and not reproduced by the v2 render path in this slice.',
  );
}

// ─── Slice #2: orders_by_month ───────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date` from user_purchase_order
//   • buckets by month, counts rows per bucket
//   • emits `_data`, `_labels`, `_unit=""`, `_yLabel="Orders"`,
//     `_meta.{total,prior,delta}`
//
// query_v2 equivalent (Path A — current window only, no comparison_window):
//
//   SELECT date_trunc('month', t."created_date") AS "bucket_start",
//          to_char(date_trunc('month', t."created_date"), 'Mon YYYY')
//              AS "bucket_label",
//          count(*) AS "Orders"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//   GROUP BY date_trunc('month', t."created_date")
//   ORDER BY "bucket_start" ASC;
CannedTranslation _ordersByMonth() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression: 'date_trunc(\'month\', t."created_date")',
        alias: 'bucket_start',
      ),
      ComputedColumn(
        expression:
            'to_char(date_trunc(\'month\', t."created_date"), \'Mon YYYY\')',
        alias: 'bucket_label',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Orders',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('bucket_start'),
    ],
    orderBy: [
      OrderBySpec(alias: 'bucket_start', dir: 'ASC'),
    ],
    viz: VizSpec(
      chartType: 'line',
      x: 'bucket_label',
      y: 'Orders',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally emits a prior-period delta in _meta. '
        'Display-only and not reproduced by the v2 render path in this slice.',
  );
}

// ─── Slice #3: top_companies_orders ──────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date`, `buyer_company_name` from user_purchase_order
//   • counts orders per buyer_company_name (null → "(unknown)")
//   • sorts DESC by count, slices top `max_items` (default 10)
//   • emits `_labels` (company names), `_data` (counts),
//     `_col1="Company"`, `_col2="Orders"`, `_yLabel="Orders"`.
//
// query_v2 equivalent (Path A — current window only):
//
//   SELECT coalesce(t."buyer_company_name",'(unknown)') AS "Company",
//          count(*)                                     AS "Orders"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//   GROUP BY coalesce(t."buyer_company_name",'(unknown)')
//   ORDER BY "Orders" DESC
//   LIMIT :max_items;
CannedTranslation _topCompaniesOrders({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression: 'coalesce(t."buyer_company_name", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Orders',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Orders', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'Orders',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos uses `max_items` (default 10) to control the top-N '
        'cut. The translator wires this to SQL LIMIT so the wizard can adjust '
        'it via the standard limit control.',
  );
}

// ─── Slice #4: top_companies_revenue ─────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date`, `buyer_company_name`, `buyer_po_price`
//   • sums buyer_po_price per buyer_company_name (null → "(unknown)")
//   • sorts DESC by sum, slices top `max_items` (default 10)
//   • rescales to $M / $K for display (peak-of-set based) — display-only
//   • emits `_labels`, `_data`, `_unit`, `_yLabel="Revenue"`,
//     `_col1="Company"`, `_col2="Revenue ($)"`.
//
// query_v2 equivalent (Path A — current window only, raw dollars):
//
//   SELECT coalesce(t."buyer_company_name",'(unknown)') AS "Company",
//          SUM(t."buyer_po_price")                       AS "Revenue"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//   GROUP BY coalesce(t."buyer_company_name",'(unknown)')
//   ORDER BY "Revenue" DESC
//   LIMIT :max_items;
CannedTranslation _topCompaniesRevenue({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression: 'coalesce(t."buyer_company_name", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        fn: 'sum',
        alias: 'Revenue',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Revenue', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'Revenue',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally rescales the top-N revenues to \$M/\$K '
        'for display (based on peak of set). Display-only; the v2 render path '
        'shows raw dollar values.',
  );
}

// ─── Slice #5: count_orders (KPI) ────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date` from user_purchase_order
//   • counts rows in current vs. prior window; emits _data=[prior,current]
//
// query_v2 equivalent (Path A — total count, no comparison window):
//
//   SELECT count(*) AS "Orders"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id;
CannedTranslation _countOrders() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Orders',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Orders'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally emits a prior-period delta in _meta '
        '(current vs. prior window). Display-only and not reproduced by the '
        'v2 render path in this slice.',
  );
}

// ─── Slice #6: sum_po_price (KPI) ────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date`, `buyer_po_price`
//   • sums buyer_po_price for current vs. prior window
//   • rescales to $M/$K/$ for display (display-only)
//
// query_v2 equivalent (Path A — raw dollars, no comparison window):
//
//   SELECT sum(t."buyer_po_price") AS "Revenue"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id;
CannedTranslation _sumPoPrice() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        fn: 'sum',
        alias: 'Revenue',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Revenue'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally rescales the total to \$M/\$K for '
        'display and emits a prior-period delta in _meta. Both are display-'
        'only; the v2 render path shows raw dollar values.',
  );
}

// ─── Slice #7: count_users (KPI) ─────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `is_active`, `created_date` from user
//   • counts active users in current vs. prior window
//
// query_v2 equivalent (Path A — active-user total, no comparison window):
//
//   SELECT count(*) AS "Users"
//   FROM rds_user t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//     AND t."is_active" = 1;
CannedTranslation _countUsers() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user',
    filters: [
      FilterSpec(
        table: 'rds_user',
        column: 'is_active',
        op: '=',
        value: 1,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user',
        column: '',
        fn: 'count',
        alias: 'Users',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Users'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally emits a prior-period delta and '
        'all-time total in _meta. Display-only and not reproduced by the '
        'v2 render path in this slice.',
  );
}

// ─── Slice #8: count_companies (KPI) ─────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches `is_active`, `created_date` from user_main_company
//   • counts active companies in current vs. prior window
//
// query_v2 equivalent (Path A — active-company total, no comparison window):
//
//   SELECT count(*) AS "Companies"
//   FROM rds_user_main_company t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//     AND t."is_active" = 1;
CannedTranslation _countCompanies() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_main_company',
    filters: [
      FilterSpec(
        table: 'rds_user_main_company',
        column: 'is_active',
        op: '=',
        value: 1,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_main_company',
        column: '',
        fn: 'count',
        alias: 'Companies',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Companies'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally emits a prior-period delta and '
        'all-time total in _meta. Display-only and not reproduced by the '
        'v2 render path in this slice.',
  );
}

// ─── Slice #9: credit_enabled_companies_kpi (KPI) ────────────────────────
//
// widget-data-bryzos:
//   • fetches `is_active`, `bnpl_status` from user_main_company (no window)
//   • counts active companies whose bnpl_status = "ENABLED" (case-insensitive)
//   • emits `_meta.{total, totalActive, pct}`
//
// query_v2 equivalent (Path A — BNPL-enabled count, no comparison window):
//
//   SELECT count(*) AS "Companies"
//   FROM rds_user_main_company t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//     AND t."is_active" = 1
//     AND t."bnpl_status" ILIKE 'ENABLED';
CannedTranslation _creditEnabledCompaniesKpi() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_main_company',
    filters: [
      FilterSpec(
        table: 'rds_user_main_company',
        column: 'is_active',
        op: '=',
        value: 1,
      ),
      FilterSpec(
        table: 'rds_user_main_company',
        column: 'bnpl_status',
        op: 'ILIKE',
        value: 'ENABLED',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_main_company',
        column: '',
        fn: 'count',
        alias: 'Companies',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Companies'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally emits the pct-of-active in _meta '
        '(BNPL enabled / total active). The v2 KPI render shows the count '
        'only; percentage is not reproduced in this slice.',
  );
}

// ─── Slice #10: cancelled_orders_by_company ──────────────────────────────
//
// widget-data-bryzos:
//   • fetches `created_date`, `buyer_company_name`, `in_dispute`
//   • counts rows where in_dispute is truthy, per buyer_company_name
//     (null → "(unknown)")
//   • sorts DESC by count, slices top `max_items` (default 10)
//   • emits `_labels`, `_data`, `_yLabel="Disputed Orders"`,
//     `_col1="Company"`, `_col2="Disputed"`.
//
// query_v2 equivalent (Path A — current window only):
//
//   SELECT coalesce(t."buyer_company_name",'(unknown)') AS "Company",
//          count(*)                                     AS "Disputed"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//     AND t."in_dispute" = 1
//   GROUP BY coalesce(t."buyer_company_name",'(unknown)')
//   ORDER BY "Disputed" DESC
//   LIMIT :max_items;
CannedTranslation _cancelledOrdersByCompany({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression: 'coalesce(t."buyer_company_name", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'in_dispute',
        op: '=',
        value: 1,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Disputed',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Disputed', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'Disputed',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos uses `in_dispute` as a proxy for cancelled/'
        'disputed orders. The translator preserves that semantic. `max_items` '
        '(default 10) is wired to SQL LIMIT so the wizard can adjust it via '
        'the standard limit control.',
  );
}

// ─── Slice #11: orders_by_status ─────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, in_dispute, is_closed from user_purchase_order
//   • buckets each row into Open / Closed / Disputed
//   • emits _labels, _data, _col1="Status", _col2="Orders"
//
// query_v2 equivalent:
//
//   SELECT case when t."in_dispute" = 1 then 'Disputed'
//               when t."is_closed"  = 1 then 'Closed'
//               else 'Open' end AS "Status",
//          count(*) AS "Orders"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//   GROUP BY 1
//   ORDER BY "Orders" DESC;
CannedTranslation _ordersByStatus() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression:
            'case when t."in_dispute" = 1 then \'Disputed\' '
            'when t."is_closed" = 1 then \'Closed\' '
            'else \'Open\' end',
        alias: 'Status',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Orders',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Status'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Orders', dir: 'DESC'),
    ],
    viz: VizSpec(
      chartType: 'bar',
      x: 'Status',
      y: 'Orders',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos uses `in_dispute` and `is_closed` as bigint '
        'proxies for the three status buckets (Disputed / Closed / Open). '
        'Priority: Disputed > Closed > Open. Translator preserves the same '
        'ordering via a case expression.',
  );
}

// ─── Slice #12: users_by_type ────────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, type from user
//   • buckets by upper(type) into Buyers / Sellers / Other
//   • omits "Other" bucket when its count is 0
//   • emits _labels, _data, _col1="Type", _col2="Users"
//
// query_v2 equivalent:
//
//   SELECT case when upper(t."type") = 'BUYER'  then 'Buyers'
//               when upper(t."type") = 'SELLER' then 'Sellers'
//               else 'Other' end AS "Type",
//          count(*) AS "Users"
//   FROM rds_user t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//   GROUP BY 1
//   ORDER BY "Users" DESC;
//
// Note: v2 render path always returns all three buckets. The widget-side
// suppression of empty "Other" is a display detail preserved in
// postFetchNote and not reproduced by the RPC.
CannedTranslation _usersByType() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user',
    computedColumns: [
      ComputedColumn(
        expression:
            'case when upper(t."type") = \'BUYER\' then \'Buyers\' '
            'when upper(t."type") = \'SELLER\' then \'Sellers\' '
            'else \'Other\' end',
        alias: 'Type',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user',
        column: '',
        fn: 'count',
        alias: 'Users',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Type'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Users', dir: 'DESC'),
    ],
    viz: VizSpec(
      chartType: 'bar',
      x: 'Type',
      y: 'Users',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos omits the "Other" bucket when its count is 0. '
        'The v2 render path always emits all three rows; a zero-count '
        '"Other" row will appear unless suppressed at the widget layer.',
  );
}

// ─── Slice #13: bpns_by_company ──────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches rows from user_product_tag_mapping (created_date, is_active,
//     company_id) and user_main_company (id, company_name)
//   • filters tags to is_active = 1
//   • joins mapping.company_id → company.id, coalesces missing names to
//     "(unknown)"
//   • counts BPNs per company, sorts DESC by count, slices top `max_items`
//   • emits `_labels`, `_data`, `_col1="Company"`, `_col2="BPNs"`,
//     `_yLabel="BPNs"`.
//
// query_v2 equivalent (Path A — current window only, LEFT JOIN):
//
//   SELECT coalesce(j1."company_name",'(unknown)') AS "Company",
//          count(*)                                AS "BPNs"
//   FROM rds_user_product_tag_mapping t
//   LEFT JOIN public.rds_user_main_company j1
//     ON t."company_id"::text = j1."id"::text
//    AND j1."tenant_id" = :tenant_id
//    AND j1."data_source_id" = :data_source_id
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//     AND t."is_active" = 1
//   GROUP BY coalesce(j1."company_name",'(unknown)')
//   ORDER BY "BPNs" DESC
//   LIMIT :max_items;
CannedTranslation _bpnsByCompany({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_product_tag_mapping',
    joins: [
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_product_tag_mapping',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(
        expression: 'coalesce(j1."company_name", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_product_tag_mapping',
        column: '',
        fn: 'count',
        alias: 'BPNs',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_product_tag_mapping',
        column: 'is_active',
        op: '=',
        value: 1,
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'BPNs', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'BPNs',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos loads all matching rows in memory and applies '
        'the is_active filter + coalesce there. The v2 path pushes both to '
        'the RPC via a filter and a computed_column expression, which '
        'produces the same top-N ordering.',
  );
}

// ─── Slice #14: quotes_by_company ────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches save_order_draft (created_date, buyer_id, buyer_po_price),
//     user (id, company_id, client_company), user_main_company
//     (id, company_name)
//   • resolves each draft's company as
//       coalesce(company.company_name via user.company_id,
//                user.client_company,
//                '(unknown)')
//   • counts drafts per resolved company, sorts DESC, slices top max_items
//   • emits `_labels` (company), `_data` (counts), `_col1="Company"`,
//     `_col2="Quotes"`, `_yLabel="Quotes"`.
//
// query_v2 equivalent (Path A — current window only, LEFT JOIN chain):
//
//   SELECT coalesce(j2."company_name", j1."client_company",'(unknown)')
//            AS "Company",
//          count(*) AS "Quotes"
//   FROM rds_save_order_draft t
//   LEFT JOIN public.rds_user j1
//     ON t."buyer_id"::text = j1."id"::text
//    AND j1."tenant_id" = :tenant_id
//    AND j1."data_source_id" = :data_source_id
//   LEFT JOIN public.rds_user_main_company j2
//     ON j1."company_id"::text = j2."id"::text
//    AND j2."tenant_id" = :tenant_id
//    AND j2."data_source_id" = :data_source_id
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//   GROUP BY coalesce(j2."company_name", j1."client_company",'(unknown)')
//   ORDER BY "Quotes" DESC
//   LIMIT :max_items;
CannedTranslation _quotesByCompany({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_save_order_draft',
    joins: [
      JoinSpec(
        table: 'rds_user',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_save_order_draft',
            fromColumn: 'buyer_id',
            toTable: 'rds_user',
            toColumn: 'id',
          ),
        ],
      ),
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(
        expression:
            'coalesce(j2."company_name", j1."client_company", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_save_order_draft',
        column: '',
        fn: 'count',
        alias: 'Quotes',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Quotes', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'Quotes',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos resolves the company label in-memory by joining '
        'draft.buyer_id -> user.id, then user.company_id -> main_company.id, '
        'falling back to user.client_company then "(unknown)". The v2 path '
        'produces the same label via a computed_column coalesce over both '
        'joined tables (j1=user, j2=main_company).',
  );
}

// ─── Slice #15: searches_by_company ──────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches user_search_analytics (created_date, user_id),
//     user (id, company_id, client_company), user_main_company
//     (id, company_name)
//   • resolves each search's company via user_id -> user.id,
//     then user.company_id -> main_company.id, falling back to
//     user.client_company then '(unknown)'
//   • counts searches per resolved company, sorts DESC, slices top max_items
//   • emits `_labels` (company), `_data` (counts), `_col1="Company"`,
//     `_col2="Searches"`, `_yLabel="Searches"`.
//
// query_v2 equivalent (Path A — current window only, LEFT JOIN chain):
//
//   SELECT coalesce(j2."company_name", j1."client_company",'(unknown)')
//            AS "Company",
//          count(*) AS "Searches"
//   FROM rds_user_search_analytics t
//   LEFT JOIN public.rds_user j1
//     ON t."user_id"::text = j1."id"::text
//    AND j1."tenant_id" = :tenant_id
//    AND j1."data_source_id" = :data_source_id
//   LEFT JOIN public.rds_user_main_company j2
//     ON j1."company_id"::text = j2."id"::text
//    AND j2."tenant_id" = :tenant_id
//    AND j2."data_source_id" = :data_source_id
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//   GROUP BY coalesce(j2."company_name", j1."client_company",'(unknown)')
//   ORDER BY "Searches" DESC
//   LIMIT :max_items;
CannedTranslation _searchesByCompany({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_search_analytics',
    joins: [
      JoinSpec(
        table: 'rds_user',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_search_analytics',
            fromColumn: 'user_id',
            toTable: 'rds_user',
            toColumn: 'id',
          ),
        ],
      ),
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(
        expression:
            'coalesce(j2."company_name", j1."client_company", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_search_analytics',
        column: '',
        fn: 'count',
        alias: 'Searches',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Searches', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'Searches',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos resolves the company label in-memory by joining '
        'search.user_id -> user.id, then user.company_id -> main_company.id, '
        'falling back to user.client_company then "(unknown)". The v2 path '
        'produces the same label via a computed_column coalesce over both '
        'joined tables (j1=user, j2=main_company).',
  );
}

// ─── Slice #16: bpns_by_user ─────────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches user_product_tag_mapping (created_date, is_active, user_id),
//     user (id, email_id, first_name, last_name, company_id, client_company),
//     user_main_company (id, company_name)
//   • filters tags to is_active = 1
//   • builds a per-user label via buildUserLabels(users, companies, "id"):
//       "<name-or-email>  (<company>)"  when a company is available,
//       otherwise "<name-or-email>"     — and "(unknown)" when no user match.
//   • counts BPNs per user label, sorts DESC, slices top max_items
//   • emits `_labels`, `_data`, `_col1="User"`, `_col2="BPNs"`,
//     `_yLabel="BPNs"`.
//
// query_v2 equivalent (Path A — current window only, LEFT JOIN chain):
//
//   SELECT
//     case
//       when j1."id" is null then '(unknown)'
//       when coalesce(nullif(btrim(j2."company_name"),''), j1."client_company",'') <> ''
//         then coalesce(nullif(btrim(concat_ws(' ',j1."first_name",j1."last_name")),''),
//                       j1."email_id", j1."id"::text)
//              || '  (' || coalesce(nullif(btrim(j2."company_name"),''), j1."client_company") || ')'
//       else coalesce(nullif(btrim(concat_ws(' ',j1."first_name",j1."last_name")),''),
//                     j1."email_id", j1."id"::text, '(unknown)')
//     end                                     AS "User",
//     count(*)                                AS "BPNs"
//   FROM rds_user_product_tag_mapping t
//   LEFT JOIN public.rds_user j1
//     ON t."user_id"::text = j1."id"::text
//    AND j1."tenant_id" = :tenant_id
//    AND j1."data_source_id" = :data_source_id
//   LEFT JOIN public.rds_user_main_company j2
//     ON j1."company_id"::text = j2."id"::text
//    AND j2."tenant_id" = :tenant_id
//    AND j2."data_source_id" = :data_source_id
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//     AND t."is_active" = 1
//   GROUP BY "User"
//   ORDER BY "BPNs" DESC
//   LIMIT :max_items;
CannedTranslation _bpnsByUser({required int maxItems}) {
  const userLabelExpr = 'case '
      'when j1."id" is null then \'(unknown)\' '
      'when coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company", \'\') <> \'\' '
      'then coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text) '
      '|| \'  (\' || coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company") || \')\' '
      'else coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text, \'(unknown)\') '
      'end';

  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_product_tag_mapping',
    joins: [
      JoinSpec(
        table: 'rds_user',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_product_tag_mapping',
            fromColumn: 'user_id',
            toTable: 'rds_user',
            toColumn: 'id',
          ),
        ],
      ),
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(
        expression: userLabelExpr,
        alias: 'User',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_product_tag_mapping',
        column: '',
        fn: 'count',
        alias: 'BPNs',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_product_tag_mapping',
        column: 'is_active',
        op: '=',
        value: 1,
      ),
    ],
    groupBy: [
      GroupBySpec.alias('User'),
    ],
    orderBy: [
      OrderBySpec(alias: 'BPNs', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'User',
      y: 'BPNs',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos composes the per-user label in memory via '
        'buildUserLabels(users, companies, "id"), producing '
        '"<name-or-email>  (<company>)" or "(unknown)" when no user match. '
        'The v2 path pushes the same label composition into a computed_column '
        'CASE expression over j1=user + j2=main_company, so top-N ordering '
        'matches the legacy widget.',
  );
}

// ─── Slice #17: cancelled_orders_by_user ─────────────────────────────────
CannedTranslation _cancelledOrdersByUser({required int maxItems}) {
  const userLabelExpr = 'case '
      'when j1."id" is null then coalesce(nullif(btrim(t."buyer_email"), \'\'), \'(unknown)\') '
      'when coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company", \'\') <> \'\' '
      'then coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text) '
      '|| \'  (\' || coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company") || \')\' '
      'else coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text, \'(unknown)\') '
      'end';

  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    joins: [
      JoinSpec(
        table: 'rds_user',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_purchase_order',
            fromColumn: 'buyer_email',
            toTable: 'rds_user',
            toColumn: 'email_id',
          ),
        ],
      ),
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(expression: userLabelExpr, alias: 'User'),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Disputed',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'in_dispute',
        op: '=',
        value: 1,
      ),
    ],
    groupBy: [GroupBySpec.alias('User')],
    orderBy: [OrderBySpec(alias: 'Disputed', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'User', y: 'Disputed'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos joins user via buyer_email->email_id (not user_id). '
        'Falls back to the raw buyer_email when no user row matches, then to '
        '"(unknown)". The v2 CASE expression mirrors that fallback chain.',
  );
}

// ─── Slice #18: quotes_by_user ───────────────────────────────────────────
CannedTranslation _quotesByUser({required int maxItems}) {
  const userLabelExpr = 'case '
      'when j1."id" is null then \'(unknown)\' '
      'when coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company", \'\') <> \'\' '
      'then coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text) '
      '|| \'  (\' || coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company") || \')\' '
      'else coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text, \'(unknown)\') '
      'end';

  final q = CustomReportQueryV2(
    primaryTable: 'rds_save_order_draft',
    joins: [
      JoinSpec(
        table: 'rds_user',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_save_order_draft',
            fromColumn: 'buyer_id',
            toTable: 'rds_user',
            toColumn: 'id',
          ),
        ],
      ),
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(expression: userLabelExpr, alias: 'User'),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_save_order_draft',
        column: '',
        fn: 'count',
        alias: 'Quotes',
      ),
    ],
    groupBy: [GroupBySpec.alias('User')],
    orderBy: [OrderBySpec(alias: 'Quotes', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'User', y: 'Quotes'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos joins user on save_order_draft.buyer_id->user.id, '
        'then user_main_company on user.company_id->id, and composes '
        '"<name-or-email>  (<company>)" in memory. The v2 CASE mirrors that.',
  );
}

// ─── Slice #19: searches_by_user ─────────────────────────────────────────
CannedTranslation _searchesByUser({required int maxItems}) {
  const userLabelExpr = 'case '
      'when j1."id" is null then \'(unknown)\' '
      'when coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company", \'\') <> \'\' '
      'then coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text) '
      '|| \'  (\' || coalesce(nullif(btrim(j2."company_name"), \'\'), j1."client_company") || \')\' '
      'else coalesce(nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", j1."id"::text, \'(unknown)\') '
      'end';

  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_search_analytics',
    joins: [
      JoinSpec(
        table: 'rds_user',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_search_analytics',
            fromColumn: 'user_id',
            toTable: 'rds_user',
            toColumn: 'id',
          ),
        ],
      ),
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(expression: userLabelExpr, alias: 'User'),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_search_analytics',
        column: '',
        fn: 'count',
        alias: 'Searches',
      ),
    ],
    groupBy: [GroupBySpec.alias('User')],
    orderBy: [OrderBySpec(alias: 'Searches', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'User', y: 'Searches'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos joins user via user_id and composes '
        '"<name-or-email>  (<company>)". The v2 CASE mirrors that.',
  );
}

// ─── Slice #20: cancelled_orders_list ────────────────────────────────────
CannedTranslation _cancelledOrdersList({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    columns: [
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_number',
        alias: 'PO #',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_company_name',
        alias: 'Company',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_email',
        alias: 'User',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        alias: 'Price',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'created_date',
        alias: 'Created',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'in_dispute',
        op: '=',
        value: 1,
      ),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'Pure detail listing - no aggregation. widget-data-bryzos surfaces '
        'buyer_po_number/company_name/email/price/created_date; the v2 path '
        'selects the same columns via ColumnRef and orders by Created DESC.',
  );
}

// ─── Slice #21: orders_recent_list ───────────────────────────────────────
CannedTranslation _ordersRecentList({required int maxItems}) {
  const statusExpr = 'case '
      'when t."is_closed" = 1 then \'Closed\' '
      'when t."in_dispute" = 1 then \'Disputed\' '
      'else \'Open\' end';

  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    columns: [
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_number',
        alias: 'PO #',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_company_name',
        alias: 'Company',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        alias: 'Price',
      ),
      ColumnRef(
        table: 'rds_user_purchase_order',
        column: 'created_date',
        alias: 'Created',
      ),
    ],
    computedColumns: [
      ComputedColumn(expression: statusExpr, alias: 'Status'),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos derives status in TypeScript from is_closed / '
        'in_dispute. The v2 path pushes that same case-cascade into a '
        'computed_column so the RPC returns a Status column directly.',
  );
}

// ─── Slice #22: users_recent_list ────────────────────────────────────────
CannedTranslation _usersRecentList({required int maxItems}) {
  const nameExpr = 'coalesce('
      'nullif(btrim(concat_ws(\' \', t."first_name", t."last_name")), \'\'), '
      't."email_id", '
      '\'(unknown)\')';
  const companyExpr = 'coalesce('
      'nullif(btrim(j1."company_name"), \'\'), '
      'nullif(btrim(t."client_company"), \'\'), '
      'null)';

  final q = CustomReportQueryV2(
    primaryTable: 'rds_user',
    joins: [
      JoinSpec(
        table: 'rds_user_main_company',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    columns: [
      ColumnRef(table: 'rds_user', column: 'email_id', alias: 'Email'),
      ColumnRef(table: 'rds_user', column: 'type', alias: 'Type'),
      ColumnRef(table: 'rds_user', column: 'created_date', alias: 'Created'),
    ],
    computedColumns: [
      ComputedColumn(expression: nameExpr, alias: 'User'),
      ComputedColumn(expression: companyExpr, alias: 'Company'),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos composes the user display name from '
        'first_name/last_name/email in TS, and picks company_name from '
        'user_main_company with a fall-back to client_company. The v2 path '
        'mirrors both fall-back chains via computed_columns.',
  );
}
