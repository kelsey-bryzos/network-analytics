/// Optics — Custom Report Builder v2
///
/// Pure-Dart SQL generator for `CustomReportQueryV2`. Mirrors the SQL that
/// `public.rds_execute_query` emits so users can see the exact statement
/// that will run against Postgres before they clone/execute.
///
/// Contract:
///   * Output dialect: Postgres (identifiers double-quoted, `::text` casts).
///   * Table aliases: primary → `t`; joins → `j1`, `j2`, ... in order.
///   * Mirror tables receive the `rds_` prefix; external joins do not.
///   * Tenant + data_source predicates use `:tenant_id` / `:data_source_id`
///     placeholders so the string is safe to display without leaking IDs.
///   * When `comparison_window` is present, both statements are returned;
///     the caller can display them side-by-side or concatenated.
///
/// This generator is **display-oriented**. The database RPC re-derives its
/// own SQL from the same JSON on execute, so any drift here is a UX bug
/// only — it can never cause a wrong query to run.
library;

import 'custom_report_query_v2.dart';

/// Result of generating SQL from a `CustomReportQueryV2`.
///
/// * When the query has no `comparison_window`, [current] holds the single
///   emitted statement and [prior] is `null`.
/// * When a `comparison_window` is set, [current] and [prior] each hold the
///   fully-formed statement for that window.
class GeneratedSql {
  final String current;
  final String? prior;
  final List<String> warnings;

  const GeneratedSql({
    required this.current,
    this.prior,
    this.warnings = const [],
  });

  bool get isComparison => prior != null;

  /// Convenience: both statements concatenated with a divider, suitable for
  /// a single read-only editor pane.
  String combined() {
    if (prior == null) return current;
    return '-- current window\n$current\n\n-- prior window\n$prior';
  }
}

