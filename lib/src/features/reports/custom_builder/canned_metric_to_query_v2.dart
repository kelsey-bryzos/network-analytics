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
  'accepted_orders_by_company',
  'accepted_orders_by_user',
  'accepted_orders_table',
  'cancelled_lines_by_company',
  'cancelled_lines_by_user',
  'monthly_activity_summary',
  'all_buyers_table',
  'all_sellers_table',
  'avg_order_price_trend',
  'avg_price_per_lb_by_metal_trend',
  'bpns_by_company',
  'bpns_by_user',
  'bpns_full_list',
  'cancelled_orders_by_company',
  'cancelled_orders_by_user',
  'cancelled_orders_list',
  'chat_volume_by_month',
  'count_companies',
  'count_orders',
  'count_users',
  'credit_enabled_companies_kpi',
  'least_searched_products',
  'margin_by_metal_type',
  'margin_by_shape_grade',
  'most_searched_products',
  'order_lines_table',
  'orders_by_month',
  'orders_by_status',
  'orders_in_dispute_table',
  'orders_previewed_by_sellers_table',
  'orders_recent_list',
  'orders_with_chat',
  'price_search_feed_price_search_kpi',
  'price_search_feed_purchasing_kpi',
  'price_search_feed_quoting_kpi',
  'price_search_feed_table',
  'quotes_by_company',
  'quotes_by_user',
  'revenue_by_month',
  'sales_by_grade',
  'searches_by_company',
  'searches_by_user',
  'sum_po_price',
  'top_companies_orders',
  'top_companies_revenue',
  'unclaimed_orders_table',
  'users_by_type',
  'users_recent_list',
  'yoy_revenue',
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
    case 'accepted_orders_by_company':
      return _acceptedOrdersByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'accepted_orders_by_user':
      return _acceptedOrdersByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'accepted_orders_table':
      return _acceptedOrdersTable(maxItems: maxItems ?? kDefaultTopN);
    case 'cancelled_lines_by_company':
      return _cancelledLinesByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'cancelled_lines_by_user':
      return _cancelledLinesByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'monthly_activity_summary':
      return _monthlyActivitySummary();
    case 'all_buyers_table':
      return _allBuyersTable(maxItems: maxItems ?? kDefaultTopN);
    case 'avg_order_price_trend':
      return _avgOrderPriceTrend();
    case 'avg_price_per_lb_by_metal_trend':
      return _avgPricePerLbByMetalTrend();
    case 'all_sellers_table':
      return _allSellersTable(maxItems: maxItems ?? kDefaultTopN);
    case 'bpns_by_company':
      return _bpnsByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'chat_volume_by_month':
      return _chatVolumeByMonth();
    case 'bpns_by_user':
      return _bpnsByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'bpns_full_list':
      return _bpnsFullList(maxItems: maxItems ?? kDefaultTopN);
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
    case 'least_searched_products':
      return _leastSearchedProducts(maxItems: maxItems ?? kDefaultTopN);
    case 'margin_by_metal_type':
      return _marginByMetalType(maxItems: maxItems ?? kDefaultTopN);
    case 'margin_by_shape_grade':
      return _marginByShapeGrade(maxItems: maxItems ?? kDefaultTopN);
    case 'most_searched_products':
      return _mostSearchedProducts(maxItems: maxItems ?? kDefaultTopN);
    case 'order_lines_table':
      return _orderLinesTable(maxItems: maxItems ?? kDefaultTopN);
    case 'orders_by_month':
      return _ordersByMonth();
    case 'orders_by_status':
      return _ordersByStatus();
    case 'orders_in_dispute_table':
      return _ordersInDisputeTable(maxItems: maxItems ?? kDefaultTopN);
    case 'orders_previewed_by_sellers_table':
      return _ordersPreviewedBySellersTable(
          maxItems: maxItems ?? kDefaultTopN);
    case 'orders_recent_list':
      return _ordersRecentList(maxItems: maxItems ?? kDefaultTopN);
    case 'orders_with_chat':
      return _ordersWithChat();
    case 'price_search_feed_price_search_kpi':
      return _priceSearchFeedKpi('Price Search');
    case 'price_search_feed_purchasing_kpi':
      return _priceSearchFeedKpi('Purchasing');
    case 'price_search_feed_quoting_kpi':
      return _priceSearchFeedKpi('Quoting');
    case 'price_search_feed_table':
      return _priceSearchFeedTable(maxItems: maxItems ?? kDefaultTopN);
    case 'quotes_by_company':
      return _quotesByCompany(maxItems: maxItems ?? kDefaultTopN);
    case 'quotes_by_user':
      return _quotesByUser(maxItems: maxItems ?? kDefaultTopN);
    case 'revenue_by_month':
      return _revenueByMonth();
    case 'sales_by_grade':
      return _salesByGrade(maxItems: maxItems ?? kDefaultTopN);
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
    case 'unclaimed_orders_table':
      return _unclaimedOrdersTable(maxItems: maxItems ?? kDefaultTopN);
    case 'users_by_type':
      return _usersByType();
    case 'users_recent_list':
      return _usersRecentList(maxItems: maxItems ?? kDefaultTopN);
    case 'yoy_revenue':
      return _yoyRevenue();
    default:
      return null;
  }
}

// ─── Accepted Orders: accepted_orders_by_company ─────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, buyer_company_name, seller_id
//   • counts rows where seller_id IS NOT NULL/non-empty, per buyer_company_name
//   • sorts DESC by count, slices top max_items
//
// query_v2 equivalent:
//
//   SELECT coalesce(t."buyer_company_name",'(unknown)') AS "Company",
//          count(*)                                     AS "Accepted"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//     AND t."seller_id" IS NOT NULL
//     AND t."seller_id" != ''
//   GROUP BY coalesce(t."buyer_company_name",'(unknown)')
//   ORDER BY "Accepted" DESC
//   LIMIT :max_items;
CannedTranslation _acceptedOrdersByCompany({required int maxItems}) {
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
        column: 'seller_id',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'seller_id',
        op: '!=',
        value: '',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Accepted',
      ),
    ],
    groupBy: [GroupBySpec.alias('Company')],
    orderBy: [OrderBySpec(alias: 'Accepted', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'Company', y: 'Accepted'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'Accepted = order has a seller_id (non-null, non-empty). '
        'Groups by buyer company; counts orders claimed by any seller.',
  );
}

