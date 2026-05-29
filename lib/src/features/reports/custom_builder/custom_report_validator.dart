// Optics — Custom Report Builder validator
//
// Pure, side-effect-free analysis of a `CustomReportQueryV2`. Returns a list
// of `ValidationIssue`s, each tagged with the wizard step that owns it and a
// severity. The wizard binds these to:
//   * a red/amber dot on the step rail,
//   * a "why is my preview empty?" banner in the live-preview panel,
//   * inline helper text/tooltips on the offending step.
//
// All checks are intentionally conservative — we only fire when the user is
// guaranteed to hit an error or an empty result. Stylistic suggestions belong
// elsewhere.

import 'custom_report_query_v2.dart';

enum IssueSeverity { error, warning, info }

class ValidationIssue {
  /// 0-indexed step (0=Tables, 1=Columns, 2=Filters, 3=Group, 4=Sort, 5=Viz).
  final int step;
  final IssueSeverity severity;
  final String title;
  final String detail;
  final String? fixHint;

  const ValidationIssue({
    required this.step,
    required this.severity,
    required this.title,
    required this.detail,
    this.fixHint,
  });
}

class ValidationReport {
  final List<ValidationIssue> issues;
  const ValidationReport(this.issues);

  bool get hasBlockers =>
      issues.any((i) => i.severity == IssueSeverity.error);

  /// Issues that explain why the preview would be empty or fail.
  Iterable<ValidationIssue> get blockers =>
      issues.where((i) => i.severity == IssueSeverity.error);

  Iterable<ValidationIssue> forStep(int step) =>
      issues.where((i) => i.step == step);

  IssueSeverity? worstForStep(int step) {
    IssueSeverity? worst;
    for (final i in forStep(step)) {
      if (i.severity == IssueSeverity.error) return IssueSeverity.error;
      if (i.severity == IssueSeverity.warning) worst = IssueSeverity.warning;
      worst ??= IssueSeverity.info;
    }
    return worst;
  }
}

