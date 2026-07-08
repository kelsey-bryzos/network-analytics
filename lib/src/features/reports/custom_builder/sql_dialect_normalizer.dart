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
///        DATE_FORMAT(x, f)   → to_char(x, ...)        (fmt tokens converted)
///        CONCAT(a, b, ...)   → (a || b || ...)        (safe when no NULLs)
///        LENGTH(x)           → char_length(x)         (byte→char behavior)
///        GROUP_CONCAT(...)   → string_agg(..., ',')   (approximate)
///   5. `LIMIT n, m`          → `LIMIT m OFFSET n`
///   6. `RAND()`              → `random()`
///   7. Bare table names that match a known `rds_*` mirror → auto-prefixed
///      (e.g. `FROM user` → `FROM rds_user`)
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

  // Step 0: mask strings + comments so we don't rewrite inside them.
  final _MaskedSql masked = _maskLiteralsAndComments(input);
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
      applied.add('Rewrote MySQL function → Postgres: ${pattern.replaceAll(r'\b', '').replaceAll(r'\s*\(\s*\)', '()')} → $replacement');
    }
  });

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

  // Step 7: DATE_FORMAT(x, '%Y-%m-%d') → to_char(x, 'YYYY-MM-DD')
  // We convert a small set of the most common format tokens; unknown tokens
  // are passed through with a warning so the user knows to check.
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
              'DATE_FORMAT contained unrecognized token(s): ${converted.unknownTokens.join(', ')}. Verify the Postgres output manually.',
        ));
      }
      applied.add('Rewrote DATE_FORMAT($expr, ...) → to_char(...)');
      return "to_char($expr, '${converted.postgresFormat}')";
    },
  );

  // Step 8: GROUP_CONCAT(x [ORDER BY ...] [SEPARATOR 's']) → string_agg
  // Approximate: honor SEPARATOR if literal, drop ORDER BY (rare in raw
  // reports) with a warning if present.
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
              'GROUP_CONCAT had an ORDER BY inside — Postgres string_agg supports this but the syntax was not auto-rewritten. Verify manually.',
        ));
      }
      applied.add('Rewrote GROUP_CONCAT(...) → string_agg(..., \'$sep\')');
      return "string_agg($expr::text, '$sep')";
    },
  );

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

  // Step 10: Double-quoted string literals — MySQL allows "foo" as a string,
  // but in Postgres "foo" is an identifier. If any double-quoted literal was
  // captured during masking as a *string* (not an identifier), we've already
  // safely masked it and will unmask below. But if a raw `"...` remains in
  // the visible sql now that clearly looks like a string (has spaces, is on
  // the RHS of `=`, etc.) we warn — safer than a wrong auto-rewrite.
  //
  // In practice: the mask step captured only single-quoted literals, so any
  // double-quoted content is treated as an identifier and left alone. We
  // surface a warning if the SQL contains double-quoted content that looks
  // suspicious (contains a space, common in string values).
  final suspiciousDq = RegExp(r'"[^"]* [^"]*"').firstMatch(sql);
  if (suspiciousDq != null) {
    issues.add(SqlNormalizerIssue(
      severity: SqlIssueSeverity.warning,
      code: 'double_quoted_string_literal',
      message:
          'Found "${suspiciousDq.group(0)}" — in Postgres double quotes mean an identifier, not a string. If this was meant to be a string, use single quotes.',
      suggestedFix: suspiciousDq
          .group(0)!
          .replaceAll('"', "'"),
    ));
  }

  // Restore masked strings + comments.
  final restored = _unmask(sql, masked);

  return SqlNormalizerResult(
    normalized: restored,
    issues: issues,
    appliedRewrites: applied,
  );
}

// ─── Internals ──────────────────────────────────────────────────────────

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
/// Used by CONCAT rewriter.
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