// ─── Accepted Orders: accepted_orders_by_user ────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, buyer_email, seller_id
//   • counts rows where seller_id IS NOT NULL/non-empty, per buyer (user label)
//   • sorts DESC by count, slices top max_items
CannedTranslation _acceptedOrdersByUser({required int maxItems}) {
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
        alias: 'Accepted',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'seller_id',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'seller_id',
        op: '!=',
        value: '',
      ),
    ],
    groupBy: [GroupBySpec.alias('User')],
    orderBy: [OrderBySpec(alias: 'Accepted', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'User', y: 'Accepted'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'Accepted = order has a seller_id (non-null, non-empty). '
        'Groups by buyer user. Joins via buyer_email->email_id.',
  );
}

// ─── Phase 2: accepted_orders_table ──────────────────────────────────────
CannedTranslation _acceptedOrdersTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    columns: [
      ColumnRef(table: 'rds_user_purchase_order', column: 'buyer_po_number', alias: 'PO #'),
      ColumnRef(table: 'rds_user_purchase_order', column: 'buyer_company_name', alias: 'Company'),
      ColumnRef(table: 'rds_user_purchase_order', column: 'buyer_email', alias: 'Buyer'),
      ColumnRef(table: 'rds_user_purchase_order', column: 'buyer_po_price', alias: 'Price'),
      ColumnRef(table: 'rds_user_purchase_order', column: 'seller_company_name', alias: 'Seller'),
      ColumnRef(table: 'rds_user_purchase_order', column: 'seller_claim_date', alias: 'Claimed'),
      ColumnRef(table: 'rds_user_purchase_order', column: 'created_date', alias: 'Created'),
    ],
    filters: [
      FilterSpec(table: 'rds_user_purchase_order', column: 'seller_id', op: 'IS NOT NULL'),
      FilterSpec(table: 'rds_user_purchase_order', column: 'seller_id', op: '!=', value: ''),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(query: q);
}

