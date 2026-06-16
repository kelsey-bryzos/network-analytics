import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (_) => Supabase.instance.client,
);

final activeTenantProvider = StateProvider<String?>((ref) {
  final user = ref.watch(supabaseProvider).auth.currentUser;
  return user?.appMetadata['active_tenant_id'] as String?;
});

class SupabaseRepo {
  final SupabaseClient client;
  SupabaseRepo(this.client);

  /// Headers attached to every Edge Function call so the server can resolve
  /// the active tenant even when the Supabase-issued JWT doesn't carry it.
  Map<String, String> _fnHeaders() {
    final tid = client.auth.currentUser?.appMetadata['active_tenant_id']
        as String?;
    return tid == null ? {} : {'x-optics-tenant': tid};
  }

  // ------------------ Tenants ------------------
  Future<List<Tenant>> listTenants() async {
    final rows = await client.from('tenants').select().order('name');
    return (rows as List).map((r) => Tenant.fromMap(r as Map<String, dynamic>)).toList();
  }

  Future<Tenant> getTenant(String id) async {
    final row = await client.from('tenants').select().eq('id', id).single();
    return Tenant.fromMap(row);
  }

  // ------------------ Dashboards ------------------
  Future<List<Dashboard>> listDashboards() async {
    final rows = await client
        .from('dashboards')
        .select()
        .order('updated_at', ascending: false);
    return (rows as List)
        .map((r) => Dashboard.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  Future<Dashboard> getDashboard(String id) async {
    final row =
        await client.from('dashboards').select().eq('id', id).single();
    return Dashboard.fromMap(row);
  }

  Future<Dashboard> createDashboard(String name) async {
    final row = await client
        .from('dashboards')
        .insert({'name': name, 'global_settings': {}}).select().single();
    return Dashboard.fromMap(row);
  }

  Future<void> deleteDashboard(String id) async {
    // Widgets cascade via FK; if not, clean them up explicitly first.
    await client.from('widgets').delete().eq('dashboard_id', id);
    await client.from('dashboards').delete().eq('id', id);
  }

  // ------------------ Widgets ------------------
  Future<List<WidgetModel>> listWidgets(String dashboardId) async {
    final rows = await client
        .from('widgets')
        .select()
        .eq('dashboard_id', dashboardId)
        .order('created_at');
    return (rows as List)
        .map((r) => WidgetModel.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  Future<WidgetModel> createWidget({
    required String dashboardId,
    required String title,
    required WidgetKind kind,
    double x = 0,
    double y = 0,
    double w = 12,
    double h = 6,
    Map<String, dynamic> binding = const {},
    Map<String, dynamic> settings = const {},
  }) async {
    final row = await client.from('widgets').insert({
      'dashboard_id': dashboardId,
      'title': title,
      'type': kind.dbTypeName,
      'layout': {'x': x, 'y': y, 'w': w, 'h': h},
      'data_binding': binding,
      'settings': settings,
    }).select().single();
    return WidgetModel.fromMap(row);
  }

  Future<WidgetModel> updateWidget(WidgetModel w) async {
    final row = await client
        .from('widgets')
        .update(w.toUpdateMap())
        .eq('id', w.id)
        .select()
        .single();
    return WidgetModel.fromMap(row);
  }

  Future<void> deleteWidget(String id) async {
    await client.from('widgets').delete().eq('id', id);
  }

  // ------------------ Data Sources ------------------
  Future<List<DataSource>> listDataSources() async {
    final rows =
        await client.from('data_sources').select().order('created_at');
    return (rows as List)
        .map((r) => DataSource.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  /// Create a new data source row for the active tenant. For REST kinds the
  /// optional [apiKey] is written to Supabase Vault via `data-source-set-secret`.
  /// For MySQL kinds the optional [username]/[password] are also written to Vault.
  Future<DataSource> createDataSource({
    required String tenantId,
    required String name,
    required String kind,
    required Map<String, dynamic> config,
    String? apiKey,
    String? username,
    String? password,
  }) async {
    final row = await client
        .from('data_sources')
        .insert({
          'tenant_id': tenantId,
          'name': name,
          'kind': kind,
          'config': config,
        })
        .select()
        .single();
    final ds = DataSource.fromMap(row);

    final hasRest = apiKey != null && apiKey.isNotEmpty;
    final hasMysql = username != null && password != null;
    if (hasRest || hasMysql) {
      await client.functions.invoke(
        'data-source-set-secret',
        body: hasRest
            ? {'data_source_id': ds.id, 'api_key': apiKey}
            : {'data_source_id': ds.id, 'username': username, 'password': password},
        headers: _fnHeaders(),
      );
      // Re-read so we pick up vault_secret_id (powers `hasCredentials`).
      final fresh =
          await client.from('data_sources').select().eq('id', ds.id).single();
      return DataSource.fromMap(fresh);
    }
    return ds;
  }

  Future<void> deleteDataSource(String id) async {
    await client.from('data_sources').delete().eq('id', id);
  }

  Future<DataSource> updateDataSource(String id, String name, Map<String, dynamic> config) async {
    final row = await client
        .from('data_sources')
        .update({
          'name': name,
          'config': config,
        })
        .eq('id', id)
        .select()
        .single();
    return DataSource.fromMap(row);
  }

  /// Rotate the credentials stored in Vault for an existing data source.
  Future<void> rotateDataSourceSecret(
    String id, {
    String? apiKey,
    String? username,
    String? password,
  }) async {
    final hasRest = apiKey != null && apiKey.isNotEmpty;
    final hasMysql = username != null && password != null;
    if (!hasRest && !hasMysql) return;
    await client.functions.invoke(
      'data-source-set-secret',
      body: hasRest
          ? {'data_source_id': id, 'api_key': apiKey}
          : {'data_source_id': id, 'username': username, 'password': password},
      headers: _fnHeaders(),
    );
  }

  // ------------------ Data Source Sync (manual + scheduled refresh) ------------------

  /// Read sync state (cadence + last result) for a data source.
  /// Returns null if the row doesn't exist yet.
  Future<Map<String, dynamic>?> getDataSourceSync(String dataSourceId) async {
    final row = await client
        .from('data_source_sync')
        .select()
        .eq('data_source_id', dataSourceId)
        .maybeSingle();
    return row == null ? null : (row).cast<String, dynamic>();
  }

  /// Update the auto-refresh cadence (in minutes). 0 = off.
  Future<void> setDataSourceCadence(
    String dataSourceId,
    String tenantId,
    int cadenceMinutes,
  ) async {
    await client.from('data_source_sync').upsert({
      'data_source_id': dataSourceId,
      'tenant_id': tenantId,
      'cadence_minutes': cadenceMinutes,
    });
  }

  /// Live progress for an in-flight sync, derived from etl_runs.
  /// Returns: {total, completed, running, errored, started_at, elapsed_ms,
  ///           eta_ms, current_table}.
  /// `total` is the number of tables in rds_table_map; `completed` counts
  /// etl_runs rows for this data source whose started_at is at or after the
  /// sync window's start (from data_source_sync.last_sync_at when status is
  /// 'running', else the most recent run cluster).
  Future<Map<String, dynamic>> getSyncProgress(String dataSourceId) async {
    // Total tables to sync (tenant-agnostic catalog).
    final mapRows =
        await client.from('rds_table_map').select('rds_table');
    final total = (mapRows as List).length;

    // Window start = data_source_sync.last_sync_at if running, else
    // the started_at of the most recent etl_runs row for this DS.
    final syncRow = await client
        .from('data_source_sync')
        .select('last_sync_at,last_sync_status')
        .eq('data_source_id', dataSourceId)
        .maybeSingle();
    final status = (syncRow as Map?)?['last_sync_status'] as String?;
    final windowStartIso = (syncRow)?['last_sync_at'] as String?;
    if (windowStartIso == null) {
      return {
        'total': total,
        'completed': 0,
        'running': 0,
        'errored': 0,
        'started_at': null,
        'elapsed_ms': 0,
        'eta_ms': null,
        'current_table': null,
        'status': status,
      };
    }
    final runs = await client
        .from('etl_runs')
        .select('source_table,status,started_at,finished_at')
        .eq('data_source_id', dataSourceId)
        .gte('started_at', windowStartIso)
        .order('started_at');
    final list = (runs as List).cast<Map<String, dynamic>>();
    int completed = 0, running = 0, errored = 0;
    String? currentTable;
    for (final r in list) {
      final s = r['status'] as String?;
      if (s == 'ok') {
        completed++;
      } else if (s == 'running') {
        running++;
        currentTable = r['source_table'] as String?;
      } else if (s == 'error') {
        errored++;
      }
    }
    final startedAt = DateTime.parse(windowStartIso).toUtc();
    final elapsedMs =
        DateTime.now().toUtc().difference(startedAt).inMilliseconds;
    int? etaMs;
    final done = completed + errored;
    if (done > 0 && done < total) {
      final perTable = elapsedMs / done;
      etaMs = (perTable * (total - done)).round();
    }
    return {
      'total': total,
      'completed': completed,
      'running': running,
      'errored': errored,
      'started_at': windowStartIso,
      'elapsed_ms': elapsedMs,
      'eta_ms': etaMs,
      'current_table': currentTable,
      'status': status,
    };
  }

  /// Kick off a manual refresh. Returns immediately; the edge function fires
  /// sync-rds in the background and stamps data_source_sync on completion.
  ///
  /// [tenantId] should be the tenant that owns this data source. request-sync
  /// resolves the tenant from the data source itself (no tenant header needed
  /// there), but passing it keeps the header consistent for any middleware.
  Future<Map<String, dynamic>> requestDataSourceSync(
    String dataSourceId, {
    String mode = 'incremental',
    String? tenantId,
  }) async {
    final headers = tenantId != null
        ? {'x-optics-tenant': tenantId}
        : _fnHeaders();
    final res = await client.functions.invoke(
      'request-sync',
      body: {'data_source_id': dataSourceId, 'mode': mode},
      headers: headers,
    );
    return (res.data as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Cancel a running sync. Marks in-flight etl_runs as cancelled and sets
  /// data_source_sync.last_sync_status = 'cancelled'.
  ///
  /// [tenantId] should be the tenant that owns this data source.
  Future<Map<String, dynamic>> cancelDataSourceSync(
    String dataSourceId, {
    String? tenantId,
  }) async {
    final headers = tenantId != null
        ? {'x-optics-tenant': tenantId}
        : _fnHeaders();
    final res = await client.functions.invoke(
      'request-sync',
      body: {'data_source_id': dataSourceId, 'action': 'cancel'},
      headers: headers,
    );
    return (res.data as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Probe a REST data source via bryzos-proxy. All current data sources
  /// are REST; MySQL is out of scope for v1 of the deployed app.
  ///
  /// [tenantId] must be the tenant that *owns* this data source. The proxy
  /// enforces ds.tenant_id == x-optics-tenant, so passing the wrong tenant
  /// (e.g. the currently-active tenant when viewing a different org's card)
  /// returns 403. Always pass the data source's own tenantId here.
  Future<Map<String, dynamic>> testDataSource(
    String dataSourceId, {
    String kind = 'rest',
    String? tenantId,
  }) async {
    // Use the caller-supplied tenantId (the data source's owner) in preference
    // to the currently-active tenant from the JWT. This fixes the 403 that
    // occurred when a Bryzos admin had tenant A active but was testing a data
    // source that belongs to tenant B.
    final headers = tenantId != null
        ? {'x-optics-tenant': tenantId}
        : _fnHeaders();
    final res = await client.functions.invoke(
      'bryzos-proxy',
      body: {
        'data_source_id': dataSourceId,
        'table': 'user',
        'limit': 1,
      },
      headers: headers,
    );
    return (res.data as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Resolve a Bryzos-bound widget metric into chart-ready data
  /// (server-side pagination + aggregation against the Bryzos Tables API).
  Future<Map<String, dynamic>> widgetDataBryzos({
    required String dataSourceId,
    required String metric,
    String timeRange = 'Last 30 days',
    int maxItems = 10,
  }) async {
    final res = await client.functions.invoke(
      'widget-data-bryzos',
      body: {
        'data_source_id': dataSourceId,
        'metric': metric,
        'time_range': timeRange,
        'max_items': maxItems,
      },
      headers: _fnHeaders(),
    );
    return (res.data as Map?)?.cast<String, dynamic>() ?? {};
  }

  // ------------------ Library ------------------
  Future<List<LibraryItem>> listLibrary() async {
    final rows =
        await client.from('library_items').select().order('name');
    return (rows as List)
        .map((r) => LibraryItem.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  // ------------------ Reports ------------------
  /// Returns the combined list of:
  ///  1. **Canned reports** — sourced from `library_items` where
  ///     `scope='system'` and `kind='report'`. Materialized as `Report`
  ///     instances with `isCanned=true` and `category` set from the
  ///     library item's `category` column.
  ///  2. **Custom reports** — actual rows in the tenant-scoped `reports`
  ///     table (which the current user has visibility to via RLS).
  Future<List<Report>> listReports() async {
    // 1. Fetch canned (system library) reports AND widgets
    final libRows = await client
        .from('library_items')
        .select()
        .eq('scope', 'system')
        .inFilter('kind', ['report', 'widget'])
        .order('name');

    // 1b. Pull the current user's per-canned-report archive prefs so we can
    //     surface "View Archives" entries that are user-specific.
    final userId = client.auth.currentUser?.id;
    final cannedArchivedAt = <String, DateTime>{};
    if (userId != null) {
      final prefs = await client
          .from('user_report_prefs')
          .select('target_id, archived_at')
          .eq('user_id', userId)
          .eq('is_canned', true)
          .not('archived_at', 'is', null);
      for (final p in (prefs as List)) {
        final m = p as Map<String, dynamic>;
        final tid = m['target_id'] as String?;
        final at = m['archived_at'] as String?;
        if (tid != null && at != null) {
          final parsed = DateTime.tryParse(at);
          if (parsed != null) cannedArchivedAt[tid] = parsed;
        }
      }
    }

    final canned = (libRows as List).map((r) {
      final m = r as Map<String, dynamic>;
      final kind = m['kind'] as String;
      final payload = (m['payload'] as Map?)?.cast<String, dynamic>() ?? {};
      
      Map<String, dynamic> layout;
      if (kind == 'widget') {
        layout = {
          'pages': [
            {
              'title': m['name'],
              'widgets': [
                {
                  'title': m['name'],
                  ...payload
                }
              ]
            }
          ]
        };
      } else {
        layout = (payload['layout'] as Map?)?.cast<String, dynamic>() ?? {'pages': []};
      }
      
      final libId = m['id'] as String;
      final archivedAt = cannedArchivedAt[libId];
      return Report(
        // Prefix the id so the reports screen can recognize canned items
        // when invoking the clone Edge Function.
        id: 'lib:$libId',
        tenantId: '',
        name: m['name'] as String? ?? '',
        isCanned: true,
        category: m['category'] as String? ?? 'custom',
        description: m['description'] as String?,
        layout: layout,
        status: archivedAt != null
            ? ReportStatus.archived
            : ReportStatus.live,
        archivedAt: archivedAt,
      );
    }).toList();

    // 2. Fetch tenant custom reports — include status, archived_at,
    //    shared_with_tenant, and creation metadata. Operational clones
    //    (the hidden tenant-scoped handles used silently for Schedule /
    //    Export of canned reports) are excluded from the user-facing list.
    final repRows = await client
        .from('reports')
        .select('*')
        .or('is_operational.is.null,is_operational.eq.false')
        .order('created_at', ascending: false);

    // 3. Resolve creator display names in a second round-trip (the FK on
    //    reports.created_by points at auth.users, not user_profiles, so we
    //    can't embed via PostgREST).
    final creatorIds = {
      for (final r in (repRows as List))
        if ((r as Map)['created_by'] != null) r['created_by'] as String,
    };
    final namesById = <String, String>{};
    if (creatorIds.isNotEmpty) {
      final profiles = await client
          .from('user_profiles')
          .select('user_id, display_name')
          .inFilter('user_id', creatorIds.toList());
      for (final p in (profiles as List)) {
        final pm = p as Map<String, dynamic>;
        final uid = pm['user_id'] as String?;
        final dn = pm['display_name'] as String?;
        if (uid != null && dn != null) namesById[uid] = dn;
      }
    }

    final custom = repRows.map((r) {
      final m = r as Map<String, dynamic>;
      final createdBy = m['created_by'] as String?;
      return Report.fromMap({
        ...m,
        'is_canned': false,
        'category': 'custom',
        'layout': (m['layout'] as Map?)?.cast<String, dynamic>() ??
            {'pages': []},
        if (createdBy != null && namesById[createdBy] != null)
          'user_profiles': {'display_name': namesById[createdBy]},
      });
    }).toList();

    return [...canned, ...custom];
  }

  // ------------------ Report Builder ------------------

  /// Fetch every `rds_*` mirror table + its columns via the `rds_catalog`
  /// RPC. Returns a list of `{table_name, display_name, columns: [...]}`.
  Future<List<Map<String, dynamic>>> rdsCatalog() async {
    final res = await client.rpc('rds_catalog');
    final rows = (res as List).cast<Map<String, dynamic>>();
    // Group by table_name preserving column order.
    final byTable = <String, Map<String, dynamic>>{};
    for (final r in rows) {
      final tn = r['table_name'] as String;
      final t = byTable.putIfAbsent(
        tn,
        () => <String, dynamic>{
          'table_name': tn,
          'display_name': r['display_name'] as String,
          'columns': <Map<String, dynamic>>[],
        },
      );
      (t['columns'] as List).add({
        'name': r['column_name'] as String,
        'data_type': r['data_type'] as String,
        'is_generated': r['is_generated'] as bool? ?? false,
      });
    }
    final out = byTable.values.toList();
    out.sort((a, b) =>
        (a['display_name'] as String).compareTo(b['display_name'] as String));
    return out;
  }

  /// Fetch the system-curated relationships + display expressions used by
  /// the join-aware Report Builder to surface virtual "Buyer Name",
  /// "Buyer Company", etc. columns.
  ///
  /// Returns `{relationships: [{from_table, from_column, to_table, to_column,
  /// role_label}], displays: [{table_name, display_expr, display_label}]}`.
  Future<Map<String, dynamic>> rdsRelations() async {
    final rels = await client
        .from('rds_relationships')
        .select(
            'from_table, from_column, to_table, to_column, role_label, is_external');
    final disps = await client
        .from('rds_table_display')
        .select('table_name, display_expr, display_label');
    return {
      'relationships': (rels as List).cast<Map<String, dynamic>>(),
      'displays': (disps as List).cast<Map<String, dynamic>>(),
    };
  }

  /// Join-aware projected read across mirrors. `columns` is a list of
  /// `{alias, column}` (plain) or `{alias, path: [...], expr}` (virtual)
  /// objects matching the `rds_select_joined` RPC's contract.
  Future<List<Map<String, dynamic>>> rdsSelectJoined({
    required String dataSourceId,
    required String baseTable,
    required List<Map<String, dynamic>> columns,
    String? dateField,
    DateTime? since,
    DateTime? until,
    int? limit,
  }) async {
    final tenantId = client.auth.currentUser?.appMetadata['active_tenant_id']
        as String?;
    if (tenantId == null) return const [];
    final bare = baseTable.startsWith('rds_') ? baseTable.substring(4) : baseTable;
    final res = await client.rpc('rds_select_joined', params: {
      'p_tenant_id': tenantId,
      'p_data_source_id': dataSourceId,
      'p_base_table': bare,
      'p_columns': columns,
      if (dateField != null) 'p_date_field': dateField,
      if (since != null) 'p_since': since.toIso8601String(),
      if (until != null) 'p_until': until.toIso8601String(),
      if (limit != null) 'p_limit': limit,
    });
    if (res is List) return res.cast<Map<String, dynamic>>();
    return const [];
  }

  /// Execute a `custom_report_query_v2`-shaped JSON via the new
  /// explicit-join wizard RPC `rds_execute_query` (ADR-0013).
  ///
  /// `query` is the full v2 JSON shape. When `preview` is true, the server
  /// caps the row limit to 200 to keep the wizard's right-side panel fast.
  /// Returns the row array; throws on RPC error so callers can surface
  /// the message in-line.
  Future<List<Map<String, dynamic>>> rdsExecuteQuery({
    required String dataSourceId,
    required Map<String, dynamic> query,
    bool preview = false,
  }) async {
    final tenantId = client.auth.currentUser?.appMetadata['active_tenant_id']
        as String?;
    if (tenantId == null) return const [];
    final res = await client.rpc('rds_execute_query', params: {
      'p_tenant_id': tenantId,
      'p_data_source_id': dataSourceId,
      'p_query': query,
      'p_preview': preview,
    });
    if (res is List) return res.cast<Map<String, dynamic>>();
    return const [];
  }

  /// Projected read from any `rds_*` mirror via the `rds_select` RPC.
  /// Strips the `rds_` prefix on the table name automatically.
  Future<List<Map<String, dynamic>>> rdsSelect({
    required String dataSourceId,
    required String table,
    required List<String> columns,
    String? dateField,
    DateTime? since,
    DateTime? until,
    int? limit,
  }) async {
    final tenantId = client.auth.currentUser?.appMetadata['active_tenant_id']
        as String?;
    if (tenantId == null) return const [];
    final bare = table.startsWith('rds_') ? table.substring(4) : table;
    final res = await client.rpc('rds_select', params: {
      'p_tenant_id': tenantId,
      'p_data_source_id': dataSourceId,
      'p_table': bare,
      'p_columns': columns,
      if (dateField != null) 'p_date_field': dateField,
      if (since != null) 'p_since': since.toIso8601String(),
      if (until != null) 'p_until': until.toIso8601String(),
      if (limit != null) 'p_limit': limit,
    });
    if (res is List) return res.cast<Map<String, dynamic>>();
    return const [];
  }

  /// Fetch a single report (custom) by id. Returns null if not found.
  Future<Report?> getReport(String id) async {
    final row = await client
        .from('reports')
        .select('*')
        .eq('id', id)
        .maybeSingle();
    if (row == null) return null;
    return Report.fromMap({
      ...row,
      'is_canned': false,
      'category': 'custom',
      'layout': (row['layout'] as Map?)?.cast<String, dynamic>() ??
          {'pages': []},
    });
  }

  /// Update a report's layout (auto-save path from the Report Builder).
  Future<void> updateReportLayout(
    String id, {
    required Map<String, dynamic> layout,
    String? name,
    String? description,
  }) async {
    await client.from('reports').update({
      'layout': layout,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
    }).eq('id', id);
  }

  /// Flip a report's status (e.g. pending → live on Publish).
  Future<void> setReportStatus(String id, ReportStatus status) async {
    await client.from('reports').update({
      'status': status.wire,
    }).eq('id', id);
  }

  // ------------------ Export & Schedule ------------------

  /// Generate an export (PDF or XLSX) for a report by invoking the matching
  /// Edge Function (`export-pdf` / `export-excel`). Returns the storage path
  /// of the generated artifact in the `exports` bucket.
  Future<String?> exportReport({
    required String reportId,
    required String format, // 'pdf' | 'xlsx'
  }) async {
    final slug = format == 'xlsx' ? 'export-excel' : 'export-pdf';
    final res = await client.functions.invoke(
      slug,
      body: {'report_id': reportId},
      headers: _fnHeaders(),
    );
    final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
    return data['storage_path'] as String?;
  }

  /// Create a short-lived signed URL for an artifact in the `exports`
  /// bucket so the user can download / open it from the browser.
  Future<String?> signedExportUrl(String storagePath,
      {int expiresInSeconds = 3600}) async {
    final res = await client.storage
        .from('exports')
        .createSignedUrl(storagePath, expiresInSeconds);
    return res;
  }

  /// List schedules for a report (current tenant — enforced by RLS).
  Future<List<Map<String, dynamic>>> listSchedules(String reportId) async {
    final rows = await client
        .from('schedules')
        .select('*')
        .eq('report_id', reportId)
        .order('created_at', ascending: false);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Insert a new schedule row. RLS uses `current_tenant_id()` default.
  Future<Map<String, dynamic>> createSchedule({
    required String reportId,
    required String cron,
    required List<String> recipients,
    required List<String> format,
    bool enabled = true,
  }) async {
    final inserted = await client
        .from('schedules')
        .insert({
          'report_id': reportId,
          'cron': cron,
          'recipients': recipients,
          'format': format,
          'enabled': enabled,
        })
        .select()
        .single();
    return (inserted as Map).cast<String, dynamic>();
  }

  Future<void> deleteSchedule(String scheduleId) async {
    await client.from('schedules').delete().eq('id', scheduleId);
  }

  Future<void> setScheduleEnabled(String scheduleId, bool enabled) async {
    await client
        .from('schedules')
        .update({'enabled': enabled})
        .eq('id', scheduleId);
  }

  // ------------------ User report prefs ------------------
  /// Archive a canned report for the current user only (does not affect
  /// other users or tenants). `libraryItemId` is the bare uuid (no `lib:`
  /// prefix).
  Future<void> archiveCannedForUser(String libraryItemId) async {
    final user = client.auth.currentUser;
    if (user == null) return;
    final tid =
        user.appMetadata['active_tenant_id'] as String?;
    if (tid == null) return;
    await client.from('user_report_prefs').upsert({
      'user_id': user.id,
      'tenant_id': tid,
      'target_id': libraryItemId,
      'is_canned': true,
      'archived_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id,target_id,is_canned');
  }

  /// Restore a previously-archived canned report for the current user.
  Future<void> restoreCannedForUser(String libraryItemId) async {
    final user = client.auth.currentUser;
    if (user == null) return;
    await client.from('user_report_prefs').upsert({
      'user_id': user.id,
      'tenant_id': user.appMetadata['active_tenant_id'] as String? ?? '',
      'target_id': libraryItemId,
      'is_canned': true,
      'archived_at': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id,target_id,is_canned');
  }

  // ------------------ Report clone (custom → custom) ------------------
  /// Clone a tenant-scoped custom report into a new row with an
  /// auto-incremented name (e.g. "Sales Report" → "Copy of Sales Report",
  /// then "Copy of Sales Report 2" if it already exists).
  Future<String?> cloneCustomReport(Report r) async {
    final base = r.name.trim();
    final existing = await client
        .from('reports')
        .select('name')
        .order('name');
    final names = <String>{
      for (final e in (existing as List))
        ((e as Map)['name'] as String? ?? '').trim()
    };
    String candidate = 'Copy of $base';
    if (names.contains(candidate)) {
      var n = 2;
      while (names.contains('$candidate $n')) {
        n++;
      }
      candidate = '$candidate $n';
    }
    final inserted = await client
        .from('reports')
        .insert({
          'name': candidate,
          'description': r.description,
          'layout': r.layout,
          'status': 'pending',
        })
        .select('id')
        .single();
    return inserted['id'] as String?;
  }
}

final repoProvider = Provider<SupabaseRepo>(
  (ref) => SupabaseRepo(ref.watch(supabaseProvider)),
);

final dashboardsListProvider = FutureProvider<List<Dashboard>>((ref) {
  return ref.watch(repoProvider).listDashboards();
});

final dashboardWidgetsProvider =
    FutureProvider.family<List<WidgetModel>, String>((ref, dashId) {
  return ref.watch(repoProvider).listWidgets(dashId);
});

final activeTenantObjectProvider = FutureProvider<Tenant?>((ref) async {
  final id = ref.watch(activeTenantProvider);
  if (id == null) return null;
  return ref.watch(repoProvider).getTenant(id);
});

final activeTenantMembersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final tenantId = ref.watch(activeTenantProvider);
  if (tenantId == null) return [];
  final client = ref.watch(supabaseProvider);
  // Uses the list_tenant_members RPC which filters Bryzos staff out of
  // non-Bryzos tenants for non-Bryzos viewers (silent-owners rule).
  final rows = await client.rpc('list_tenant_members', params: {'tid': tenantId});
  return (rows as List).map((r) {
    final m = r as Map<String, dynamic>;
    final firstName = (m['first_name'] as String?)?.trim() ?? '';
    final lastName  = (m['last_name']  as String?)?.trim() ?? '';
    final fullName  = [firstName, lastName].where((s) => s.isNotEmpty).join(' ');
    final displayName = (m['display_name'] as String?)?.trim() ?? '';
    return {
      'role': m['role'],
      'display_name': displayName.isNotEmpty
          ? displayName
          : (fullName.isNotEmpty ? fullName : 'Unknown User'),
      'first_name': firstName,
      'last_name': lastName,
      'full_name': fullName.isNotEmpty ? fullName : null,
      'email': (m['email'] as String?)?.trim() ?? '',
      'user_id': m['user_id'],
      'is_bryzos_staff': m['is_bryzos_staff'] ?? false,
    };
  }).toList();
});

/// Pending (un-accepted, un-expired) invites for the active tenant.
/// Returns rows of: id, email, role, expires_at, invited_by (uuid),
/// inviter_is_bryzos_staff. Used by Settings → Organizations to show the
/// "Pending Invites" list with a revoke (×) action per row.
/// (Release Plan §1.9)
///
/// Uses the list_tenant_pending_invites RPC which filters invites sent
/// by Bryzos staff out of non-Bryzos tenants for non-Bryzos viewers
/// (silent-owners rule).
final activeTenantPendingInvitesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final tenantId = ref.watch(activeTenantProvider);
  if (tenantId == null) return [];
  final client = ref.watch(supabaseProvider);
  final rows = await client.rpc(
    'list_tenant_pending_invites',
    params: {'tid': tenantId},
  );
  return (rows as List).cast<Map<String, dynamic>>();
});

final dataSourcesProvider = FutureProvider<List<DataSource>>((ref) {
  return ref.watch(repoProvider).listDataSources();
});

/// Sync state (cadence + last_sync_*) for a single data source.
/// Auto-refreshes every 10 s so the UI reflects background completion.
final dataSourceSyncProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>?, String>(
  (ref, dataSourceId) async {
    return ref.watch(repoProvider).getDataSourceSync(dataSourceId);
  },
);

/// Live progress (completed/total tables, elapsed, ETA) for an in-flight sync.
/// Polled on demand by the UI while a manual refresh is running.
final dataSourceSyncProgressProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>, String>(
  (ref, dataSourceId) async {
    return ref.watch(repoProvider).getSyncProgress(dataSourceId);
  },
);

/// Returns the caller's role in the active tenant ('owner' | 'admin' | 'editor' | 'viewer'),
/// or null if there is no active tenant / membership.
final activeTenantRoleProvider = FutureProvider<String?>((ref) async {
  final tid = ref.watch(activeTenantProvider);
  if (tid == null) return null;
  final client = ref.watch(supabaseProvider);
  final uid = client.auth.currentUser?.id;
  if (uid == null) return null;
  try {
    final row = await client
        .from('memberships')
        .select('role')
        .eq('tenant_id', tid)
        .eq('user_id', uid)
        .maybeSingle();
    return (row as Map?)?['role'] as String?;
  } catch (_) {
    return null;
  }
});

// --- Convenience role-tier checks (Release Plan §9.3, §9.4) -----------------
//
// These read `activeTenantRoleProvider` and return a synchronous `bool` so UI
// affordances can render without juggling AsyncValue at every call site.
//
// Tier order:  viewer < editor < admin < owner
//
// Rule of thumb:
//   - Read pages / view dashboards / view reports        → any role.
//   - Edit / create / clone widgets, dashboards, reports → editor or higher.
//   - Manage members / branding / invites                → admin or higher.
//   - Create tenants / change data sources               → owner.
//
// All of these treat "unknown role" (loading or null) as the *lowest*
// privilege — i.e. we hide rather than flash an edit button that would
// disappear a moment later.

int _roleRank(String? role) {
  switch (role) {
    case 'owner':
      return 4;
    case 'admin':
      return 3;
    case 'editor':
      return 2;
    case 'viewer':
      return 1;
    default:
      return 0;
  }
}

/// True iff the active-tenant role is at or above [minimum].
bool roleAtLeast(String? role, String minimum) =>
    _roleRank(role) >= _roleRank(minimum);

/// The currently signed-in user's id (or null when signed out).
final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(supabaseProvider).auth.currentUser?.id;
});

/// Synchronous viewer/editor/admin/owner gates for the active tenant.
/// They return `false` while the role is loading — fail-closed by design.
final canViewProvider = Provider<bool>((ref) {
  final role = ref.watch(activeTenantRoleProvider).value;
  return roleAtLeast(role, 'viewer');
});
final canEditProvider = Provider<bool>((ref) {
  final role = ref.watch(activeTenantRoleProvider).value;
  return roleAtLeast(role, 'editor');
});
final canAdminProvider = Provider<bool>((ref) {
  final role = ref.watch(activeTenantRoleProvider).value;
  return roleAtLeast(role, 'admin');
});
final canOwnProvider = Provider<bool>((ref) {
  final role = ref.watch(activeTenantRoleProvider).value;
  return roleAtLeast(role, 'owner');
});

/// True if the *current user* is an `owner` of ANY tenant. Owners are Bryzos
/// admins — they can create new organizations and edit data sources across
/// every org they belong to.
final isBryzosOwnerProvider = FutureProvider<bool>((ref) async {
  final client = ref.watch(supabaseProvider);
  final uid = client.auth.currentUser?.id;
  if (uid == null) return false;
  try {
    final rows = await client
        .from('memberships')
        .select('role')
        .eq('user_id', uid)
        .eq('role', 'owner')
        .limit(1);
    return (rows as List).isNotEmpty;
  } catch (_) {
    return false;
  }
});

final libraryProvider = FutureProvider<List<LibraryItem>>((ref) {
  // Re-fetch when the active tenant changes so we never show another
  // tenant's library items after a switch.
  ref.watch(activeTenantProvider);
  return ref.watch(repoProvider).listLibrary();
});

final reportsProvider = FutureProvider<List<Report>>((ref) {
  // Re-fetch when the active tenant changes. RLS already filters server-side
  // (`tenant_id = current_tenant_id()`), but without this watch the cached
  // list from the previous tenant would persist after `switch-tenant`.
  ref.watch(activeTenantProvider);
  return ref.watch(repoProvider).listReports();
});
