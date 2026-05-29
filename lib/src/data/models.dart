/// Lightweight Optics data models (Dart side).
///
/// These map 1:1 to the Postgres schema in /program/supabase/migrations/.
library;

class Tenant {
  final String id;
  final String name;
  final String slug;
  final String? logoUrl;

  Tenant({
    required this.id,
    required this.name,
    required this.slug,
    this.logoUrl,
  });

  factory Tenant.fromMap(Map<String, dynamic> m) => Tenant(
        id: m['id'] as String,
        name: m['name'] as String,
        slug: m['slug'] as String,
        logoUrl: m['logo_url'] as String?,
      );
}

class Dashboard {
  final String id;
  final String tenantId;
  final String name;
  final String? description;
  final Map<String, dynamic> settings;
  final DateTime updatedAt;

  Dashboard({
    required this.id,
    required this.tenantId,
    required this.name,
    this.description,
    required this.settings,
    required this.updatedAt,
  });

  factory Dashboard.fromMap(Map<String, dynamic> m) => Dashboard(
        id: m['id'] as String,
        tenantId: m['tenant_id'] as String,
        name: m['name'] as String? ?? 'Untitled',
        description: m['description'] as String?,
        // The Postgres column is `global_settings`; older code expected
        // `settings`. Accept either so we don't lose values written before
        // this fix.
        settings: (m['global_settings'] as Map?)?.cast<String, dynamic>() ??
            (m['settings'] as Map?)?.cast<String, dynamic>() ??
            {},
        updatedAt: DateTime.parse(m['updated_at'] as String),
      );
}

enum WidgetKind {
  kpi,
  line,
  barVertical,
  barHorizontal,
  barStacked,
  barGrouped,
  combo,
  pie,
  donut,
  gauge,
  table,
  map,
  markdown;

  static WidgetKind fromString(String s) {
    // Accept both enum names (e.g. "barHorizontal") and the snake_case /
    // shorthand variants used in the canned-library payloads
    // ("bar_horizontal", "bar", "horizontal_bar", etc.).
    final norm = s.trim().toLowerCase().replaceAll('-', '_');
    const aliases = <String, WidgetKind>{
      'kpi': WidgetKind.kpi,
      'tile': WidgetKind.kpi,
      'line': WidgetKind.line,
      'trend': WidgetKind.line,
      'area': WidgetKind.line,
      'bar': WidgetKind.barVertical,
      'bar_vertical': WidgetKind.barVertical,
      'barvertical': WidgetKind.barVertical,
      'column': WidgetKind.barVertical,
      'bar_horizontal': WidgetKind.barHorizontal,
      'barhorizontal': WidgetKind.barHorizontal,
      'horizontal_bar': WidgetKind.barHorizontal,
      'bar_stacked': WidgetKind.barStacked,
      'barstacked': WidgetKind.barStacked,
      'stacked_bar': WidgetKind.barStacked,
      'bar_grouped': WidgetKind.barGrouped,
      'bargrouped': WidgetKind.barGrouped,
      'grouped_bar': WidgetKind.barGrouped,
      'combo': WidgetKind.combo,
      'dual_axis': WidgetKind.combo,
      'pie': WidgetKind.pie,
      'donut': WidgetKind.donut,
      'doughnut': WidgetKind.donut,
      'gauge': WidgetKind.gauge,
      'table': WidgetKind.table,
      'grid': WidgetKind.table,
      'list': WidgetKind.table,
      'map': WidgetKind.map,
      'markdown': WidgetKind.markdown,
      'text': WidgetKind.markdown,
      'note': WidgetKind.markdown,
    };
    final aliased = aliases[norm];
    if (aliased != null) return aliased;
    return WidgetKind.values.firstWhere(
      (e) => e.name.toLowerCase() == norm,
      orElse: () => WidgetKind.kpi,
    );
  }
}