/// Generates a Postgres SELECT statement from a `CustomReportQueryV2`.
///
/// If [q] uses the raw-SQL escape hatch (`useRawSql == true`), the authored
/// SQL is returned as-is (or the legacy `rawSql` field for pre-normalizer
/// rows). Otherwise the wizard state is walked and emitted.
GeneratedSql generateSqlFromQueryV2(CustomReportQueryV2 q) {
  final warnings = <String>[];

  if (q.useRawSql) {
    final authored = (q.sqlAuthored ?? '').trim();
    final legacy = (q.rawSql ?? '').trim();
    final text = authored.isNotEmpty
        ? authored
        : (legacy.isNotEmpty ? legacy : '-- (no SQL authored)');
    return GeneratedSql(current: text, warnings: warnings);
  }

  final primary = (q.primaryTable ?? '').toLowerCase();
  if (primary.isEmpty) {
    return GeneratedSql(
      current: '-- (primary table not selected)',
      warnings: const ['primary_table is required'],
    );
  }

  // Build alias map: primary → 't'; joins → 'j1', 'j2', ...
  // Keys are the "stem" name without any `rds_` prefix (matches RPC logic).
  final primaryStem =
      primary.startsWith('rds_') ? primary.substring(4) : primary;
  final primaryPhys =
      primary.startsWith('rds_') ? primary : 'rds_$primary';

  final aliasOf = <String, String>{primaryStem: 't'};
  final physOf = <String, String>{primaryStem: primaryPhys};
  final isExternal = <String, bool>{primaryStem: false};

  var joinCounter = 0;
  for (final j in q.joins) {
    final raw = j.table.toLowerCase();
    final stem = j.external
        ? raw
        : (raw.startsWith('rds_') ? raw.substring(4) : raw);
    if (aliasOf.containsKey(stem)) continue;
    joinCounter += 1;
    aliasOf[stem] = 'j$joinCounter';
    physOf[stem] = j.external
        ? stem
        : (raw.startsWith('rds_') ? raw : 'rds_$raw');
    isExternal[stem] = j.external;
  }

  String stemOf(String rawTable) {
    final low = rawTable.toLowerCase();
    return low.startsWith('rds_') ? low.substring(4) : low;
  }

  String qi(String ident) => '"$ident"';

  // ── SELECT list ─────────────────────────────────────────────────────────
  final selectParts = <String>[];

  for (final c in q.columns) {
    final stem = stemOf(c.table);
    final alias = aliasOf[stem];
    if (alias == null) {
      warnings.add('column references unjoined table "$stem"');
      continue;
    }
    selectParts.add('$alias.${qi(c.column)} AS ${qi(c.alias)}');
  }

  for (final a in q.aggregates) {
    final fn = a.fn.toLowerCase();
    String expr;
    if (fn == 'count' && a.column.isEmpty) {
      expr = 'count(*)';
    } else {
      final stem = stemOf(a.table);
      final alias = aliasOf[stem];
      if (alias == null) {
        warnings.add('aggregate references unjoined table "$stem"');
        continue;
      }
      final colRef = '$alias.${qi(a.column)}';
      if (fn == 'count_distinct') {
        expr = 'count(distinct $colRef)';
      } else {
        expr = '$fn($colRef)';
      }
    }
    selectParts.add('$expr AS ${qi(a.alias)}');
  }

  for (final cc in q.computedColumns) {
    // Emit verbatim — the wizard-time normalizer is responsible for turning
    // MySQL-flavored expressions into Postgres before they reach this point.
    selectParts.add('${cc.expression} AS ${qi(cc.alias)}');
  }

  if (selectParts.isEmpty) {
    selectParts.add('/* no columns selected */ null');
    warnings.add('at least one column, aggregate, or computed_column is required');
  }

  // ── FROM + JOINs ────────────────────────────────────────────────────────
  final fromClause = 'FROM public.${qi(primaryPhys)} t';

  final joinSb = StringBuffer();
  for (final j in q.joins) {
    final stem = j.external
        ? j.table.toLowerCase()
        : stemOf(j.table);
    final alias = aliasOf[stem]!;
    final phys = physOf[stem]!;
    final joinKeyword = j.type == JoinType.inner ? 'INNER JOIN' : 'LEFT JOIN';
    final onParts = <String>[];

    for (final pair in j.on) {
      final fromStem = stemOf(pair.fromTable);
      final toStem = stemOf(pair.toTable);
      final fromAlias = aliasOf[fromStem];
      final toAlias = aliasOf[toStem];
      if (fromAlias == null || toAlias == null) {
        warnings.add('ON pair references unknown table');
        continue;
      }
      onParts.add(
        '$fromAlias.${qi(pair.fromColumn)}::text = '
        '$toAlias.${qi(pair.toColumn)}::text',
      );
    }

    if (!j.external) {
      onParts.add('$alias."tenant_id" = :tenant_id');
      onParts.add('$alias."data_source_id" = :data_source_id');
    }

    joinSb.write('\n  $joinKeyword public.${qi(phys)} $alias');
    joinSb.write(' ON ${onParts.join(' AND ')}');
  }

  // ── WHERE ───────────────────────────────────────────────────────────────
  final whereParts = <String>[
    't."tenant_id" = :tenant_id',
    't."data_source_id" = :data_source_id',
  ];

  String renderFilterValue(dynamic v) {
    if (v == null) return 'NULL';
    if (v is num || v is bool) return v.toString();
    if (v is String) return "'${v.replaceAll("'", "''")}'";
    return "'${v.toString().replaceAll("'", "''")}'";
  }

  for (final f in q.filters) {
    final stem = stemOf(f.table);
    final alias = aliasOf[stem];
    if (alias == null) {
      warnings.add('filter references unjoined table "$stem"');
      continue;
    }
    final lhs = '$alias.${qi(f.column)}';
    final op = f.op.toUpperCase();

    if (op == 'IS NULL' || op == 'IS NOT NULL') {
      whereParts.add('$lhs $op');
    } else if (op == 'IN' || op == 'NOT IN') {
      final list = (f.value is List) ? (f.value as List) : const [];
      if (list.isEmpty) {
        warnings.add('$op requires non-empty array value');
        continue;
      }
      final rendered = list.map(renderFilterValue).join(', ');
      whereParts.add('$lhs::text $op ($rendered)');
    } else if (op == 'BETWEEN') {
      final list = (f.value is List) ? (f.value as List) : const [];
      if (list.length != 2) {
        warnings.add('BETWEEN requires a 2-element array value');
        continue;
      }
      whereParts.add(
        '$lhs::text BETWEEN ${renderFilterValue(list[0])} AND ${renderFilterValue(list[1])}',
      );
    } else {
      whereParts.add('$lhs::text $op ${renderFilterValue(f.value)}');
    }
  }

  // ── GROUP BY ────────────────────────────────────────────────────────────
  // Two forms supported: column ({table, column}) and alias (references a
  // computed_column by alias — emits the underlying expression verbatim,
  // mirroring the RPC's behavior).
  final computedByAlias = <String, String>{
    for (final cc in q.computedColumns) cc.alias: cc.expression,
  };
  final groupParts = <String>[];
  for (final g in q.groupBy) {
    if (g.isAlias) {
      final expr = computedByAlias[g.alias];
      if (expr == null) {
        warnings.add(
          'group_by alias "${g.alias}" does not match any computed_column',
        );
        continue;
      }
      groupParts.add(expr);
      continue;
    }
    final stem = stemOf(g.table ?? '');
    final alias = aliasOf[stem];
    if (alias == null) {
      warnings.add('group_by references unjoined table "$stem"');
      continue;
    }
    groupParts.add('$alias.${qi(g.column!)}');
  }

  // ── ORDER BY ────────────────────────────────────────────────────────────
  final orderParts = <String>[];
  final validAliases = <String>{
    ...q.columns.map((c) => c.alias),
    ...q.aggregates.map((a) => a.alias),
    ...q.computedColumns.map((c) => c.alias),
  };
  for (final o in q.orderBy) {
    if (!validAliases.contains(o.alias)) {
      warnings.add('order_by alias "${o.alias}" is not in the select list');
      continue;
    }
    final dir = o.dir.toUpperCase() == 'DESC' ? 'DESC' : 'ASC';
    orderParts.add('${qi(o.alias)} $dir');
  }

  // ── Assemble base pieces ────────────────────────────────────────────────
  String assemble({List<String>? extraWhere}) {
    final sb = StringBuffer();
    sb.write('SELECT ');
    sb.write(selectParts.join(', '));
    sb.write('\n');
    sb.write(fromClause);
    if (joinSb.isNotEmpty) sb.write(joinSb.toString());
    final allWhere = <String>[...whereParts, ...?extraWhere];
    sb.write('\nWHERE ${allWhere.join('\n  AND ')}');
    if (groupParts.isNotEmpty) {
      sb.write('\nGROUP BY ${groupParts.join(', ')}');
    }
    if (orderParts.isNotEmpty) {
      sb.write('\nORDER BY ${orderParts.join(', ')}');
    }
    if (q.limit != null) {
      sb.write('\nLIMIT ${q.limit}');
    }
    sb.write(';');
    return sb.toString();
  }

  // ── Comparison window ───────────────────────────────────────────────────
  final cw = q.comparisonWindow;
  if (cw != null) {
    final stem = stemOf(cw.table);
    final alias = aliasOf[stem];
    if (alias == null) {
      warnings.add(
        'comparison_window references unjoined table "${cw.table}"',
      );
      return GeneratedSql(current: assemble(), warnings: warnings);
    }
    final lhs = '$alias.${qi(cw.column)}';
    final curr = assemble(extraWhere: [
      "$lhs >= '${cw.currentStart}'",
      "$lhs <  '${cw.currentEnd}'",
    ]);
    final prior = assemble(extraWhere: [
      "$lhs >= '${cw.priorStart}'",
      "$lhs <  '${cw.priorEnd}'",
    ]);
    return GeneratedSql(current: curr, prior: prior, warnings: warnings);
  }

  return GeneratedSql(current: assemble(), warnings: warnings);
}
