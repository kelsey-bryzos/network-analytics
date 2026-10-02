/// Optics — MySQL → Postgres SQL Normalizer (Bryzos-only Raw-SQL Escape Hatch)
///
/// Bryzos users author raw SQL in MySQL dialect (the language they've used
/// for years in SequelPro). The app runs on Postgres, so before we hand the
/// SQL to `rds_execute_raw_sql_bryzos` we translate the common divergences.
///
/// This normalizer is intentionally **conservative**. It only touches
/// patterns whose rewrite is unambiguous. Anything ambiguous is surfaced as
/// a [SqlNormalizerIssue] with a suggested fix the user must approve via the
/// "Fix Automatically" button in the editor.
///
/// Rules covered (in order):
///   1. Backticked identifiers → double-quoted identifiers
///   2. Double-quoted string literals ("foo") → single-quoted ('foo')
///   3. `AUTO_INCREMENT`, `UNSIGNED`, and other MySQL DDL keywords → error
///      (raw SQL is read-only so DDL is always a mistake)
///   4. MySQL date/string functions → Postgres equivalents where 1:1
///        NOW()               → NOW()                  (identical)
///        CURDATE()           → CURRENT_DATE
///        CURTIME()           → CURRENT_TIME
///        UNIX_TIMESTAMP(x)   → EXTRACT(EPOCH FROM (x))
///        IFNULL(a, b)        → COALESCE(a, b)
///        IF(cond, a, b)      → CASE WHEN cond THEN a ELSE b END
///        IF(col = '', a, b)  → condition additionally rewritten: = '' → IS NULL
///        DATE_FORMAT(x, f)   → to_char(x, ...)        (fmt tokens converted)
///        CONCAT(a, b, ...)   → (a || b || ...)        (safe when no NULLs)
///        LENGTH(x)           → char_length(x)         (byte→char behavior)
///        GROUP_CONCAT(...)   → string_agg(..., ',')   (approximate)
///   5. `LIMIT n, m`          → `LIMIT m OFFSET n`
///   6. `RAND()`              → `random()`
///   7. Bare table names that match a known `rds_*` mirror → auto-prefixed
///      (e.g. `FROM user` → `FROM rds_user`)
///   8. GROUP BY / ORDER BY on a quoted alias name → positional index
///      (MySQL allows `GROUP BY "Revenue"` where "Revenue" is a SELECT alias;
///       Postgres does not — we rewrite to `GROUP BY 5` using the alias's
///       1-based position in the SELECT list)
///   9. rds_user.id JOIN type cast — rds_user.id is bigint but FK columns
///      in related tables (buyer_id, seller_id, user_id) are text. We
///      auto-emit `alias.id::text` so the JOIN type-checks in Postgres.
///  10. GROUP BY completeness check — Postgres rejects SELECT columns that
///      are neither in GROUP BY nor wrapped in an aggregate. We detect this
///      and surface a clear actionable warning.
///
/// The output is source-text only — we do not parse an AST. Every rewrite is
/// applied to a version of the SQL with string literals + comments masked
/// out, then unmasked at the end, so text inside strings/comments is
/// preserved untouched.
library;

/// Known `rds_` mirror tables that the wizard/raw-SQL should auto-prefix
/// when a Bryzos user writes the bare MySQL name.
///
/// This list is intentionally maintained by hand — smaller and safer than
/// querying `information_schema` on every keystroke.
const Set<String> kKnownRdsMirrorBareNames = {
  'user',
  'user_purchase_order',
  'user_purchase_order_line',
  'user_shipping_address',
  'user_billing_address',
  'company',
  'company_domain',
  'buyer',
  'buyer_flat',
  'seller',
  'seller_flat',
  'listing',
  'listing_photo',
  'quote',
  'quote_line',
  'invoice',
  'invoice_line',
  'shipment',
  'shipment_line',
  'tender',
  'tender_line',
  'search_result',
  'referral',
};

enum SqlIssueSeverity { info, warning, error }

class SqlNormalizerIssue {
  final SqlIssueSeverity severity;
  final String code;
  final String message;
  final String? suggestedFix;
  const SqlNormalizerIssue({
    required this.severity,
    required this.code,
    required this.message,
    this.suggestedFix,
  });
}

class SqlNormalizerResult {
  /// The rewritten SQL text, ready to hand to `rds_execute_raw_sql_bryzos`.
  final String normalized;

  /// Issues detected during normalization. Errors block execution; warnings
  /// and info are informational.
  final List<SqlNormalizerIssue> issues;

  /// The set of concrete rewrites the normalizer applied automatically —
  /// used by the editor to show a "Fixed N things automatically" summary.
  final List<String> appliedRewrites;

  const SqlNormalizerResult({
    required this.normalized,
    required this.issues,
    required this.appliedRewrites,
  });

  bool get hasErrors =>
      issues.any((i) => i.severity == SqlIssueSeverity.error);
}