class WidgetModel {
  final String id;
  final String tenantId;
  final String dashboardId;
  final String title;
  final WidgetKind kind;
  // Grid position (~48-col micro-grid with sub-cell snap) stored in `layout`.
  final double x;
  final double y;
  final double w;
  final double h;
  final Map<String, dynamic> binding; // metric/dimension refs
  final Map<String, dynamic> settings; // per-widget settings page

  WidgetModel({
    required this.id,
    required this.tenantId,
    required this.dashboardId,
    required this.title,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.binding,
    required this.settings,
  });

  WidgetModel copyWith({
    String? title,
    WidgetKind? kind,
    double? x,
    double? y,
    double? w,
    double? h,
    Map<String, dynamic>? binding,
    Map<String, dynamic>? settings,
  }) {
    return WidgetModel(
      id: id,
      tenantId: tenantId,
      dashboardId: dashboardId,
      title: title ?? this.title,
      kind: kind ?? this.kind,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
      binding: binding ?? this.binding,
      settings: settings ?? this.settings,
    );
  }

  factory WidgetModel.fromMap(Map<String, dynamic> m) {
    final layout = (m['layout'] as Map?)?.cast<String, dynamic>() ?? {};
    return WidgetModel(
      id: m['id'] as String,
      tenantId: m['tenant_id'] as String,
      dashboardId: m['dashboard_id'] as String,
      title: m['title'] as String? ?? 'Untitled',
      kind: WidgetKind.fromString(m['type'] as String? ?? 'kpi'),
      x: (layout['x'] as num?)?.toDouble() ?? 0,
      y: (layout['y'] as num?)?.toDouble() ?? 0,
      w: (layout['w'] as num?)?.toDouble() ?? 12,
      h: (layout['h'] as num?)?.toDouble() ?? 6,
      binding: (m['data_binding'] as Map?)?.cast<String, dynamic>() ?? {},
      settings: (m['settings'] as Map?)?.cast<String, dynamic>() ?? {},
    );
  }

  Map<String, dynamic> toUpdateMap() => {
        'title': title,
        'type': kind.name,
        'layout': {'x': x, 'y': y, 'w': w, 'h': h},
        'data_binding': binding,
        'settings': settings,
      };
}

class DataSource {
  final String id;
  final String tenantId;
  final String name;
  final String kind; // 'mysql' | 'rest' | ...
  final String host;
  final int port;
  final String database;
  final String username;
  // REST-specific
  final String baseUrl;
  final String provider;
  final String? lastTestStatus;
  final DateTime? lastTestedAt;
  final bool hasCredentials;

  DataSource({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.kind,
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    this.baseUrl = '',
    this.provider = '',
    this.lastTestStatus,
    this.lastTestedAt,
    required this.hasCredentials,
  });

  factory DataSource.fromMap(Map<String, dynamic> m) {
    final cfg = (m['config'] as Map?)?.cast<String, dynamic>() ?? {};
    return DataSource(
      id: m['id'] as String,
      tenantId: m['tenant_id'] as String,
      name: m['name'] as String,
      kind: m['kind'] as String,
      host: cfg['host'] as String? ?? '',
      port: (cfg['port'] as num?)?.toInt() ?? 3306,
      database: cfg['database'] as String? ?? '',
      username: cfg['username'] as String? ?? '',
      baseUrl: cfg['base_url'] as String? ?? '',
      provider: cfg['provider'] as String? ?? '',
      lastTestStatus: m['last_test_status'] as String?,
      lastTestedAt: m['last_tested_at'] != null
          ? DateTime.tryParse(m['last_tested_at'] as String)
          : null,
      hasCredentials: m['vault_secret_id'] != null,
    );
  }

  /// Human-readable connection summary line shown under the name.
  String get summary {
    if (kind == 'rest') {
      final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
      return 'rest · $host';
    }
    return '$kind · $username@$host:$port/$database';
  }
}

class LibraryItem {
  final String id;
  final String? tenantId; // null = system library (scope='system')
  final String scope; // 'system' | 'org' | 'personal'
  final String kind; // 'metric' | 'widget' | 'dashboard' | 'report'
  final String name;
  final String category;
  final String? description;
  final List<String> tags;
  final Map<String, dynamic> payload;