// ─── Phase 2: cancelled_lines_by_company ─────────────────────────────────
CannedTranslation _cancelledLinesByCompany({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order_line',
    joins: [
      JoinSpec(
        table: 'rds_user_purchase_order',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_purchase_order_line',
            fromColumn: 'purchase_order_id',
            toTable: 'rds_user_purchase_order',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(
        expression: 'coalesce(j1."buyer_company_name", \'(unknown)\')',
        alias: 'Company',
      ),
    ],
    filters: [
      FilterSpec(table: 'rds_user_purchase_order_line', column: 'is_active', op: '=', value: 0),
      FilterSpec(table: 'rds_user_purchase_order_line', column: 'line_cancel_date', op: 'IS NOT NULL'),
    ],
    aggregates: [
      AggregateSpec(table: 'rds_user_purchase_order_line', column: '', fn: 'count', alias: 'Cancelled_Lines'),
    ],
    groupBy: [GroupBySpec.alias('Company')],
    orderBy: [OrderBySpec(alias: 'Cancelled_Lines', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'Company', y: 'Cancelled_Lines'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote: 'Cancelled lines = is_active=0 AND line_cancel_date IS NOT NULL. Joins to purchase_order for company name.',
  );
}

// ─── Phase 2: cancelled_lines_by_user ────────────────────────────────────
CannedTranslation _cancelledLinesByUser({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order_line',
    joins: [
      JoinSpec(
        table: 'rds_user_purchase_order',
        type: JoinType.left,
        on: [
          JoinOnPair(
            fromTable: 'rds_user_purchase_order_line',
            fromColumn: 'purchase_order_id',
            toTable: 'rds_user_purchase_order',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    computedColumns: [
      ComputedColumn(
        expression: 'coalesce(j1."buyer_email", \'(unknown)\')',
        alias: 'User',
      ),
    ],
    filters: [
      FilterSpec(table: 'rds_user_purchase_order_line', column: 'is_active', op: '=', value: 0),
      FilterSpec(table: 'rds_user_purchase_order_line', column: 'line_cancel_date', op: 'IS NOT NULL'),
    ],
    aggregates: [
      AggregateSpec(table: 'rds_user_purchase_order_line', column: '', fn: 'count', alias: 'Cancelled_Lines'),
    ],
    groupBy: [GroupBySpec.alias('User')],
    orderBy: [OrderBySpec(alias: 'Cancelled_Lines', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'User', y: 'Cancelled_Lines'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote: 'Cancelled lines = is_active=0 AND line_cancel_date IS NOT NULL. Groups by buyer email from the parent order.',
  );
}

// ─── Phase 2: monthly_activity_summary ───────────────────────────────────
CannedTranslation _monthlyActivitySummary() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order',
    computedColumns: [
      ComputedColumn(
        expression: 'date_trunc(\'month\', t."created_date")',
        alias: 'bucket_start',
      ),
      ComputedColumn(
        expression: 'to_char(date_trunc(\'month\', t."created_date"), \'Mon YYYY\')',
        alias: 'Month',
      ),
    ],
    aggregates: [
      AggregateSpec(table: 'rds_user_purchase_order', column: '', fn: 'count', alias: 'Orders'),
      AggregateSpec(table: 'rds_user_purchase_order', column: 'buyer_po_price', fn: 'sum', alias: 'Revenue'),
    ],
    groupBy: [GroupBySpec.alias('bucket_start'), GroupBySpec.alias('Month')],
    orderBy: [OrderBySpec(alias: 'bucket_start', dir: 'ASC')],
    viz: VizSpec(chartType: 'table', x: 'Month', y: 'Orders'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos monthly_activity_summary computes Quotes, Orders, Cancelled, and Accepted '
        'columns per month from multiple tables in a single pass. The v2 path produces only Orders '
        'and Revenue per month from user_purchase_order. For the full multi-column summary, use '
        'the canned widget directly.',
  );
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
//   • fetches `created_date`, `buyer_company_name`, `is_active`, `cancel_date`
//   • counts rows where is_active=0 AND cancel_date IS NOT NULL/non-empty
//   • sorts DESC by count, slices top `max_items` (default 10)
//   • emits `_labels`, `_data`, `_yLabel="Cancelled Orders"`,
//     `_col1="Company"`, `_col2="Cancelled"`.
//
// query_v2 equivalent (Path A — current window only):
//
//   SELECT coalesce(t."buyer_company_name",'(unknown)') AS "Company",
//          count(*)                                     AS "Cancelled"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id
//     AND t."data_source_id" = :data_source_id
//     AND t."is_active" = 0
//     AND t."cancel_date" IS NOT NULL
//     AND t."cancel_date" != ''
//   GROUP BY coalesce(t."buyer_company_name",'(unknown)')
//   ORDER BY "Cancelled" DESC
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
        column: 'is_active',
        op: '=',
        value: 0,
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'cancel_date',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'cancel_date',
        op: '!=',
        value: '',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: '',
        fn: 'count',
        alias: 'Cancelled',
      ),
    ],
    groupBy: [
      GroupBySpec.alias('Company'),
    ],
    orderBy: [
      OrderBySpec(alias: 'Cancelled', dir: 'DESC'),
    ],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Company',
      y: 'Cancelled',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'Cancelled = is_active=0 AND cancel_date IS NOT NULL/non-empty. '
        'Previously used in_dispute as proxy — that was incorrect. '
        '`max_items` (default 10) is wired to SQL LIMIT.',
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
        alias: 'Cancelled',
      ),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'is_active',
        op: '=',
        value: 0,
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'cancel_date',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'cancel_date',
        op: '!=',
        value: '',
      ),
    ],
    groupBy: [GroupBySpec.alias('User')],
    orderBy: [OrderBySpec(alias: 'Cancelled', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'User', y: 'Cancelled'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'Cancelled = is_active=0 AND cancel_date IS NOT NULL/non-empty. '
        'Previously used in_dispute as proxy — that was incorrect. '
        'Joins user via buyer_email->email_id.',
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
        column: 'cancel_date',
        alias: 'Cancel Date',
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
        column: 'is_active',
        op: '=',
        value: 0,
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'cancel_date',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'cancel_date',
        op: '!=',
        value: '',
      ),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'Cancelled = is_active=0 AND cancel_date IS NOT NULL/non-empty. '
        'Previously used in_dispute as proxy — that was incorrect. '
        'cancel_date column added to output.',
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

// ─── Slice #23: all_buyers_table ─────────────────────────────────────────
//
// widget-data-bryzos:
//   • rdsSelect all_buyers_flat (buyer, email, buyer_company, purchases,
//     aov, total_purchases, date_joined) ORDER BY date_joined DESC LIMIT max
//
// query_v2: pure detail-list on rds_all_buyers_flat.
CannedTranslation _allBuyersTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_all_buyers_flat',
    columns: [
      ColumnRef(table: 'rds_all_buyers_flat', column: 'buyer', alias: 'Buyer'),
      ColumnRef(
          table: 'rds_all_buyers_flat', column: 'email', alias: 'Buyer Email'),
      ColumnRef(
          table: 'rds_all_buyers_flat',
          column: 'buyer_company',
          alias: 'Buyer Company'),
      ColumnRef(
          table: 'rds_all_buyers_flat',
          column: 'purchases',
          alias: 'Purchases'),
      ColumnRef(table: 'rds_all_buyers_flat', column: 'aov', alias: 'AOV'),
      ColumnRef(
          table: 'rds_all_buyers_flat',
          column: 'total_purchases',
          alias: 'Total Purchases'),
      ColumnRef(
          table: 'rds_all_buyers_flat',
          column: 'date_joined',
          alias: 'Date Joined'),
    ],
    orderBy: [OrderBySpec(alias: 'Date Joined', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos also emits prior/current buyer bucket counts in '
        '_data. This v2 slice returns only the row listing; the prior/current '
        'counts are not reproduced in edit-mode.',
  );
}

// ─── Slice #24: all_sellers_table ────────────────────────────────────────
CannedTranslation _allSellersTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_all_sellers_flat',
    columns: [
      ColumnRef(
          table: 'rds_all_sellers_flat', column: 'seller', alias: 'Seller'),
      ColumnRef(
          table: 'rds_all_sellers_flat',
          column: 'email',
          alias: 'Seller Email'),
      ColumnRef(
          table: 'rds_all_sellers_flat',
          column: 'seller_company',
          alias: 'Seller Company'),
      ColumnRef(table: 'rds_all_sellers_flat', column: 'sales', alias: 'Sales'),
      ColumnRef(table: 'rds_all_sellers_flat', column: 'aov', alias: 'AOV'),
      ColumnRef(
          table: 'rds_all_sellers_flat',
          column: 'total_sales',
          alias: 'Total Sales'),
      ColumnRef(
          table: 'rds_all_sellers_flat',
          column: 'date_joined',
          alias: 'Date Joined'),
    ],
    orderBy: [OrderBySpec(alias: 'Date Joined', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos also emits prior/current seller bucket counts in '
        '_data. This v2 slice returns only the row listing.',
  );
}

// ─── Slice #25: bpns_full_list ───────────────────────────────────────────
//
// widget-data-bryzos: full BPN listing (tag, description, user, company,
// created), filtered to is_active = 1, company resolved via
// tag.company_id -> main_company.id; falls back to user.company_id then
// user.client_company then "(unknown)".
CannedTranslation _bpnsFullList({required int maxItems}) {
  const userExpr = 'coalesce('
      'nullif(btrim(concat_ws(\' \', j1."first_name", j1."last_name")), \'\'), '
      'j1."email_id", '
      '\'(unknown)\')';
  const companyExpr = 'coalesce('
      'nullif(btrim(j2."company_name"), \'\'), '
      'nullif(btrim(j1."client_company"), \'\'), '
      '\'(unknown)\')';

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
            fromTable: 'rds_user_product_tag_mapping',
            fromColumn: 'company_id',
            toTable: 'rds_user_main_company',
            toColumn: 'id',
          ),
        ],
      ),
    ],
    columns: [
      ColumnRef(
          table: 'rds_user_product_tag_mapping',
          column: 'tag',
          alias: 'Tag'),
      ColumnRef(
          table: 'rds_user_product_tag_mapping',
          column: 'description',
          alias: 'Description'),
      ColumnRef(
          table: 'rds_user_product_tag_mapping',
          column: 'created_date',
          alias: 'Created'),
    ],
    computedColumns: [
      ComputedColumn(expression: userExpr, alias: 'User'),
      ComputedColumn(expression: companyExpr, alias: 'Company'),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_product_tag_mapping',
        column: 'is_active',
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
        'widget-data-bryzos preferred tag.company_id when present, falling '
        'back to user.company_id. The v2 join uses tag.company_id directly '
        '(the primary lookup path); if that is null the company name '
        'coalesces to user.client_company then "(unknown)".',
  );
}

// ─── Slice #26: order_lines_table ────────────────────────────────────────
CannedTranslation _orderLinesTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_order_lines_flat',
    columns: [
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'buyer_po_number',
          alias: 'Order#'),
      ColumnRef(
          table: 'rds_order_lines_flat', column: 'po_line', alias: 'Line'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'product',
          alias: 'Product'),
      ColumnRef(table: 'rds_order_lines_flat', column: 'qty', alias: 'Qty'),
      ColumnRef(
          table: 'rds_order_lines_flat', column: 'qty_unit', alias: 'Unit'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'buyer_price_per_unit',
          alias: 'Unit Price'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'buyer_line_total',
          alias: 'Line Total'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'buyer_company',
          alias: 'Buyer Co.'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'seller_company',
          alias: 'Seller Co.'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'line_status',
          alias: 'Status'),
      ColumnRef(
          table: 'rds_order_lines_flat',
          column: 'created_date',
          alias: 'Created'),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'Detail listing. widget-data-bryzos formats unit price / line total '
        'as en-US currency strings; the v2 path returns raw numeric columns '
        'and defers formatting to the render layer.',
  );
}

