/// Optics — Custom Report Builder v2
///
/// Data model + JSON ser/deser for the `custom_report_query_v2` shape
/// consumed by the `rds_execute_query` RPC (ADR-0013).
library;

class JoinOnPair {
  final String fromTable;
  final String fromColumn;
  final String toTable;
  final String toColumn;
  const JoinOnPair({
    required this.fromTable,
    required this.fromColumn,
    required this.toTable,
    required this.toColumn,
  });

  Map<String, dynamic> toJson() => {
        'from': '$fromTable.$fromColumn',
        'to': '$toTable.$toColumn',
      };

  static JoinOnPair? fromJson(Map<String, dynamic> j) {
    final f = (j['from'] as String?)?.split('.') ?? const [];
    final t = (j['to'] as String?)?.split('.') ?? const [];
    if (f.length != 2 || t.length != 2) return null;
    return JoinOnPair(
      fromTable: f[0],
      fromColumn: f[1],
      toTable: t[0],
      toColumn: t[1],
    );
  }
}

enum JoinType { left, inner }

class JoinSpec {
  final String table;       // mirror table name (e.g. "rds_user") or external ("states")
  final JoinType type;
  final bool external;      // true → public.<table> (no rds_ prefix, no tenant scope)
  final List<JoinOnPair> on;
  JoinSpec({
    required this.table,
    this.type = JoinType.left,
    this.external = false,
    required this.on,
  });

  Map<String, dynamic> toJson() => {
        'table': table,
        'type': type == JoinType.left ? 'LEFT' : 'INNER',
        if (external) 'external': true,
        'on': on.map((p) => p.toJson()).toList(),
      };