/// Returns a fresh report on every call. Cheap — pure traversal.
ValidationReport validateCustomReportQuery(CustomReportQueryV2 q) {
  final out = <ValidationIssue>[];

  // ── STEP 1 · TABLES ──────────────────────────────────────────────────────
  if (q.primaryTable == null) {
    out.add(const ValidationIssue(
      step: 0,
      severity: IssueSeverity.error,
      title: 'Pick a primary table',
      detail:
          'Every report starts from one table. Choose one in Step 1 to enable the rest of the wizard.',
      fixHint: 'Open Step 1 and click a table.',
    ));
  }

  for (final j in q.joins) {
    if (j.on.isEmpty) {
      out.add(ValidationIssue(
        step: 0,
        severity: IssueSeverity.error,
        title: 'Join is missing an ON clause',
        detail:
            '"${_bare(j.table)}" is added to the query but has no join condition. The database can\'t match rows without one.',
        fixHint:
            'Remove the table or pick a relationship column pair in Step 1.',
      ));
    }
  }

  // ── STEP 2 · COLUMNS ─────────────────────────────────────────────────────
  if (q.primaryTable != null &&
      q.columns.isEmpty &&
      q.aggregates.isEmpty) {
    out.add(const ValidationIssue(
      step: 1,
      severity: IssueSeverity.error,
      title: 'Pick at least one column',
      detail:
          'The query has no SELECT projection. Tick a column in Step 2, or add an aggregate in Step 4.',
      fixHint: 'Open Step 2 and tick a column.',
    ));
  }

  // Alias collisions between columns and aggregates would produce ambiguous
  // result keys.
  final aliasCount = <String, int>{};
  for (final c in q.columns) {
    aliasCount[c.alias] = (aliasCount[c.alias] ?? 0) + 1;
  }
  for (final a in q.aggregates) {
    aliasCount[a.alias] = (aliasCount[a.alias] ?? 0) + 1;
  }
  final dupes = aliasCount.entries
      .where((e) => e.value > 1)
      .map((e) => e.key)
      .toList();
  if (dupes.isNotEmpty) {
    out.add(ValidationIssue(
      step: 1,
      severity: IssueSeverity.warning,
      title: 'Duplicate result aliases',
      detail:
          'These names appear more than once: ${dupes.join(", ")}. The last one wins in the result map.',
      fixHint:
          'Rename one side — give the aggregate a distinct alias in Step 4.',
    ));
  }

  // ── STEP 3 · FILTERS ─────────────────────────────────────────────────────
  for (var i = 0; i < q.filters.length; i++) {
    final f = q.filters[i];
    final needsValue = _opNeedsValue(f.op);
    final hasValue = f.value != null &&
        !(f.value is String && (f.value as String).trim().isEmpty);
    if (needsValue && !hasValue) {
      out.add(ValidationIssue(
        step: 2,
        severity: IssueSeverity.error,
        title: 'Filter is missing a value',
        detail:
            '${_bare(f.table)}.${f.column} ${f.op} … needs a value to compare against. Without one, MySQL returns nothing.',
        fixHint: 'Enter a value next to the filter in Step 3.',
      ));
    }
    if (f.op == 'BETWEEN') {
      final v = f.value;
      if (v is! List || v.length != 2) {
        out.add(ValidationIssue(
          step: 2,
          severity: IssueSeverity.error,
          title: 'BETWEEN needs two values',
          detail:
              '${_bare(f.table)}.${f.column} BETWEEN … requires a lower and upper bound.',
          fixHint: 'Provide both ends of the range in Step 3.',
        ));
      }
    }
    if ((f.op == 'IN' || f.op == 'NOT IN')) {
      final v = f.value;
      if (v is! List || v.isEmpty) {
        out.add(ValidationIssue(
          step: 2,
          severity: IssueSeverity.error,
          title: '${f.op} needs at least one value',
          detail:
              '${_bare(f.table)}.${f.column} ${f.op} (…) requires a non-empty list.',
          fixHint: 'Add one or more values in Step 3.',
        ));
      }
    }
  }

  // ── STEP 4 · GROUP / AGGREGATE ───────────────────────────────────────────
  // The big one: if there's a GROUP BY or an aggregate, every non-aggregated
  // SELECT column must appear in the GROUP BY (MySQL ONLY_FULL_GROUP_BY).
  final hasGroupBy = q.groupBy.isNotEmpty;
  final hasAggregate = q.aggregates.isNotEmpty;
  if (hasGroupBy || hasAggregate) {
    // A column is "covered" iff (table, column) appears in groupBy.
    final groupKeys = <String>{
      for (final g in q.groupBy) '${g.table}.${g.column}',
    };
    final uncovered = <ColumnRef>[];
    for (final c in q.columns) {
      final key = '${c.table}.${c.column}';
      if (!groupKeys.contains(key)) uncovered.add(c);
    }
    if (uncovered.isNotEmpty) {
      final names = uncovered
          .map((c) => '${_bare(c.table)}.${c.column}')
          .toList();
      out.add(ValidationIssue(
        step: 3,
        severity: IssueSeverity.error,
        title: 'GROUP BY / SELECT mismatch',
        detail:
            'When you group or aggregate, every selected column must either be in GROUP BY or wrapped in an aggregate. These aren\'t: ${names.join(", ")}.',
        fixHint:
            'Either remove the GROUP BY, add these columns to it, or turn them into aggregates (MIN/MAX/COUNT).',
      ));
    }
  }

  // Aggregate that references a column not present in the chosen tables is
  // a real foot-gun. We only do a shallow check (non-empty column).
  for (final a in q.aggregates) {
    final isCountStar = a.fn == 'count' && (a.column.isEmpty || a.column == '*');
    if (!isCountStar && a.column.isEmpty) {
      out.add(ValidationIssue(
        step: 3,
        severity: IssueSeverity.error,
        title: 'Aggregate is missing a column',
        detail:
            '"${a.alias}" uses ${a.fn.toUpperCase()}() with no column.',
        fixHint: 'Pick a column for the aggregate in Step 4.',
      ));
    }
    if (a.alias.trim().isEmpty) {
      out.add(ValidationIssue(
        step: 3,
        severity: IssueSeverity.error,
        title: 'Aggregate is missing an alias',
        detail:
            '${a.fn.toUpperCase()}(${_bare(a.table)}.${a.column}) needs a result alias.',
        fixHint: 'Type a short name in the alias field.',
      ));
    }
  }

  // ── STEP 5 · SORT & LIMIT ────────────────────────────────────────────────
  final allAliases = <String>{
    for (final c in q.columns) c.alias,
    for (final a in q.aggregates) a.alias,
  };
  for (final o in q.orderBy) {
    if (!allAliases.contains(o.alias)) {
      out.add(ValidationIssue(
        step: 4,
        severity: IssueSeverity.error,
        title: 'Sort references an unknown alias',
        detail:
            '"${o.alias}" isn\'t a selected column or aggregate. The database will reject this query.',
        fixHint:
            'Pick a different column in the sort row, or add the column in Step 2.',
      ));
    }
  }
  if (q.limit != null && q.limit! <= 0) {
    out.add(const ValidationIssue(
      step: 4,
      severity: IssueSeverity.error,
      title: 'Limit must be positive',
      detail: 'A row limit of 0 or less returns no rows.',
      fixHint: 'Clear the limit or enter a number greater than 0.',
    ));
  }

  // ── STEP 6 · VISUALIZE ───────────────────────────────────────────────────
  final chart = q.viz.chartType;
  final needsXY = const {
    'bar', 'hbar', 'line', 'area', 'pie', 'donut', 'combo'
  }.contains(chart);
  final needsY = const {'kpi', 'gauge'}.contains(chart);

  if (needsXY) {
    if (q.viz.x == null || !allAliases.contains(q.viz.x)) {
      out.add(ValidationIssue(
        step: 5,
        severity: IssueSeverity.warning,
        title: 'Chart has no X axis',
        detail:
            '${chart.toUpperCase()} charts need a category for X. The preview will fall back to a table until you pick one.',
        fixHint: 'Pick an X axis on Step 6.',
      ));
    }
    if (q.viz.y != null && !allAliases.contains(q.viz.y)) {
      out.add(ValidationIssue(
        step: 5,
        severity: IssueSeverity.warning,
        title: 'Chart Y axis is invalid',
        detail:
            '"${q.viz.y}" is no longer a selected column or aggregate.',
        fixHint: 'Pick a numeric aggregate (SUM, COUNT, …) for Y.',
      ));
    }
  }
  if (needsY) {
    if (q.viz.y == null || !allAliases.contains(q.viz.y)) {
      out.add(ValidationIssue(
        step: 5,
        severity: IssueSeverity.warning,
        title: '${chart.toUpperCase()} needs a value field',
        detail:
            'Pick the numeric column or aggregate this ${chart.toUpperCase()} should display.',
        fixHint: 'Choose a Y field on Step 6.',
      ));
    }
  }

  return ValidationReport(out);
}

bool _opNeedsValue(String op) {
  switch (op) {
    case 'IS NULL':
    case 'IS NOT NULL':
      return false;
    default:
      return true;
  }
}

String _bare(String t) => t.startsWith('rds_') ? t.substring(4) : t;