// ─── Slice #27: orders_in_dispute_table ──────────────────────────────────
//
// widget-data-bryzos: filters rds_dispute_counters_flat to active statuses
// (Pending / Countered — Awaiting Seller / Awaiting Buyer) via PostgREST
// `status=in.(…)`, orders by buyer_po_number DESC.
CannedTranslation _ordersInDisputeTable({required int maxItems}) {
  const activeStatuses = <String>[
    'Pending — Awaiting Seller',
    'Pending — Awaiting Buyer',
    'Countered — Awaiting Seller',
    'Countered — Awaiting Buyer',
  ];
  final q = CustomReportQueryV2(
    primaryTable: 'rds_dispute_counters_flat',
    columns: [
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'buyer_po_number',
          alias: 'Order#'),
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'event',
          alias: 'Dispute Type'),
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'buyer_company',
          alias: 'Buyer Company'),
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'buyer',
          alias: 'Buyer'),
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'seller_company',
          alias: 'Seller Company'),
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'seller',
          alias: 'Seller'),
      ColumnRef(
          table: 'rds_dispute_counters_flat',
          column: 'status',
          alias: 'Status'),
    ],
    filters: [
      FilterSpec(
        table: 'rds_dispute_counters_flat',
        column: 'status',
        op: 'IN',
        value: activeStatuses,
      ),
    ],
    orderBy: [OrderBySpec(alias: 'Order#', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'Active-dispute filter is expressed as an IN clause on the four '
        'awaiting-seller/buyer statuses — matches the widget exactly.',
  );
}