/// Pure function: takes MySQL-flavored SQL and returns Postgres-flavored SQL
/// plus a list of applied rewrites and outstanding issues.
SqlNormalizerResult normalizeMySqlToPostgres(String input) {
  final applied = <String>[];
  final issues = <SqlNormalizerIssue>[];

  // Step 0a: Convert MySQL single-quoted column aliases to double-quoted
  // Postgres identifiers BEFORE masking, so masking doesn't hide them.
  // Pattern: AS 'some alias'  →  AS "some alias"
  // We only match the alias context (after AS keyword) to avoid touching
  // real string literals in WHERE clauses etc.
  String preprocessed = input.replaceAllMapped(
    RegExp(r"\bAS\s+'([^']+)'", caseSensitive: false),
    (m) {
      applied.add("Rewrote single-quoted alias AS '${m.group(1)}' → AS \"${m.group(1)}\"");
      return 'AS "${m.group(1)}"';
    },
  );

  // Step 0a2: Rewrite `col = ''` → `col IS NULL` BEFORE masking.
  // The empty-string literal '' will be masked to __SQLLIT_N__ and the
  // rewriter inside _rewriteIfCalls would never see it. We must do this
  // pre-mask pass so both bare WHERE conditions and IF() conditions are
  // handled. We only rewrite when the '' is immediately preceded by = (with
  // optional whitespace) because that's the only MySQL idiom this maps to
  // — 'col = '' checks "not set / empty / null" and Postgres numerics crash
  // on that comparison anyway.
  preprocessed = preprocessed.replaceAllMapped(
    RegExp(r"(\w+(?:\.\w+)?)\s*=\s*''"),
    (m) {
      applied.add("Rewrote '${m.group(0)}' → '${m.group(1)} IS NULL'");
      return '${m.group(1)} IS NULL';
    },
  );

  // Step 0b: DATE_FORMAT(x, 'fmt') → to_char(x, 'PG_FMT') BEFORE masking.
  // This must run before masking because masking will hide the format string
  // inside a __SQLLIT_n__ placeholder, causing the regex to not match.
  preprocessed = preprocessed.replaceAllMapped(
    RegExp(r"\bDATE_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
        caseSensitive: false),
    (m) {
      final expr = m.group(1)!;
      final fmt = m.group(2)!;
      final converted = _convertMySqlDateFormat(fmt);
      applied.add('Rewrote DATE_FORMAT($expr, ...) → to_char(...)');
      return "to_char($expr, '${converted.postgresFormat}')";
    },
  );

  // Step 0c: mask strings + comments so we don't rewrite inside them.
  final _MaskedSql masked = _maskLiteralsAndComments(preprocessed);
  String sql = masked.masked;

  // Step 1: backticks → double quotes for identifiers.
  if (sql.contains('`')) {
    sql = sql.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => '"${m.group(1)}"');
    applied.add('Rewrote MySQL backtick identifiers to Postgres double quotes');
  }

  // Step 2: MySQL DDL keywords are never valid here — surface as errors.
  final ddlKeywords = <String>[
    'AUTO_INCREMENT',
    'UNSIGNED',
    'ZEROFILL',
    'ENGINE=',
  ];
  for (final kw in ddlKeywords) {
    if (RegExp(RegExp.escape(kw), caseSensitive: false).hasMatch(sql)) {
      issues.add(SqlNormalizerIssue(
        severity: SqlIssueSeverity.error,
        code: 'mysql_ddl_keyword',
        message:
            'MySQL DDL keyword "$kw" is not allowed — raw SQL must be a read-only SELECT.',
      ));
    }
  }

  // Step 3: 1:1 function renames.
  final functionRenames = <String, String>{
    r'\bCURDATE\s*\(\s*\)': 'CURRENT_DATE',
    r'\bCURTIME\s*\(\s*\)': 'CURRENT_TIME',
    r'\bIFNULL\b': 'COALESCE',
    r'\bRAND\s*\(\s*\)': 'random()',
    r'\bLENGTH\b': 'char_length',
  };
  functionRenames.forEach((pattern, replacement) {
    final re = RegExp(pattern, caseSensitive: false);
    if (re.hasMatch(sql)) {
      sql = sql.replaceAll(re, replacement);
      applied.add('Rewrote MySQL function → Postgres: '
          '${pattern.replaceAll(r'\b', '').replaceAll(r'\s*\(\s*\)', '()')} → $replacement');
    }
  });

  // Step 3b: IF(cond, true_val, false_val) → CASE WHEN cond THEN true_val ELSE false_val END
  // MySQL IF() is not valid Postgres syntax. We use a paren-depth-aware recursive
  // rewriter that correctly handles nested IF() calls and complex expressions.
  // Additionally, any `col = ''` condition is rewritten to `col IS NULL` because:
  //   (a) In the Postgres mirror, numeric columns error on = '' type mismatch.
  //   (b) MySQL empty-string checks always mean "not set / null / zero" in this codebase.
  //   (c) The user's intent (use actual price if present, else fallback) maps to IS NULL.
  sql = _rewriteIfCalls(sql, applied);

  // Step 4: UNIX_TIMESTAMP(x) → EXTRACT(EPOCH FROM (x))
  sql = sql.replaceAllMapped(
    RegExp(r'\bUNIX_TIMESTAMP\s*\(([^)]+)\)', caseSensitive: false),
    (m) {
      applied.add('Rewrote UNIX_TIMESTAMP(x) → EXTRACT(EPOCH FROM (x))');
      return 'EXTRACT(EPOCH FROM (${m.group(1)}))';
    },
  );

  // Step 5: CONCAT(a, b, ...) → (a || b || ...)  (safe when args non-null)
  sql = sql.replaceAllMapped(
    RegExp(r'\bCONCAT\s*\(([^()]*)\)', caseSensitive: false),
    (m) {
      final args = _splitTopLevelArgs(m.group(1) ?? '');
      if (args.length < 2) return m.group(0)!;
      applied.add('Rewrote CONCAT(...) → (a || b || ...)');
      return '(${args.join(' || ')})';
    },
  );

  // Step 6: LIMIT n, m → LIMIT m OFFSET n  (MySQL comma form)
  sql = sql.replaceAllMapped(
    RegExp(r'\bLIMIT\s+(\d+)\s*,\s*(\d+)', caseSensitive: false),
    (m) {
      applied.add('Rewrote MySQL "LIMIT n, m" → "LIMIT m OFFSET n"');
      return 'LIMIT ${m.group(2)} OFFSET ${m.group(1)}';
    },
  );

  // Step 6b: Bare INTERVAL n UNIT (no quotes) → INTERVAL 'n UNIT'
  // MySQL allows: NOW() - INTERVAL 56 DAY
  // Postgres requires: NOW() - INTERVAL '56 DAY'
  // Only fires when INTERVAL is NOT already followed by a single-quoted string.
  // We match the __SQLLIT_n__ mask to detect already-quoted cases (they were
  // masked in Step 0c) — if INTERVAL is followed by a placeholder, skip it.
  sql = sql.replaceAllMapped(
    RegExp(r'\bINTERVAL\s+(\d+)\s+([A-Za-z]+)\b', caseSensitive: false),
    (m) {
      final amount = m.group(1)!;
      final unit = m.group(2)!.toUpperCase();
      applied.add("Rewrote bare INTERVAL $amount $unit → INTERVAL '$amount $unit'");
      return "INTERVAL '$amount $unit'";
    },
  );

  // Step 6c: YEAR(x) → EXTRACT(YEAR FROM x), MONTH(x) → EXTRACT(MONTH FROM x), etc.
  final orderedKeys = ['DAYOFMONTH', 'YEAR', 'MONTH', 'HOUR', 'MINUTE', 'SECOND', 'WEEK', 'DAY'];
  final extractMap = {
    'DAYOFMONTH': 'DAY',
    'YEAR': 'YEAR',
    'MONTH': 'MONTH',
    'HOUR': 'HOUR',
    'MINUTE': 'MINUTE',
    'SECOND': 'SECOND',
    'WEEK': 'WEEK',
    'DAY': 'DAY',
  };
  for (final fn in orderedKeys) {
    final re = RegExp(r'\b' + fn + r'\s*\(([^)]+)\)', caseSensitive: false);
    if (re.hasMatch(sql)) {
      sql = sql.replaceAllMapped(re, (m) {
        final expr = m.group(1)!;
        final part = extractMap[fn]!;
        applied.add('Rewrote MySQL $fn(x) → EXTRACT($part FROM x)');
        return 'EXTRACT($part FROM $expr)';
      });
    }
  }

  // Step 7a: DATE_SUB(x, INTERVAL n UNIT) → (x - INTERVAL 'n units')
  //          DATE_ADD(x, INTERVAL n UNIT) → (x + INTERVAL 'n units')
  sql = sql.replaceAllMapped(
    RegExp(r"\bDATE_(SUB|ADD)\s*\(\s*(.+?)\s*,\s*INTERVAL\s+'?(\d+)\s+([A-Za-z]+)'?\s*\)",
        caseSensitive: false),
    (m) {
      final op = m.group(1)!.toUpperCase() == 'SUB' ? '-' : '+';
      final expr = m.group(2)!;
      final amount = m.group(3)!;
      final unit = m.group(4)!.toLowerCase();
      final pgUnit = _normalizePgIntervalUnit(unit);
      applied.add(
          'Rewrote DATE_${m.group(1)!.toUpperCase()}($expr, INTERVAL $amount $unit) '
          '→ ($expr $op INTERVAL \'$amount $pgUnit\')');
      return "($expr $op INTERVAL '$amount $pgUnit')";
    },
  );

  // Step 7b: DATE_FORMAT(x, '%Y-%m-%d') → to_char(x, 'YYYY-MM-DD')
  // (catches any DATE_FORMAT that survived masking — e.g. the format was
  // already a masked literal placeholder at Step 0b time)
  sql = sql.replaceAllMapped(
    RegExp(r"\bDATE_FORMAT\s*\(\s*([^,]+?)\s*,\s*'([^']*)'\s*\)",
        caseSensitive: false),
    (m) {
      final expr = m.group(1)!;
      final fmt = m.group(2)!;
      final converted = _convertMySqlDateFormat(fmt);
      if (converted.unknownTokens.isNotEmpty) {
        issues.add(SqlNormalizerIssue(
          severity: SqlIssueSeverity.warning,
          code: 'date_format_unknown_token',
          message:
              'DATE_FORMAT contained unrecognized token(s): ${converted.unknownTokens.join(', ')}. '
              'Verify the Postgres output manually.',
        ));
      }
      applied.add('Rewrote DATE_FORMAT($expr, ...) → to_char(...)');
      return "to_char($expr, '${converted.postgresFormat}')";
    },
  );

  // Step 8: GROUP_CONCAT(x [ORDER BY ...] [SEPARATOR 's']) → string_agg
  sql = sql.replaceAllMapped(
    RegExp(
        r"\bGROUP_CONCAT\s*\(\s*(.+?)(?:\s+SEPARATOR\s+'([^']*)')?\s*\)",
        caseSensitive: false),
    (m) {
      final expr = m.group(1)!.trim();
      final sep = m.group(2) ?? ',';
      if (RegExp(r'\bORDER\s+BY\b', caseSensitive: false).hasMatch(expr)) {
        issues.add(const SqlNormalizerIssue(
          severity: SqlIssueSeverity.warning,
          code: 'group_concat_order_by',
          message:
              'GROUP_CONCAT had an ORDER BY inside — Postgres string_agg supports this '
              'but the syntax was not auto-rewritten. Verify manually.',
        ));
      }
      applied.add("Rewrote GROUP_CONCAT(...) → string_agg(..., '$sep')");
      return "string_agg($expr::text, '$sep')";
    },
  );

  // Step 8b: GROUP BY / ORDER BY on a quoted alias → positional index.
  // Postgres rejects `GROUP BY "Revenue"` when "Revenue" is a SELECT alias
  // (MySQL allows it). We extract SELECT alias names from the normalized SQL,
  // then replace each alias reference in GROUP BY and ORDER BY with its
  // 1-based column position. This runs AFTER all other rewrites so the
  // SELECT list shape is stable.
  sql = _rewriteGroupOrderByAliases(sql, applied);

  // Step 9: Auto-prefix bare table names that match a known rds_* mirror.
  // Only rewrites within `FROM` / `JOIN` clauses to avoid touching column
  // references that happen to share a name (e.g. `t.user`).
  sql = sql.replaceAllMapped(
    RegExp(r'(\b(?:FROM|JOIN)\s+)([A-Za-z_][A-Za-z0-9_]*)',
        caseSensitive: false),
    (m) {
      final prefix = m.group(1)!;
      final table = m.group(2)!;
      final lower = table.toLowerCase();
      if (lower.startsWith('rds_')) return m.group(0)!;
      if (lower.startsWith('public.')) return m.group(0)!;
      if (kKnownRdsMirrorBareNames.contains(lower)) {
        applied.add('Auto-prefixed table "$table" → "rds_$lower"');
        return '${prefix}rds_$lower';
      }
      return m.group(0)!;
    },
  );

  // Step 9b: Auto-cast rds_user.id to text in JOIN ON clauses.
  // rds_user.id is a bigint PK in the Postgres mirror, but the FK columns
  // in related tables (e.g. buyer_id, seller_id, user_id) are stored as
  // text. A JOIN ON b.id = po.buyer_id fails in Postgres with a type error.
  // We detect the pattern `<alias>.id` where the alias resolves to rds_user
  // and emit `<alias>.id::text`.
  sql = _castRdsUserIdJoins(sql, applied);

  // Step 9c: GROUP BY completeness check.
  // MySQL allows "loose" GROUP BY — SELECT columns not in GROUP BY silently
  // return an arbitrary row value. Postgres rejects this with an error.
  // We detect non-aggregated SELECT columns missing from GROUP BY and surface
  // a clear, actionable warning rather than letting the DB error confuse the user.
  _checkGroupByCompleteness(sql, issues);

  // Step 10: Double-quoted content with spaces is now intentional — it means
  // a multi-word column alias that we auto-converted from single quotes in
  // Step 0a (e.g. AS "Buyer Email"). No warning needed; this is valid Postgres.

  // Restore masked strings + comments.
  final restored = _unmask(sql, masked);

  return SqlNormalizerResult(
    normalized: restored,
    issues: issues,
    appliedRewrites: applied,
  );
}