  LibraryItem({
    required this.id,
    this.tenantId,
    required this.scope,
    required this.kind,
    required this.name,
    required this.category,
    this.description,
    required this.tags,
    required this.payload,
  });

  factory LibraryItem.fromMap(Map<String, dynamic> m) => LibraryItem(
        id: m['id'] as String,
        tenantId: m['tenant_id'] as String?,
        scope: m['scope'] as String? ?? 'system',
        kind: m['kind'] as String? ?? 'metric',
        name: m['name'] as String,
        category: m['category'] as String? ?? '',
        description: m['description'] as String?,
        tags: (m['tags'] as List?)?.cast<String>() ?? const [],
        payload: (m['payload'] as Map?)?.cast<String, dynamic>() ?? {},
      );
}

enum ReportStatus { live, pending, archived;
  static ReportStatus fromString(String? s) {
    switch ((s ?? 'live').toLowerCase()) {
      case 'pending':  return ReportStatus.pending;
      case 'archived': return ReportStatus.archived;
      default:         return ReportStatus.live;
    }
  }
  String get wire => name;
  String get label {
    switch (this) {
      case ReportStatus.live:     return 'Live';
      case ReportStatus.pending:  return 'Pending';
      case ReportStatus.archived: return 'Archived';
    }
  }
}

class Report {
  final String id;
  final String tenantId;
  final String name;
  final bool isCanned;
  final String category;
  final String? description;
  final Map<String, dynamic> layout;
  final ReportStatus status;
  final DateTime? createdAt;
  final DateTime? archivedAt;
  final String? createdBy;            // user id
  final String? createdByName;        // display name (joined)
  final bool sharedWithTenant;
  /// 1 = legacy drag/auto-join builder; 2 = explicit-join wizard (ADR-0013).
  final int queryVersion;
  Report({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.isCanned,
    this.category = '',
    this.description,
    required this.layout,
    this.status = ReportStatus.live,
    this.createdAt,
    this.archivedAt,
    this.createdBy,
    this.createdByName,
    this.sharedWithTenant = false,
    this.queryVersion = 1,
  });
  factory Report.fromMap(Map<String, dynamic> m) {
    final profile = m['user_profiles'];
    String? createdByName;
    if (profile is Map) {
      createdByName = profile['display_name'] as String?;
    }
    return Report(
      id: m['id'] as String,
      tenantId: m['tenant_id'] as String,
      name: m['name'] as String,
      isCanned: m['is_canned'] as bool? ?? false,
      category: m['category'] as String? ?? '',
      description: m['description'] as String?,
      layout: (m['layout'] as Map?)?.cast<String, dynamic>() ?? {},
      status: ReportStatus.fromString(m['status'] as String?),
      createdAt: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'] as String)
          : null,
      archivedAt: m['archived_at'] != null
          ? DateTime.tryParse(m['archived_at'] as String)
          : null,
      createdBy: m['created_by'] as String?,
      createdByName: createdByName,
      sharedWithTenant: m['shared_with_tenant'] as bool? ?? false,
      queryVersion: (m['query_version'] as num?)?.toInt() ?? 1,
    );
  }

  Report copyWith({
    String? id,
    String? tenantId,
    String? name,
    bool? isCanned,
    String? category,
    String? description,
    Map<String, dynamic>? layout,
    ReportStatus? status,
    DateTime? createdAt,
    DateTime? archivedAt,
    String? createdBy,
    String? createdByName,
    bool? sharedWithTenant,
    int? queryVersion,
  }) {
    return Report(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      name: name ?? this.name,
      isCanned: isCanned ?? this.isCanned,
      category: category ?? this.category,
      description: description ?? this.description,
      layout: layout ?? this.layout,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      archivedAt: archivedAt ?? this.archivedAt,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      sharedWithTenant: sharedWithTenant ?? this.sharedWithTenant,
      queryVersion: queryVersion ?? this.queryVersion,
    );
  }
}