// ─── Slice #28: orders_previewed_by_sellers_table ────────────────────────
CannedTranslation _ordersPreviewedBySellersTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_orders_previewed_by_sellers_flat',
    columns: [
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'order_number',
          alias: 'Order#'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'purchase_date_fmt',
          alias: 'Purchase Date'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'buyer_company',
          alias: 'Buyer Company'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'buyer',
          alias: 'Buyer'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'seller_company',
          alias: 'Seller Company'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'seller',
          alias: 'Seller'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'preview_screen_fmt',
          alias: 'Preview Screen'),
      ColumnRef(
          table: 'rds_orders_previewed_by_sellers_flat',
          column: 'claim_screen_fmt',
          alias: 'Claim Screen'),
    ],
    orderBy: [OrderBySpec(alias: 'Purchase Date', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(query: q);
}

// ─── Slice #29: unclaimed_orders_table ───────────────────────────────────
CannedTranslation _unclaimedOrdersTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_unclaimed_orders_flat',
    columns: [
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'purchase_date_fmt',
          alias: 'Purchase Date'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'delivery_date_fmt',
          alias: 'Delivery Date'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'buyer_po_number',
          alias: 'Order#'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'company',
          alias: 'Company'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'buyer',
          alias: 'Buyer'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'deliver_to',
          alias: 'Deliver To'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'order_value_fmt',
          alias: 'Order Value'),
      ColumnRef(
          table: 'rds_unclaimed_orders_flat',
          column: 'created_date',
          alias: 'Created'),
    ],
    orderBy: [OrderBySpec(alias: 'Created', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(query: q);
}

// ─── Slice #30: price_search_feed_table ──────────────────────────────────
CannedTranslation _priceSearchFeedTable({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_price_search_feed_flat',
    columns: [
      ColumnRef(
          table: 'rds_price_search_feed_flat',
          column: 'source',
          alias: 'Source'),
      ColumnRef(
          table: 'rds_price_search_feed_flat',
          column: 'company',
          alias: 'Company'),
      ColumnRef(
          table: 'rds_price_search_feed_flat',
          column: 'buyer',
          alias: 'Buyer'),
      ColumnRef(
          table: 'rds_price_search_feed_flat',
          column: 'searched_product',
          alias: 'Searched Product'),
      ColumnRef(
          table: 'rds_price_search_feed_flat',
          column: 'price',
          alias: 'Price'),
      ColumnRef(
          table: 'rds_price_search_feed_flat',
          column: 'searched_at',
          alias: 'Date'),
    ],
    orderBy: [OrderBySpec(alias: 'Date', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'table'),
  );
  return CannedTranslation(query: q);
}

// ─── Slice #31: price_search_feed_price_search_kpi ───────────────────────
// ─── Slice #32: price_search_feed_purchasing_kpi ─────────────────────────
// ─── Slice #33: price_search_feed_quoting_kpi ────────────────────────────
//
// widget-data-bryzos returns an exact HEAD count filtered by source.
// v2 mirrors that as a count(*) on rds_price_search_feed_flat with a
// source = <label> filter. This does NOT reproduce prior/current sparkline
// buckets; those are display-only enhancements not needed for the count.
CannedTranslation _priceSearchFeedKpi(String sourceLabel) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_price_search_feed_flat',
    filters: [
      FilterSpec(
        table: 'rds_price_search_feed_flat',
        column: 'source',
        op: '=',
        value: sourceLabel,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_price_search_feed_flat',
        column: '',
        fn: 'count',
        alias: 'Searches',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Searches'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos also computes a prior-window count and a per-'
        'bucket sparkline; those are display-only, not represented in the '
        'v2 query.',
  );
}

// ─── Slice #34: most_searched_products ───────────────────────────────────
// ─── Slice #35: least_searched_products ──────────────────────────────────
//
// widget-data-bryzos groups rds_user_search_analytics.keyword (trimmed,
// non-empty), counts occurrences, then either desc-sort (most) or
// asc-sort (least). The empty-keyword skip becomes an IS NOT NULL guard
// combined with a keyword != '' filter.
CannedTranslation _mostSearchedProducts({required int maxItems}) =>
    _searchedProductsRanked(maxItems: maxItems, direction: 'DESC');

CannedTranslation _leastSearchedProducts({required int maxItems}) =>
    _searchedProductsRanked(maxItems: maxItems, direction: 'ASC');

CannedTranslation _searchedProductsRanked({
  required int maxItems,
  required String direction,
}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_search_analytics',
    columns: [
      ColumnRef(
          table: 'rds_user_search_analytics',
          column: 'keyword',
          alias: 'Product / Keyword'),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_search_analytics',
        column: 'keyword',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_user_search_analytics',
        column: 'keyword',
        op: '!=',
        value: '',
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
      GroupBySpec(
          table: 'rds_user_search_analytics', column: 'keyword'),
    ],
    orderBy: [OrderBySpec(alias: 'Searches', dir: direction)],
    limit: maxItems,
    viz: VizSpec(
      chartType: 'bar',
      x: 'Product / Keyword',
      y: 'Searches',
    ),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos trims each keyword client-side and skips empty '
        'strings. The v2 path filters keyword IS NOT NULL AND keyword != "" '
        'and groups by the raw column — leading/trailing whitespace variants '
        'may therefore appear as distinct rows in the RPC output.',
  );
}

// ─── Slice #37: margin_by_metal_type ─────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, metal_type, description, actual_buyer_line_total,
//     buyer_line_total from user_purchase_order_line
//   • normalises metal_type (CS→"Carbon Steel", SS→"Stainless Steel", etc.)
//     and falls back to description sniffing when metal_type is blank
//   • sums revenue (actual_buyer_line_total ?? buyer_line_total) per metal type
//   • sorts DESC by sum, slices top max_items
//   • emits _labels (metal), _data (revenue), _col1="Metal Type",
//     _col2="Revenue ($unit)", _unit, _yLabel="Revenue"
//
// IMPORTANT: despite the name "margin_by_metal_type", the widget actually
// computes *revenue* (buyer-side only) — there is no seller-side subtraction.
// The v2 path faithfully reproduces that behaviour.
//
// NOTE: the widget's multi-step normalization (normalize() → classifyFromDesc())
// cannot be replicated inside a single SQL expression without creating a DB
// function. The v2 path uses the raw metal_type column directly and groups on
// its value after a lightweight CASE-based normalization of the most common
// abbreviations. Rows with blank metal_type are bucketed as "(unspecified)"
// rather than being classified from the description field. This is an
// intentional simplification for the editable v2 path; the legacy widget-data-
// bryzos path continues to handle description-based fallback classification.
//
// query_v2 equivalent:
//
//   SELECT case
//            when metal_type is null or btrim(metal_type) = ''
//              then '(unspecified)'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) in ('CS')
//              or  upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'CARBON%'
//              then 'Carbon Steel'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) in ('SS')
//              or  upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'STAINLESS%'
//              then 'Stainless Steel'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) in ('AL')
//              or  upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'ALUM%'
//              then 'Aluminum'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'GALV%'
//              then 'Galvanized Carbon Steel'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'BRASS%'
//              then 'Brass'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'BRONZE%'
//              then 'Bronze'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'COPPER%'
//              then 'Copper'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'ALLOY%'
//              then 'Alloy'
//            when upper(btrim(regexp_replace(metal_type,'_x000d_','','gi'))) like 'TITAN%'
//              then 'Titanium'
//            else btrim(regexp_replace(metal_type,'_x000d_','','gi'))
//          end AS "Metal Type",
//          SUM(coalesce(t."actual_buyer_line_total", t."buyer_line_total")) AS "Revenue"
//   FROM rds_user_purchase_order_line t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//   GROUP BY 1
//   ORDER BY "Revenue" DESC
//   LIMIT :max_items;
CannedTranslation _marginByMetalType({required int maxItems}) {
  const metalNormExpr = 'case '
      'when t."metal_type" is null or btrim(t."metal_type") = \'\' '
      'then \'(unspecified)\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) in (\'CS\') '
      'or   upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'CARBON%\' '
      'then \'Carbon Steel\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) in (\'SS\') '
      'or   upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'STAINLESS%\' '
      'then \'Stainless Steel\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) in (\'AL\') '
      'or   upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'ALUM%\' '
      'then \'Aluminum\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'GALV%\' '
      'then \'Galvanized Carbon Steel\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'BRASS%\' '
      'then \'Brass\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'BRONZE%\' '
      'then \'Bronze\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'COPPER%\' '
      'then \'Copper\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'ALLOY%\' '
      'then \'Alloy\' '
      'when upper(btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\'))) like \'TITAN%\' '
      'then \'Titanium\' '
      'else btrim(regexp_replace(t."metal_type", \'_x000d_\', \'\', \'gi\')) '
      'end';

  // The RPC validates aggregate columns against information_schema, so we
  // cannot pass a coalesce() expression in the column field. We use
  // buyer_line_total as the aggregate column (the primary revenue field) and
  // note the simplification. actual_buyer_line_total is more accurate when
  // present, but buyer_line_total is what the RPC can validate and emit.
  // RPC alias validation: ^[A-Za-z_][A-Za-z0-9_]*$ — no spaces allowed.
  // Use metal_type as the computed_column alias (snake_case, valid identifier).
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order_line',
    computedColumns: [
      ComputedColumn(expression: metalNormExpr, alias: 'metal_type_norm'),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order_line',
        column: 'buyer_line_total',
        fn: 'sum',
        alias: 'Revenue',
      ),
    ],
    groupBy: [GroupBySpec.alias('metal_type_norm')],
    orderBy: [OrderBySpec(alias: 'Revenue', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'metal_type_norm', y: 'Revenue'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally falls back to description-based '
        'metal classification when metal_type is blank. The v2 path groups '
        'blank metal_type rows as "(unspecified)" and does not attempt the '
        'description sniffing — the legacy widget path continues to handle '
        'that fallback. Revenue is buyer_line_total (the RPC requires a '
        'real column name; actual_buyer_line_total coalescing is handled by '
        'the legacy path). No seller subtraction is performed despite the '
        'widget\'s name including "margin".',
  );
}

// ─── Slice #38: margin_by_shape_grade ────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, shape, grade, product,
//     actual_buyer_line_total, buyer_line_total,
//     actual_seller_line_total, seller_line_total
//   • computes margin = buyer - seller per line
//   • builds a composite key: "<shape> / <grade> (<metal>)"
//     where metal is classified from the product description
//     ("SS"→Stainless, "CS"→Carbon, "AL"→Aluminum, etc.)
//   • sums margin per key, sorts DESC, slices top max_items
//
// This is the ONLY Batch C metric that computes true margin (buyer - seller).
//
// query_v2 equivalent (composite key via computed_column):
//
//   SELECT
//     coalesce(nullif(btrim(t."shape"), ''), '?') || ' / ' ||
//     coalesce(nullif(btrim(t."grade"), ''), '?') AS "Shape / Grade",
//     SUM(coalesce(t."actual_buyer_line_total", t."buyer_line_total") -
//         coalesce(t."actual_seller_line_total", t."seller_line_total")) AS "Margin"
//   FROM rds_user_purchase_order_line t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//     AND coalesce(t."actual_buyer_line_total", t."buyer_line_total") > 0
//     AND coalesce(t."actual_seller_line_total", t."seller_line_total") > 0
//   GROUP BY 1
//   ORDER BY "Margin" DESC
//   LIMIT :max_items;
//
// NOTE: the widget's metal classification from product description is dropped
// in the v2 key — the key is "<shape> / <grade>" without the "(metal)" suffix.
// This is intentional: the metal classification requires description sniffing
// that cannot be replicated in portable SQL, and the shape+grade pair already
// uniquely identifies a product tier. Users can add a metal_type column via
// the wizard if needed.
CannedTranslation _marginByShapeGrade({required int maxItems}) {
  const keyExpr =
      'coalesce(nullif(btrim(t."shape"), \'\'), \'?\') || \' / \' || '
      'coalesce(nullif(btrim(t."grade"), \'\'), \'?\')';
  // True margin: emit (buyer - seller) as a computed_column so it can be
  // passed through the select list. We then aggregate that computed column.
  // The RPC validates aggregate column names against information_schema, so
  // for the aggregate we use buyer_line_total (validated column) and subtract
  // seller_line_total via a second AggregateSpec, relying on the wizard to
  // show both columns. An alternative is to emit the entire margin expression
  // as a computed_column and not use an aggregate at all — but that would
  // produce per-row values, not a sum. The cleanest v2-compatible approach:
  // use buyer_line_total and seller_line_total as separate validated columns,
  // and note that the wizard user can subtract them if needed.
  //
  // For the group-by path (which is what this metric needs), the most
  // correct approach within the RPC's constraints is:
  //   SELECT <key>, SUM(buyer_line_total) - SUM(seller_line_total) AS Margin
  // expressed as two aggregates and noting this as a postFetchNote simplification.
  //
  // Actually the cleanest solution: the margin_line computed_column plus
  // a SUM aggregate is not directly possible via the current AggregateSpec
  // model. We emit buyer and seller as separate aggregates (Revenue, COGS)
  // so the user can see both columns and the wizard renders them as a bar.
  // RPC alias regex ^[A-Za-z_][A-Za-z0-9_]*$ — spaces and slashes banned.
  // Use shape_grade as the computed_column alias.
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order_line',
    computedColumns: [
      ComputedColumn(expression: keyExpr, alias: 'shape_grade'),
    ],
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order_line',
        column: 'buyer_line_total',
        op: '>',
        value: 0,
      ),
      FilterSpec(
        table: 'rds_user_purchase_order_line',
        column: 'seller_line_total',
        op: '>',
        value: 0,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order_line',
        column: 'buyer_line_total',
        fn: 'sum',
        alias: 'Revenue',
      ),
      AggregateSpec(
        table: 'rds_user_purchase_order_line',
        column: 'seller_line_total',
        fn: 'sum',
        alias: 'COGS',
      ),
    ],
    groupBy: [GroupBySpec.alias('shape_grade')],
    orderBy: [OrderBySpec(alias: 'Revenue', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'shape_grade', y: 'Revenue'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos computes margin = (buyer - seller) per '
        '"shape / grade (metal)" key and sorts by margin DESC. The v2 path '
        'emits Revenue (buyer_line_total) and COGS (seller_line_total) as '
        'separate columns — the RPC model cannot express SUM(buyer)-SUM(seller) '
        'as a single aggregate. Sort is by Revenue DESC (approximates the '
        'widget\'s margin-DESC ordering for most distributions). Metal suffix '
        'is omitted from the key (description-sniffing cannot be done in SQL). '
        'Filter: both buyer and seller must be > 0.',
  );
}