  static JoinSpec fromJson(Map<String, dynamic> j) => JoinSpec(
        table: j['table'] as String,
        type: ((j['type'] as String?) ?? 'LEFT').toUpperCase() == 'INNER'
            ? JoinType.inner
            : JoinType.left,
        external: (j['external'] as bool?) ?? false,
        on: ((j['on'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(JoinOnPair.fromJson)
            .whereType<JoinOnPair>()
            .toList(),
      );
}

class ColumnRef {
  final String table;
  final String column;
  final String alias;
  ColumnRef({required this.table, required this.column, required this.alias});
  Map<String, dynamic> toJson() => {
        'table': table,
        'column': column,
        'alias': alias,
      };
  static ColumnRef fromJson(Map<String, dynamic> j) => ColumnRef(
        table: j['table'] as String,
        column: j['column'] as String,
        alias: (j['alias'] as String?) ?? (j['column'] as String),
      );
}

const List<String> kFilterOps = [
  '=',
  '!=',
  '>',
  '<',
  '>=',
  '<=',
  'LIKE',
  'ILIKE',
  'IN',
  'NOT IN',
  'BETWEEN',
  'IS NULL',
  'IS NOT NULL',
];

class FilterSpec {
  final String table;
  final String column;
  final String op;
  /// String, num, bool, List for IN/NOT IN/BETWEEN, or null for IS [NOT] NULL.
  final dynamic value;
  FilterSpec({
    required this.table,
    required this.column,
    required this.op,
    this.value,
  });
  Map<String, dynamic> toJson() => {
        'table': table,
        'column': column,
        'op': op,
        if (value != null) 'value': value,
      };
  static FilterSpec fromJson(Map<String, dynamic> j) => FilterSpec(
        table: j['table'] as String,
        column: j['column'] as String,
        op: j['op'] as String,
        value: j['value'],
      );
}

const List<String> kAggregateFns = [
  'sum',
  'avg',
  'count',
  'count_distinct',
  'min',
  'max',
];

class AggregateSpec {
  final String table;
  final String column;
  final String fn;
  final String alias;
  AggregateSpec({
    required this.table,
    required this.column,
    required this.fn,
    required this.alias,
  });
  Map<String, dynamic> toJson() => {
        'table': table,
        'column': column,
        'fn': fn,
        'alias': alias,
      };
  static AggregateSpec fromJson(Map<String, dynamic> j) => AggregateSpec(
        table: j['table'] as String,
        column: (j['column'] as String?) ?? '',
        fn: j['fn'] as String,
        alias: j['alias'] as String,
      );
}

class GroupBySpec {
  final String table;
  final String column;
  GroupBySpec({required this.table, required this.column});
  Map<String, dynamic> toJson() => {'table': table, 'column': column};
  static GroupBySpec fromJson(Map<String, dynamic> j) =>
      GroupBySpec(table: j['table'] as String, column: j['column'] as String);
}

class OrderBySpec {
  final String alias;
  final String dir; // ASC | DESC
  OrderBySpec({required this.alias, this.dir = 'ASC'});
  Map<String, dynamic> toJson() => {'alias': alias, 'dir': dir};
  static OrderBySpec fromJson(Map<String, dynamic> j) =>
      OrderBySpec(alias: j['alias'] as String, dir: (j['dir'] as String?) ?? 'ASC');
}

class VizSpec {
  final String chartType; // kpi, bar, line, area, pie, donut, table, hbar, ...
  final String? x;
  final String? y;
  VizSpec({this.chartType = 'table', this.x, this.y});
  Map<String, dynamic> toJson() => {
        'chart_type': chartType,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
      };
  static VizSpec fromJson(Map<String, dynamic> j) => VizSpec(
        chartType: (j['chart_type'] as String?) ?? 'table',
        x: j['x'] as String?,
        y: j['y'] as String?,
      );
}

class CustomReportQueryV2 {
  String? primaryTable; // canonical rds_<x> or external name; null until step 1 done
  final List<JoinSpec> joins;
  final List<ColumnRef> columns;
  final List<FilterSpec> filters;
  final List<GroupBySpec> groupBy;
  final List<AggregateSpec> aggregates;
  final List<OrderBySpec> orderBy;
  int? limit;
  VizSpec viz;
  bool showShare;

  CustomReportQueryV2({
    this.primaryTable,
    List<JoinSpec>? joins,
    List<ColumnRef>? columns,
    List<FilterSpec>? filters,
    List<GroupBySpec>? groupBy,
    List<AggregateSpec>? aggregates,
    List<OrderBySpec>? orderBy,
    this.limit,
    VizSpec? viz,
    this.showShare = true,
  })  : joins = joins ?? [],
        columns = columns ?? [],
        filters = filters ?? [],
        groupBy = groupBy ?? [],
        aggregates = aggregates ?? [],
        orderBy = orderBy ?? [],
        viz = viz ?? VizSpec();

  Map<String, dynamic> toJson() => {
        'version': 2,
        if (primaryTable != null) 'primary_table': primaryTable,
        'joins': joins.map((j) => j.toJson()).toList(),
        'columns': columns.map((c) => c.toJson()).toList(),
        'filters': filters.map((f) => f.toJson()).toList(),
        'group_by': groupBy.map((g) => g.toJson()).toList(),
        'aggregates': aggregates.map((a) => a.toJson()).toList(),
        'order_by': orderBy.map((o) => o.toJson()).toList(),
        if (limit != null) 'limit': limit,
        'viz': viz.toJson(),
        if (!showShare) 'show_share': false,
      };

  static CustomReportQueryV2 fromJson(Map<String, dynamic> j) =>
      CustomReportQueryV2(
        primaryTable: j['primary_table'] as String?,
        joins: ((j['joins'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(JoinSpec.fromJson)
            .toList(),
        columns: ((j['columns'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ColumnRef.fromJson)
            .toList(),
        filters: ((j['filters'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FilterSpec.fromJson)
            .toList(),
        groupBy: ((j['group_by'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(GroupBySpec.fromJson)
            .toList(),
        aggregates: ((j['aggregates'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AggregateSpec.fromJson)
            .toList(),
        orderBy: ((j['order_by'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(OrderBySpec.fromJson)
            .toList(),
        limit: j['limit'] is int ? j['limit'] as int : null,
        viz: j['viz'] is Map<String, dynamic>
            ? VizSpec.fromJson(j['viz'] as Map<String, dynamic>)
            : VizSpec(),
        showShare: j['show_share'] is bool ? j['show_share'] as bool : true,
      );

  /// All tables referenced in this query (primary + joins).
  List<String> allTables() {
    final s = <String>{};
    if (primaryTable != null) s.add(primaryTable!);
    for (final j in joins) {
      s.add(j.table);
    }
    return s.toList();
  }

  /// Returns a list of canonical (lowercase, rds_-prefixed for mirrors)
  /// table names so they round-trip cleanly with the server contract.
  String normalizeTableName(String raw, {bool external = false}) {
    final lower = raw.toLowerCase();
    if (external) return lower;
    return lower.startsWith('rds_') ? lower : 'rds_$lower';
  }
}