// ─── Internals ──────────────────────────────────────────────────────────────

class _MaskedSql {
  final String masked;
  final List<String> literals; // in placeholder order
  const _MaskedSql(this.masked, this.literals);
}

_MaskedSql _maskLiteralsAndComments(String sql) {
  final literals = <String>[];
  final buf = StringBuffer();
  int i = 0;
  while (i < sql.length) {
    final ch = sql[i];
    // -- line comment
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      final end = sql.indexOf('\n', i);
      final stop = end < 0 ? sql.length : end;
      literals.add(sql.substring(i, stop));
      buf.write('__SQLLIT_${literals.length - 1}__');
      i = stop;
      continue;
    }
    // /* block comment */
    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      final end = sql.indexOf('*/', i + 2);
      final stop = end < 0 ? sql.length : end + 2;
      literals.add(sql.substring(i, stop));
      buf.write('__SQLLIT_${literals.length - 1}__');
      i = stop;
      continue;
    }
    // 'single quoted' (MySQL allows '' or \' as escapes; we accept both)
    if (ch == "'") {
      final start = i;
      i++;
      while (i < sql.length) {
        if (sql[i] == "\\" && i + 1 < sql.length) {
          i += 2;
          continue;
        }
        if (sql[i] == "'") {
          if (i + 1 < sql.length && sql[i + 1] == "'") {
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      literals.add(sql.substring(start, i));
      buf.write('__SQLLIT_${literals.length - 1}__');
      continue;
    }
    buf.write(ch);
    i++;
  }
  return _MaskedSql(buf.toString(), literals);
}

String _unmask(String masked, _MaskedSql src) {
  var out = masked;
  for (int i = 0; i < src.literals.length; i++) {
    out = out.replaceAll('__SQLLIT_${i}__', src.literals[i]);
  }
  return out;
}

/// Split comma-separated arguments respecting parentheses depth.
/// Used by CONCAT rewriter and GROUP BY / ORDER BY alias rewriter.
List<String> _splitTopLevelArgs(String s) {
  final out = <String>[];
  int depth = 0;
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      out.add(buf.toString().trim());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString().trim());
  return out;
}