// ─── Slice #39: sales_by_grade ────────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, grade, actual_buyer_line_total, buyer_line_total
//   • sums revenue per grade (null grade → "(unspecified)")
//   • sorts DESC, slices top max_items
//   • emits _labels, _data, _col1="Grade", _col2="Revenue ($unit)", _unit
//
// query_v2 equivalent:
//
//   SELECT coalesce(nullif(btrim(t."grade"), ''), '(unspecified)') AS "Grade",
//          SUM(coalesce(t."actual_buyer_line_total", t."buyer_line_total")) AS "Revenue"
//   FROM rds_user_purchase_order_line t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//   GROUP BY 1
//   ORDER BY "Revenue" DESC
//   LIMIT :max_items;
CannedTranslation _salesByGrade({required int maxItems}) {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order_line',
    computedColumns: [
      ComputedColumn(
        expression:
            'coalesce(nullif(btrim(t."grade"), \'\'), \'(unspecified)\')',
        alias: 'Grade',
      ),
    ],
    // The RPC validates aggregate column against information_schema — must use
    // a real column name. buyer_line_total is the primary revenue field.
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order_line',
        column: 'buyer_line_total',
        fn: 'sum',
        alias: 'Revenue',
      ),
    ],
    groupBy: [GroupBySpec.alias('Grade')],
    orderBy: [OrderBySpec(alias: 'Revenue', dir: 'DESC')],
    limit: maxItems,
    viz: VizSpec(chartType: 'bar', x: 'Grade', y: 'Revenue'),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos uses actual_buyer_line_total when present, '
        'falling back to buyer_line_total. The v2 path uses buyer_line_total '
        'directly (the RPC requires a real column name). Null/empty grade → '
        '"(unspecified)". Revenue is raw dollars; widget additionally rescales '
        'to \$M/\$K for display — not reproduced by the v2 render path.',
  );
}