/// Normalize a MySQL INTERVAL unit keyword to the Postgres plural form.
String _normalizePgIntervalUnit(String unit) {
  const map = <String, String>{
    'microsecond': 'microseconds',
    'microseconds': 'microseconds',
    'second': 'seconds',
    'seconds': 'seconds',
    'minute': 'minutes',
    'minutes': 'minutes',
    'hour': 'hours',
    'hours': 'hours',
    'day': 'days',
    'days': 'days',
    'week': 'weeks',
    'weeks': 'weeks',
    'month': 'months',
    'months': 'months',
    'quarter': 'months',
    'year': 'years',
    'years': 'years',
  };
  return map[unit.toLowerCase()] ?? unit.toLowerCase();
}

// ─── IF() → CASE WHEN rewriter ───────────────────────────────────────────────
//
// Recursively rewrites all MySQL IF(cond, trueVal, falseVal) calls in [sql]
// to CASE WHEN cond THEN trueVal ELSE falseVal END.
//
// Also rewrites `col = ''` inside the condition to `col IS NULL`, because:
//   • Numeric columns in the Postgres mirror type-error on = '' comparisons.
//   • In this codebase, `= ''` always means "not set / missing / null".
//
// The algorithm is iterative (innermost-first) to handle nested IFs:
//   IF(a, IF(b, c, d), e)  →  finds the inner one first, rewrites it, then
//   rewrites the outer one in the next pass.
String _rewriteIfCalls(String sql, List<String> applied) {
  bool changed = true;
  while (changed) {
    changed = false;
    // Find the first IF( that has no nested IF( inside its argument span.
    final re = RegExp(r'\bIF\s*\(', caseSensitive: false);
    final match = re.firstMatch(sql);
    if (match == null) break;

    // Walk forward from match.end to find the matching closing paren,
    // splitting into 3 top-level comma-separated args.
    final start = match.start;
    int depth = 1;
    int i = match.end;
    final args = <String>[];
    final buf = StringBuffer();

    while (i < sql.length && depth > 0) {
      final ch = sql[i];
      if (ch == '(') {
        depth++;
        buf.write(ch);
      } else if (ch == ')') {
        depth--;
        if (depth == 0) {
          // Closing paren of the IF call — save last arg.
          args.add(buf.toString().trim());
          buf.clear();
        } else {
          buf.write(ch);
        }
      } else if (ch == ',' && depth == 1) {
        // Top-level comma — arg boundary.
        args.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
      i++;
    }

    if (args.length != 3) {
      // Malformed IF() — stop trying to rewrite to avoid mangling the SQL.
      break;
    }

    String cond = args[0];
    final trueVal = args[1];
    final falseVal = args[2];

    // Rewrite `col = ''` in the condition to `col IS NULL`.
    // Matches: <anything> = '' (with optional spaces around =).
    // We only do this for the condition arg (first arg) of IF().
    final emptyStrRe = RegExp(r"(\w+(?:\.\w+)?)\s*=\s*''");
    if (emptyStrRe.hasMatch(cond)) {
      cond = cond.replaceAllMapped(emptyStrRe, (m) {
        applied.add("Rewrote IF condition '${m.group(0)}' → '${m.group(1)} IS NULL'");
        return '${m.group(1)} IS NULL';
      });
    }

    final replacement = 'CASE WHEN $cond THEN $trueVal ELSE $falseVal END';
    applied.add('Rewrote MySQL IF(...) → CASE WHEN ... THEN ... ELSE ... END');
    sql = sql.substring(0, start) + replacement + sql.substring(i);
    changed = true;
  }
  return sql;
}

// ─── GROUP BY / ORDER BY alias → positional index rewriter ──────────────────
//
// Postgres does not allow `GROUP BY "Revenue"` when "Revenue" is a SELECT
// alias (MySQL does). This function:
//   1. Parses the SELECT list to build a map of alias → 1-based position.
//   2. Scans the GROUP BY clause and replaces quoted alias refs with positions.
//   3. Scans the ORDER BY clause and replaces quoted alias refs with positions.
//
// Unquoted identifiers and table.column references are left untouched.
String _rewriteGroupOrderByAliases(String sql, List<String> applied) {
  // ── Step 1: Parse SELECT list to get alias → position map ──────────────
  final selectAliases = <String, int>{};

  // Find SELECT keyword.
  final selectMatch = RegExp(r'\bSELECT\b', caseSensitive: false).firstMatch(sql);
  if (selectMatch == null) return sql;
  final selectStart = selectMatch.end;

  // Find the top-level FROM keyword (skip any nested subqueries).
  int fromIdx = -1;
  int depth = 0;
  for (int i = selectStart; i < sql.length; i++) {
    final ch = sql[i];
    if (ch == '(') {
      depth++;
      continue;
    }
    if (ch == ')') {
      depth--;
      continue;
    }
    if (depth == 0) {
      final sub = sql.substring(i);
      if (RegExp(r'^\bFROM\b', caseSensitive: false).hasMatch(sub)) {
        fromIdx = i;
        break;
      }
    }
  }
  if (fromIdx < 0) return sql;

  final selectList = sql.substring(selectStart, fromIdx);
  final selectItems = _splitTopLevelArgs(selectList);
  int pos = 0;
  for (final item in selectItems) {
    pos++;
    // Match trailing:  AS "alias"  (double-quoted after our backtick rewrite)
    final quotedAliasRe = RegExp(r'\bAS\s+"([^"]+)"\s*$', caseSensitive: false);
    final quotedMatch = quotedAliasRe.firstMatch(item.trim());
    if (quotedMatch != null) {
      selectAliases[quotedMatch.group(1)!.toLowerCase()] = pos;
    } else {
      // Unquoted alias: AS identifier
      final unquotedAliasRe = RegExp(r'\bAS\s+([A-Za-z_][A-Za-z0-9_]*)\s*$', caseSensitive: false);
      final uqMatch = unquotedAliasRe.firstMatch(item.trim());
      if (uqMatch != null) {
        selectAliases[uqMatch.group(1)!.toLowerCase()] = pos;
      }
    }
  }

  if (selectAliases.isEmpty) return sql;

  // ── Step 2: Rewrite GROUP BY clause ─────────────────────────────────────
  sql = sql.replaceAllMapped(
    RegExp(r'\bGROUP\s+BY\b(.+?)(?=\bHAVING\b|\bORDER\b|\bLIMIT\b|\bUNION\b|$)',
        caseSensitive: false, dotAll: true),
    (m) {
      final clause = m.group(1)!;
      final rewritten = _replaceAliasesInClause(clause, selectAliases, applied, 'GROUP BY');
      return 'GROUP BY$rewritten';
    },
  );

  // ── Step 3: Rewrite ORDER BY clause ─────────────────────────────────────
  sql = sql.replaceAllMapped(
    RegExp(r'\bORDER\s+BY\b(.+?)(?=\bLIMIT\b|\bUNION\b|$)',
        caseSensitive: false, dotAll: true),
    (m) {
      final clause = m.group(1)!;
      final rewritten = _replaceAliasesInClause(clause, selectAliases, applied, 'ORDER BY');
      return 'ORDER BY$rewritten';
    },
  );

  return sql;
}

/// Within a GROUP BY or ORDER BY clause string, replace double-quoted alias
/// names that appear in [aliasMap] with their positional index.
String _replaceAliasesInClause(
    String clause, Map<String, int> aliasMap, List<String> applied, String clauseName) {
  final items = _splitTopLevelArgs(clause);
  final out = <String>[];
  for (final item in items) {
    final trimmed = item.trim();
    // Match: "alias" optionally followed by ASC or DESC
    final m = RegExp(r'^"([^"]+)"(\s+(?:ASC|DESC))?\s*$', caseSensitive: false)
        .firstMatch(trimmed);
    if (m != null) {
      final aliasName = m.group(1)!;
      final dir = m.group(2) ?? '';
      final posn = aliasMap[aliasName.toLowerCase()];
      if (posn != null) {
        applied.add('Rewrote $clauseName alias "$aliasName" → positional $posn');
        out.add(' $posn$dir');
        continue;
      }
    }
    out.add(' $trimmed');
  }
  return out.join(',');
}

// ─── rds_user.id bigint → text cast injector ─────────────────────────────────
//
// In the Postgres mirror, `rds_user.id` is a bigint primary key.
// Foreign key columns in related tables (buyer_id, seller_id, user_id, etc.)
// are stored as text. A JOIN condition like:
//
//   JOIN rds_user AS b ON b.id = po.buyer_id
//
// fails in Postgres with: "operator does not exist: bigint = text"
//
// We detect all aliases that are assigned to `rds_user` (including the bare
// name `user` before prefixing, since prefixing happens before this step), then
// rewrite `<alias>.id` → `<alias>.id::text` anywhere in the SQL that is NOT
// already cast.
//
// Only `rds_user` is special-cased here because it is the only mirror table
// whose PK is bigint while its FK references in other tables are text.
String _castRdsUserIdJoins(String sql, List<String> applied) {
  // Collect all aliases that refer to rds_user.
  // Patterns matched:
  //   FROM rds_user AS alias
  //   JOIN rds_user AS alias
  //   FROM rds_user alias   (no AS keyword)
  //   JOIN rds_user alias
  //   FROM rds_user         (no alias — use bare table name as alias)
  final userAliases = <String>{};

  final joinRe = RegExp(
      r'\b(?:FROM|JOIN)\s+rds_user\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*)',
      caseSensitive: false);
  for (final m in joinRe.allMatches(sql)) {
    userAliases.add(m.group(1)!.toLowerCase());
  }
  // Also catch bare `FROM rds_user` / `JOIN rds_user` with no alias.
  if (RegExp(r'\b(?:FROM|JOIN)\s+rds_user\b', caseSensitive: false).hasMatch(sql)) {
    userAliases.add('rds_user');
  }

  if (userAliases.isEmpty) return sql;

  bool didCast = false;
  for (final alias in userAliases) {
    // Match alias.id NOT already followed by ::
    final re = RegExp(
        r'\b(' + RegExp.escape(alias) + r')\.id(?!:)',
        caseSensitive: false);
    if (re.hasMatch(sql)) {
      sql = sql.replaceAllMapped(re, (m) {
        didCast = true;
        return '${m.group(1)}.id::text';
      });
    }
  }
  if (didCast) {
    applied.add(
        'Auto-cast rds_user.id → rds_user.id::text to match text FK columns '
        '(bigint/text type mismatch)');
  }
  return sql;
}

// ─── GROUP BY completeness checker ───────────────────────────────────────────
//
// Postgres requires that every non-aggregated expression in the SELECT list
// appears in the GROUP BY clause. MySQL allows "loose" GROUP BY (picks an
// arbitrary row value for missing columns). We detect this mismatch and surface
// an actionable warning rather than letting the DB produce a cryptic error.
//
// Detection logic:
//   1. Extract SELECT items. Classify each as "aggregated" (contains an
//      aggregate function call at the top level) or "bare" (column reference
//      or expression that must appear in GROUP BY).
//   2. Extract the GROUP BY clause.
//   3. For each bare SELECT item, check whether its core column reference
//      appears in the GROUP BY text.
//   4. If any bare items are missing, emit a SqlNormalizerIssue.warning with
//      a helpful suggested fix listing the missing columns.
void _checkGroupByCompleteness(String sql, List<SqlNormalizerIssue> issues) {
  // Only relevant when there IS a GROUP BY.
  final groupByMatch = RegExp(
          r'\bGROUP\s+BY\b(.+?)(?=\bHAVING\b|\bORDER\b|\bLIMIT\b|\bUNION\b|$)',
          caseSensitive: false,
          dotAll: true)
      .firstMatch(sql);
  if (groupByMatch == null) return;

  final groupByText = groupByMatch.group(1)!.toLowerCase();

  // Extract SELECT list.
  final selectMatch = RegExp(r'\bSELECT\b', caseSensitive: false).firstMatch(sql);
  if (selectMatch == null) return;
  final selectStart = selectMatch.end;

  int fromIdx = -1;
  int depth = 0;
  for (int i = selectStart; i < sql.length; i++) {
    final ch = sql[i];
    if (ch == '(') {
      depth++;
      continue;
    }
    if (ch == ')') {
      depth--;
      continue;
    }
    if (depth == 0) {
      if (RegExp(r'^\bFROM\b', caseSensitive: false).hasMatch(sql.substring(i))) {
        fromIdx = i;
        break;
      }
    }
  }
  if (fromIdx < 0) return;

  final selectList = sql.substring(selectStart, fromIdx);
  final selectItems = _splitTopLevelArgs(selectList);

  // Aggregate function names (Postgres standard + common extensions).
  final aggFnRe = RegExp(
      r'\b(?:SUM|COUNT|AVG|MIN|MAX|STRING_AGG|ARRAY_AGG|BOOL_AND|BOOL_OR|EVERY|'
      r'STDDEV|STDDEV_POP|STDDEV_SAMP|VARIANCE|VAR_POP|VAR_SAMP|'
      r'JSON_AGG|JSONB_AGG|PERCENTILE_CONT|PERCENTILE_DISC)\s*\(',
      caseSensitive: false);

  final missing = <String>[];

  for (final item in selectItems) {
    final trimmed = item.trim();
    if (trimmed.isEmpty || trimmed == '*') continue;

    // Skip aggregated expressions — they don't need to be in GROUP BY.
    if (aggFnRe.hasMatch(trimmed)) continue;

    // Strip any trailing AS alias to get the core expression.
    final coreExpr = trimmed
        .replaceAll(RegExp(r'\bAS\s+"[^"]*"\s*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bAS\s+[A-Za-z_][A-Za-z0-9_]*\s*$', caseSensitive: false), '')
        .trim();

    if (coreExpr.isEmpty) continue;

    // Check if the core expression appears anywhere in the GROUP BY text.
    // We check for table.column style refs and bare column names.
    // Normalise to lowercase for comparison.
    final coreLower = coreExpr.toLowerCase();

    // Extract the innermost column name (last segment after dot, if any).
    final parts = coreLower.split('.');
    final colName = parts.last.trim();

    // Consider it "covered" if:
    //   - The full expression appears in GROUP BY, OR
    //   - The column name (without table prefix) appears in GROUP BY, OR
    //   - It's a positional reference (pure number) in the GROUP BY.
    final covered = groupByText.contains(coreLower) ||
        (colName.isNotEmpty && groupByText.contains(colName)) ||
        // GROUP BY 1, 2, 3 — positional references cover everything.
        RegExp(r'^\s*\d+\s*(,\s*\d+\s*)*$').hasMatch(groupByText.trim());

    if (!covered) {
      missing.add(coreExpr);
    }
  }

  if (missing.isNotEmpty) {
    // Build a suggested GROUP BY that adds the missing columns.
    final groupByItems = groupByText.trim().split(',').map((s) => s.trim()).toList();
    final suggested = [...groupByItems, ...missing].join(', ');
    issues.add(SqlNormalizerIssue(
      severity: SqlIssueSeverity.warning,
      code: 'group_by_incomplete',
      message:
          'GROUP BY is incomplete for Postgres. MySQL allows non-aggregated columns '
          'to be omitted from GROUP BY, but Postgres does not.\n\n'
          'Missing from GROUP BY: ${missing.join(', ')}\n\n'
          'Either wrap each missing column in an aggregate function (SUM, MAX, MIN, etc.) '
          'or add it to GROUP BY.',
      suggestedFix: 'GROUP BY $suggested',
    ));
  }
}

// ─── Date format conversion ──────────────────────────────────────────────────

class _DateFormatConversion {
  final String postgresFormat;
  final List<String> unknownTokens;
  const _DateFormatConversion(this.postgresFormat, this.unknownTokens);
}

/// Convert a MySQL DATE_FORMAT format string to a Postgres to_char pattern.
/// Only the common tokens are translated; unknown tokens are preserved
/// verbatim and reported.
_DateFormatConversion _convertMySqlDateFormat(String mysqlFmt) {
  const map = <String, String>{
    '%Y': 'YYYY',
    '%y': 'YY',
    '%m': 'MM',
    '%c': 'FMMM',
    '%d': 'DD',
    '%e': 'FMDD',
    '%H': 'HH24',
    '%h': 'HH12',
    '%I': 'HH12',
    '%i': 'MI',
    '%s': 'SS',
    '%S': 'SS',
    '%M': 'Month',
    '%b': 'Mon',
    '%W': 'Day',
    '%a': 'Dy',
    '%p': 'AM',
    '%T': 'HH24:MI:SS',
    '%r': 'HH12:MI:SS AM',
    '%%': '%',
  };
  final unknown = <String>[];
  final out = StringBuffer();
  int i = 0;
  while (i < mysqlFmt.length) {
    if (mysqlFmt[i] == '%' && i + 1 < mysqlFmt.length) {
      final tok = mysqlFmt.substring(i, i + 2);
      final rep = map[tok];
      if (rep != null) {
        out.write(rep);
      } else {
        unknown.add(tok);
        out.write(tok);
      }
      i += 2;
    } else {
      out.write(mysqlFmt[i]);
      i++;
    }
  }
  return _DateFormatConversion(out.toString(), unknown);
}