// ─── Slice #40: avg_order_price_trend ────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, buyer_po_price from user_purchase_order
//   • buckets by month, computes AVG(buyer_po_price) per bucket
//   • emits _data (avg series), _labels (month labels), _unit, _yLabel=\"Avg Order $\"
//   • also emits overall weighted avg in _meta.total
//
// query_v2 equivalent:
//
//   SELECT date_trunc('month', t."created_date") AS "bucket_start",
//          to_char(date_trunc('month', t."created_date"), 'Mon YYYY')
//              AS "bucket_label",
//          AVG(t."buyer_po_price") AS "Avg Order Value"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//     AND t."buyer_po_price" > 0
//   GROUP BY date_trunc('month', t."created_date")
//   ORDER BY "bucket_start" ASC;
//
// Note: widget filters rows where buyer_po_price <= 0 before averaging.
// We express this as a filter so the RPC produces the same denominator.
CannedTranslation _avgOrderPriceTrend() {
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
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        op: '>',
        value: 0,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order',
        column: 'buyer_po_price',
        fn: 'avg',
        alias: 'Avg_Order_Value',
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
      y: 'Avg_Order_Value',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally rescales the avg to \$M/\$K for '
        'display and emits a weighted overall average in _meta.total. The v2 '
        'path returns raw dollar values. Widget filter: buyer_po_price > 0 '
        'is pushed to the RPC WHERE clause so per-bucket averages match.',
  );
}

// ─── Slice #41: avg_price_per_lb_by_metal_trend ──────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, metal_type, description, actual_buyer_line_total,
//     buyer_line_total, total_weight from user_purchase_order_line
//   • normalises metal_type (same as margin_by_metal_type)
//   • skips rows where revenue <= 0 or total_weight <= 0
//   • computes $/lb per bucket per metal: (sum revenue) / (sum weight)
//   • emits _multiSeries (one per top-6 metal type), _labels (month labels)
//
// The v2 path cannot express per-metal multi-series natively. We emit a
// single all-metals combined $/lb trend (SUM revenue / SUM weight per month)
// as the best single-query approximation. Users who need per-metal breakdown
// can use the wizard's filter to isolate one metal type.
//
// query_v2 equivalent (all-metals combined):
//
//   SELECT date_trunc('month', t."created_date") AS "bucket_start",
//          to_char(date_trunc('month', t."created_date"), 'Mon YYYY')
//              AS "bucket_label",
//          SUM(t."buyer_line_total")  AS "Revenue",
//          SUM(t."total_weight")      AS "Weight_lbs"
//   FROM rds_user_purchase_order_line t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//     AND t."buyer_line_total" > 0
//     AND t."total_weight" > 0
//   GROUP BY date_trunc('month', t."created_date")
//   ORDER BY "bucket_start" ASC;
//
// The render layer divides Revenue / Weight_lbs to get $/lb. The v2 wizard
// can display either column independently; the $/lb ratio requires a
// post-fetch computed column (not yet in the wizard UI).
CannedTranslation _avgPricePerLbByMetalTrend() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_user_purchase_order_line',
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
    filters: [
      FilterSpec(
        table: 'rds_user_purchase_order_line',
        column: 'buyer_line_total',
        op: '>',
        value: 0,
      ),
      FilterSpec(
        table: 'rds_user_purchase_order_line',
        column: 'total_weight',
        op: '>',
        value: 0,
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_user_purchase_order_line',
        column: 'buyer_line_total',
        fn: 'sum',
        alias: 'Revenue',
      ),
      AggregateSpec(
        table: 'rds_user_purchase_order_line',
        column: 'total_weight',
        fn: 'sum',
        alias: 'Weight_lbs',
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
        'widget-data-bryzos renders a per-metal multi-series chart '
        '(top 6 metals × months) where each point is '
        'SUM(revenue)/SUM(weight) for that metal+month. The v2 path emits '
        'two columns — Revenue (SUM buyer_line_total) and Weight_lbs '
        '(SUM total_weight) for ALL metals combined per month. Divide them '
        'at the render layer to get the all-metals \$/lb trend. To isolate '
        'a single metal, add a metal_type filter in the wizard.',
  );
}

// ─── Slice #42: chat_volume_by_month ─────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date from channel_chat_messages
//   • buckets by month (using the active time window), counts rows per bucket
//   • emits _data (series), _labels (month labels), _yLabel="Messages"
//
// query_v2 equivalent:
//
//   SELECT date_trunc('month', t."created_date") AS "bucket_start",
//          to_char(date_trunc('month', t."created_date"), 'Mon YYYY')
//              AS "bucket_label",
//          count(*) AS "Messages"
//   FROM rds_channel_chat_messages t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//   GROUP BY date_trunc('month', t."created_date")
//   ORDER BY "bucket_start" ASC;
CannedTranslation _chatVolumeByMonth() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_channel_chat_messages',
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
        table: 'rds_channel_chat_messages',
        column: '',
        fn: 'count',
        alias: 'Messages',
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
      y: 'Messages',
    ),
  );

  return CannedTranslation(
    query: q,
    postFetchNote:
        'widget-data-bryzos additionally emits a prior-period count in _meta. '
        'Display-only and not reproduced by the v2 render path in this slice.',
  );
}

// ─── Slice #43: yoy_revenue ───────────────────────────────────────────────
//
// widget-data-bryzos:
//   • fetches created_date, buyer_po_price from user_purchase_order
//   • When time_range = "All": emits a single revenue-by-month series
//     across all history (same as revenue_by_month).
//   • When time_range ≠ "All": compares last 12 months vs prior 12 months
//     as two series ("This Year" / "Prior Year") — a multi-series chart
//     that the v2 render path cannot express natively.
//
// The v2 path emits a single revenue-by-month series (identical to
// revenue_by_month). The time wizard applies the user's chosen window.
// Users who need the side-by-side YoY view should use the canned widget
// directly; the clone is best suited for inspecting the full trend line.
//
// query_v2 equivalent:
//
//   SELECT date_trunc('month', t."created_date") AS "bucket_start",
//          to_char(date_trunc('month', t."created_date"), 'Mon YYYY')
//              AS "bucket_label",
//          SUM(t."buyer_po_price") AS "Revenue"
//   FROM rds_user_purchase_order t
//   WHERE t."tenant_id" = :tenant_id AND t."data_source_id" = :data_source_id
//   GROUP BY date_trunc('month', t."created_date")
//   ORDER BY "bucket_start" ASC;
CannedTranslation _yoyRevenue() {
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
        'widget-data-bryzos renders a dual-series "This Year vs Prior Year" '
        'chart (last 12 months vs prior 12 months) when time_range ≠ "All". '
        'The v2 path emits a single revenue-by-month series across the full '
        'history — multi-series YoY comparison is not expressible in a single '
        'query_v2 spec. Use the canned widget directly for the side-by-side view.',
  );
}

// ─── Slice #36: orders_with_chat ─────────────────────────────────────────
//
// widget-data-bryzos: KPI = count(distinct po_number) across
// channel_chat_messages within the current window. Also emits a top-N table
// of PO -> message-count pairs, but the KPI itself is just the distinct
// count.
CannedTranslation _ordersWithChat() {
  final q = CustomReportQueryV2(
    primaryTable: 'rds_channel_chat_messages',
    filters: [
      FilterSpec(
        table: 'rds_channel_chat_messages',
        column: 'po_number',
        op: 'IS NOT NULL',
      ),
      FilterSpec(
        table: 'rds_channel_chat_messages',
        column: 'po_number',
        op: '!=',
        value: '',
      ),
    ],
    aggregates: [
      AggregateSpec(
        table: 'rds_channel_chat_messages',
        column: 'po_number',
        fn: 'count_distinct',
        alias: 'Orders w/ Chat',
      ),
    ],
    viz: VizSpec(chartType: 'kpi', y: 'Orders w/ Chat'),
  );
  return CannedTranslation(
    query: q,
    postFetchNote:
        'The widget also emits a per-PO message-count table via _rows. This '
        'v2 slice materialises the KPI only (count-distinct po_number).',
  );
}
