import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

final supabaseProvider = Provider<SupabaseClient>(
  (_) => Supabase.instance.client,
);

final _authChangeProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(supabaseProvider).auth.onAuthStateChange;
});

final activeTenantProvider = StateProvider<String?>((ref) {
  ref.watch(_authChangeProvider); // React to login/logout
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

  /// Runs an idempotent read with up to 3 retries on browser-level transport
  /// failures (e.g. `ClientException: Failed to fetch`, DNS hiccup, transient
  /// proxy interference). Real auth/RLS/server errors fall straight through
  /// unchanged — we only swallow obviously-transient transport failures.
  ///
  /// Backoff schedule (with ±30% jitter):
  ///   - Attempt 1: immediate
  ///   - Attempt 2: ~500ms
  ///   - Attempt 3: ~1500ms
  ///   - Attempt 4: ~4000ms
  /// Worst-case total wait before final failure: ~6 seconds.
  ///
  /// Originally added after a Ryerson user (first login from a corporate
  /// network) hit `Failed to fetch` on `/rest/v1/dashboards`. Strengthened
  /// to 3 retries after a second Ryerson user (Frank) hit the same error
  /// on dashboard load — the single 600ms retry was insufficient for
  /// flakier corporate networks / WAF interference.
  static final _retryRng = math.Random();
  Future<T> _retryTransient<T>(Future<T> Function() op) async {
    const baseDelaysMs = [500, 1500, 4000];
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        return await op();
      } catch (e, st) {
        final msg = e.toString().toLowerCase();
        final isTransient = msg.contains('failed to fetch') ||
            msg.contains('failed host lookup') ||
            msg.contains('clientexception') ||
            msg.contains('socketexception') ||
            msg.contains('connection closed') ||
            msg.contains('connection reset') ||
            msg.contains('network is unreachable');
        if (!isTransient) rethrow;
        lastError = e;
        lastStack = st;
        if (attempt == 3) break;
        final base = baseDelaysMs[attempt];
        // ±30% jitter to avoid thundering-herd on shared networks.
        final jitter = (base * (0.7 + _retryRng.nextDouble() * 0.6)).round();
        await Future<void>.delayed(Duration(milliseconds: jitter));
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
  }

  // ------------------ Tenants ------------------
  Future<List<Tenant>> listTenants() async {
    // Route through the `db-read` Edge Function (see comment on
    // listDashboards) so corporate WAFs that block SQL-shaped PostgREST query
    // strings (e.g. `order=name`) cannot interfere. RLS is still enforced
    // server-side using the caller's JWT.
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listTenants'}),
    );
    final data = res.data;
    final List rows = (data is Map && data['tenants'] is List)
        ? data['tenants'] as List
        : const [];
    return rows
        .map((r) => Tenant.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  Future<Tenant> getTenant(String id) async {
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: {'op': 'getTenant', 'args': {'id': id}}),
    );
    final data = res.data;
    final row = (data is Map && data['tenant'] is Map)
        ? (data['tenant'] as Map).cast<String, dynamic>()
        : null;
    if (row == null) {
      throw StateError('Tenant not found: $id');
    }
    return Tenant.fromMap(row);
  }

  // ------------------ Dashboards ------------------
  Future<List<Dashboard>> listDashboards() async {
    // Route through the `db-read` Edge Function (WAF-safe transport). RLS is
    // still enforced server-side using the caller's JWT.
    //
    // History: this previously called the standalone `list-dashboards`
    // Edge Function (Phase 2 hotfix #1). It was folded into `db-read` in
    // Stage 2 to keep a single dispatcher for all reads. The old
    // `list-dashboards` function remains deployed for one promotion cycle
    // as a safety net and will be decommissioned after Prod soak.
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listDashboards'}),
    );
    final data = res.data;
    final List rows = (data is Map && data['dashboards'] is List)
        ? data['dashboards'] as List
        : const [];
    return rows
        .map((r) => Dashboard.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  Future<Dashboard> getDashboard(String id) async {
    // Route through `db-read` Edge Function for WAF-safe transport. RLS still
    // enforced server-side using the caller's JWT.
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: {'op': 'getDashboard', 'args': {'id': id}}),
    );
    final data = res.data;
    final row = (data is Map && data['dashboard'] is Map)
        ? (data['dashboard'] as Map).cast<String, dynamic>()
        : null;
    if (row == null) {
      throw StateError('Dashboard not found: $id');
    }
    return Dashboard.fromMap(row);
  }

  Future<Dashboard> createDashboard(String name) async {
    final row = await client
        .from('dashboards')
        .insert({'name': name, 'global_settings': {}}).select().single();
    return Dashboard.fromMap(row);
  }

  // ------------------ Dashboard Template Gallery ------------------
  /// Lists all active dashboard templates available to every authenticated
  /// user across all tenants (curated by Bryzos).
  Future<List<Map<String, dynamic>>> listDashboardTemplates() async {
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listDashboardTemplates'}),
    );
    final data = res.data;
    final List rows = (data is Map && data['templates'] is List)
        ? data['templates'] as List
        : const [];
    return rows.map((r) => (r as Map).cast<String, dynamic>()).toList();
  }

  /// Returns the widgets attached to a template, for preview rendering.
  Future<List<Map<String, dynamic>>> listDashboardTemplateWidgets(
      String templateId) async {
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read', body: {
        'op': 'listDashboardTemplateWidgets',
        'args': {'template_id': templateId},
      }),
    );
    final data = res.data;
    final List rows = (data is Map && data['widgets'] is List)
        ? data['widgets'] as List
        : const [];
    return rows.map((r) => (r as Map).cast<String, dynamic>()).toList();
  }

  /// Deep-clones a template into a new dashboard in the caller's tenant.
  /// Returns the new dashboard id. The server-side RPC rebinds data sources
  /// to the caller's tenant.
  Future<String> cloneDashboardTemplate({
    required String templateId,
    String? newName,
  }) async {
    final id = await client.rpc('clone_dashboard_template', params: {
      'p_template_id': templateId,
      'p_new_name': newName,
    });
    return id as String;
  }

  Future<void> deleteDashboard(String id) async {
    // Widgets cascade via FK; if not, clean them up explicitly first.
    await client.from('widgets').delete().eq('dashboard_id', id);
    await client.from('dashboards').delete().eq('id', id);
  }

  /// Persist a dashboard's `global_settings` JSONB blob (theme overrides,
  /// time range, grid lines, etc.).
  Future<void> updateDashboardGlobalSettings(
      String dashboardId, Map<String, dynamic> settings) async {
    await client
        .from('dashboards')
        .update({'global_settings': settings}).eq('id', dashboardId);
  }

  /// Returns `{id → settings}` for every widget on the given dashboard.
  /// Used by the global-settings editor to snapshot per-widget settings
  /// before applying a tenant-wide override (so "reset to original" works).
  /// Routed through `db-read` for WAF-safe transport.
  Future<Map<String, Map<String, dynamic>>> dashboardWidgetSnapshots(
      String dashboardId) async {
    final res = await _retryTransient(
      () => client.functions.invoke('db-read', body: {
        'op': 'dashboardWidgetSnapshots',
        'args': {'dashboard_id': dashboardId},
      }),
    );
    final data = res.data;
    final List rows = (data is Map && data['snapshots'] is List)
        ? data['snapshots'] as List
        : const [];
    final snap = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final m = (row as Map).cast<String, dynamic>();
      snap[m['id'] as String] = Map<String, dynamic>.from(
          (m['settings'] as Map?)?.cast<String, dynamic>() ?? const {});
    }
    return snap;
  }

  /// Merge `keysToWrite` into every widget's `settings` JSONB on the given
  /// dashboard. The merge happens server-side via the
  /// `merge_widget_settings_for_dashboard` RPC if available; otherwise the
  /// caller falls back to per-row updates. For now we do per-row client-side
  /// updates because that's what the existing UI did.
  Future<void> mergeWidgetSettingsOnDashboard({
    required String dashboardId,
    required Map<String, dynamic> keysToWrite,
  }) async {
    if (keysToWrite.isEmpty) return;
    final snap = await dashboardWidgetSnapshots(dashboardId);
    for (final entry in snap.entries) {
      final merged = {...entry.value, ...keysToWrite};
      await client
          .from('widgets')
          .update({'settings': merged}).eq('id', entry.key);
    }
  }

  /// Overwrite the `settings` JSONB on a single widget.
  Future<void> updateWidgetSettings(
      String widgetId, Map<String, dynamic> settings) async {
    await client
        .from('widgets')
        .update({'settings': settings}).eq('id', widgetId);
  }

  // ------------------ Widgets ------------------
  Future<List<WidgetModel>> listWidgets(String dashboardId) async {
    // Route through `db-read` Edge Function for WAF-safe transport.
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: {'op': 'listWidgets', 'args': {'dashboard_id': dashboardId}}),
    );
    final data = res.data;
    final List rows = (data is Map && data['widgets'] is List)
        ? data['widgets'] as List
        : const [];
    return rows
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
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listDataSources'}),
    );
    final data = res.data;
    final List rows = (data is Map && data['data_sources'] is List)
        ? data['data_sources'] as List
        : const [];
    return rows
        .map((r) => DataSource.fromMap((r as Map).cast<String, dynamic>()))
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
      // Route through `db-read` (WAF-safe transport).
      final freshRes = await _retryTransient(
        () => client.functions.invoke('db-read',
            body: {'op': 'getDataSource', 'args': {'id': ds.id}}),
      );
      final freshData = freshRes.data;
      final fresh = (freshData is Map && freshData['data_source'] is Map)
          ? (freshData['data_source'] as Map).cast<String, dynamic>()
          : null;
      if (fresh == null) {
        throw StateError('Data source not found after secret write: ${ds.id}');
      }
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
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read', body: {
        'op': 'getDataSourceSync',
        'args': {'data_source_id': dataSourceId},
      }),
    );
    final data = res.data;
    final row = (data is Map && data['sync'] is Map)
        ? (data['sync'] as Map).cast<String, dynamic>()
        : null;
    return row;
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
    // Route through `db-read` Edge Function — server-side composer returns
    // total / status / window_start_iso / runs in a single round-trip and
    // avoids any SQL-shaped PostgREST query strings on the wire.
    final res = await _retryTransient(
      () => client.functions.invoke('db-read', body: {
        'op': 'getSyncProgress',
        'args': {'data_source_id': dataSourceId},
      }),
    );
    final data = (res.data is Map)
        ? (res.data as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final total = (data['total'] as num?)?.toInt() ?? 0;
    final status = data['status'] as String?;
    final windowStartIso = data['window_start_iso'] as String?;
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
    final list = ((data['runs'] as List?) ?? const [])
        .map((r) => (r as Map).cast<String, dynamic>())
        .toList();
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
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listLibraryItems'}),
    );
    final data = res.data;
    final List rows = (data is Map && data['library_items'] is List)
        ? data['library_items'] as List
        : const [];
    return rows
        .map((r) => LibraryItem.fromMap((r as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Fetch a single library item by id. Returns the raw row (no model) so
  /// the caller can interpret `kind`/`payload` directly. Returns null if
  /// not found or RLS denies access. Routed through `db-read` for
  /// WAF-safe transport.
  Future<Map<String, dynamic>?> getLibraryItem(String id) async {
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: {'op': 'getLibraryItem', 'args': {'id': id}}),
    );
    final data = res.data;
    if (data is Map && data['library_item'] is Map) {
      return (data['library_item'] as Map).cast<String, dynamic>();
    }
    return null;
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
    // Route through `db-read` Edge Function (WAF-safe transport). The
    // server-side composer returns the same multi-step payload we used to
    // assemble client-side via 4-5 SQL-shaped PostgREST GETs.
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listReports'}),
    );
    final data = (res.data is Map)
        ? (res.data as Map).cast<String, dynamic>()
        : const <String, dynamic>{};

    // 1. Library items (canned reports + widgets).
    final libRowsRaw = (data['library_items'] as List?) ?? const [];

    // Deduplicate: if a name exists as both 'widget' and 'report', prefer the 'widget'.
    final Map<String, dynamic> deduplicatedLib = {};
    for (final row in libRowsRaw) {
      final m = (row as Map).cast<String, dynamic>();
      final name = m['name'] as String? ?? '';
      final kind = m['kind'] as String? ?? '';
      if (!deduplicatedLib.containsKey(name)) {
        deduplicatedLib[name] = m;
      } else {
        final existingKind = deduplicatedLib[name]!['kind'] as String? ?? '';
        if (existingKind == 'report' && kind == 'widget') {
          deduplicatedLib[name] = m;
        }
      }
    }
    final libRows = deduplicatedLib.values.toList();

    // 1b. Canned archive prefs for the current user.
    final cannedArchivedAt = <String, DateTime>{};
    final prefs = (data['user_prefs'] as List?) ?? const [];
    for (final p in prefs) {
      final m = (p as Map).cast<String, dynamic>();
      final tid = m['target_id'] as String?;
      final at = m['archived_at'] as String?;
      if (tid != null && at != null) {
        final parsed = DateTime.tryParse(at);
        if (parsed != null) cannedArchivedAt[tid] = parsed;
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

    // 2. Tenant custom reports (operational clones excluded server-side).
    final repRows = (data['reports'] as List?) ?? const [];

    // 3. Creator display names (server already resolved).
    final namesById = <String, String>{};
    for (final p in ((data['profiles'] as List?) ?? const [])) {
      final pm = (p as Map).cast<String, dynamic>();
      final uid = pm['user_id'] as String?;
      final dn = pm['display_name'] as String?;
      if (uid != null && dn != null) namesById[uid] = dn;
    }

    final custom = repRows.map((r) {
      final m = (r as Map).cast<String, dynamic>();
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

    final scheduledReportIds = <String>{
      for (final id in ((data['schedule_report_ids'] as List?) ?? const []))
        if (id is String) id,
    };
    final scheduledLibraryIds = <String>{};
    for (final row in ((data['op_reports'] as List?) ?? const [])) {
      final m = (row as Map).cast<String, dynamic>();
      final reportId = m['id'] as String?;
      final libId = m['cloned_from_library_item'] as String?;
      if (reportId != null &&
          libId != null &&
          scheduledReportIds.contains(reportId)) {
        scheduledLibraryIds.add(libId);
      }
    }

    final scheduledCanned = canned.map((r) {
      final libId = r.id.startsWith('lib:') ? r.id.substring(4) : r.id;
      return r.copyWith(hasEnabledSchedule: scheduledLibraryIds.contains(libId));
    }).toList();
    final scheduledCustom = custom
        .map((r) => r.copyWith(
              hasEnabledSchedule: scheduledReportIds.contains(r.id),
            ))
        .toList();

    return [...scheduledCanned, ...scheduledCustom];
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

  /// Change a user's role in a tenant (via Edge Function for reliability).
  Future<void> changeUserRole(String tenantId, String userId, String role) async {
    final res = await client.functions.invoke('manage-member', body: {
      'action': 'change_role',
      'tenant_id': tenantId,
      'target_user_id': userId,
      'new_role': role,
    });
    if (res.status != 200) {
      final msg = (res.data is Map ? res.data['error'] : null) ?? 'Failed to change role';
      throw Exception(msg);
    }
  }

  /// Remove a user from a tenant (via Edge Function for reliability).
  Future<void> removeUser(String tenantId, String userId) async {
    final res = await client.functions.invoke('manage-member', body: {
      'action': 'remove',
      'tenant_id': tenantId,
      'target_user_id': userId,
    });
    if (res.status != 200) {
      final msg = (res.data is Map ? res.data['error'] : null) ?? 'Failed to remove user';
      throw Exception(msg);
    }
  }

  /// Fetch the system-curated relationships + display expressions used by
  /// the join-aware Report Builder to surface virtual "Buyer Name",
  /// "Buyer Company", etc. columns.
  ///
  /// Returns `{relationships: [{from_table, from_column, to_table, to_column,
  /// role_label}], displays: [{table_name, display_expr, display_label}]}`.
  Future<Map<String, dynamic>> rdsRelations() async {
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'rdsRelations'}),
    );
    final data = (res.data is Map)
        ? (res.data as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final rels = (data['relationships'] as List?) ?? const [];
    final disps = (data['displays'] as List?) ?? const [];
    return {
      'relationships':
          rels.map((r) => (r as Map).cast<String, dynamic>()).toList(),
      'displays':
          disps.map((r) => (r as Map).cast<String, dynamic>()).toList(),
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

  /// Bryzos-only raw-SQL escape hatch for the Custom Report Builder
  /// (`rds_execute_raw_sql_bryzos`). Server enforces:
  ///   - Caller email must end in @bryzos.com
  ///   - Single statement, read-only, 30s timeout
  ///   - Keyword blacklist (no INSERT/UPDATE/DELETE/DDL/SET/etc.)
  /// When `preview` is true the server caps the result at 200 rows; 10000 otherwise.
  /// Throws the server's `forbidden`/`forbidden keyword`/etc. message on failure.
  Future<List<Map<String, dynamic>>> rdsExecuteRawSqlBryzos({
    required String dataSourceId,
    required String sql,
    bool preview = false,
  }) async {
    final tenantId = client.auth.currentUser?.appMetadata['active_tenant_id']
        as String?;
    if (tenantId == null) return const [];
    final res = await client.rpc('rds_execute_raw_sql_bryzos', params: {
      'p_tenant_id': tenantId,
      'p_data_source_id': dataSourceId,
      'p_sql': sql,
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
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: {'op': 'getReport', 'args': {'id': id}}),
    );
    final data = res.data;
    final row = (data is Map && data['report'] is Map)
        ? (data['report'] as Map).cast<String, dynamic>()
        : null;
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

  /// Archive a custom report (status → 'archived', stamps archived_at).
  /// Canned reports use [archiveCannedForUser] instead (per-user hide).
  Future<void> archiveReport(String id) async {
    await client.from('reports').update({
      'status': 'archived',
      'archived_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id);
  }

  /// Restore a custom report (status → 'live', clears archived_at).
  Future<void> restoreReport(String id) async {
    await client.from('reports').update({
      'status': 'live',
      'archived_at': null,
    }).eq('id', id);
  }

  /// Hard-delete a custom report row. Canned reports cannot be deleted.
  Future<void> deleteReport(String id) async {
    await client.from('reports').delete().eq('id', id);
  }

  /// Create a new (custom) report row and return its id.
  /// `tenantId` is optional — when null, the DB default / RLS applies.
  Future<String?> createReport({
    required String name,
    Map<String, dynamic>? layout,
    String? description,
    String status = 'pending',
    String? tenantId,
    bool sharedWithTenant = false,
  }) async {
    final row = await client
        .from('reports')
        .insert({
          if (tenantId != null) 'tenant_id': tenantId,
          'name': name,
          if (description != null) 'description': description,
          'layout': layout ?? const {'pages': []},
          'status': status,
          'shared_with_tenant': sharedWithTenant,
        })
        .select('*')
        .single();
    return row['id'] as String?;
  }

  /// Create a custom report and return the full row map (used by the Builder
  /// which needs the inserted row to materialize a [Report] locally).
  Future<Map<String, dynamic>> createReportRow({
    required String name,
    Map<String, dynamic>? layout,
    String? description,
    String status = 'pending',
    String? tenantId,
    bool sharedWithTenant = false,
  }) async {
    final row = await client
        .from('reports')
        .insert({
          if (tenantId != null) 'tenant_id': tenantId,
          'name': name,
          'description': description,
          'layout': layout ?? const {'pages': []},
          'status': status,
          'shared_with_tenant': sharedWithTenant,
        })
        .select('*')
        .single();
    return (row as Map).cast<String, dynamic>();
  }

  /// Toggle / set the `shared_with_tenant` flag on a custom report.
  Future<void> setReportSharedWithTenant(String id, bool value) async {
    await client.from('reports').update({
      'shared_with_tenant': value,
    }).eq('id', id);
  }

  /// Picker data — returns shareable users for a report.
  Future<List<Map<String, dynamic>>> listShareableUsersForReport(String reportId) async {
    final rows = await client.rpc(
      'list_shareable_users_for_report',
      params: {'p_report_id': reportId},
    );
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Manage Access data — current share rows for a report.
  Future<List<Map<String, dynamic>>> listReportShares(String reportId) async {
    final rows = await client.rpc(
      'list_report_shares',
      params: {'p_report_id': reportId},
    );
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Share a report with a batch of targets (user_id or email).
  Future<Map<String, dynamic>> shareReportBatch({
    required String reportId,
    required List<Map<String, String>> targets,
  }) async {
    final res = await client.functions.invoke(
      'share-report',
      body: {'report_id': reportId, 'targets': targets},
      headers: _fnHeaders(),
    );
    if (res.status != 200 && res.status != 201) {
      throw Exception(res.data?['error'] ?? 'Unknown error sharing report');
    }
    return (res.data as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Revoke a single report share by its share row id.
  Future<bool> revokeReportShare(String shareId) async {
    final res = await client.functions.invoke(
      'revoke-report-share',
      body: {'share_id': shareId},
      headers: _fnHeaders(),
    );
    if (res.status != 200 && res.status != 201) {
      throw Exception(res.data?['error'] ?? 'Unknown error revoking report share');
    }
    return (res.data as Map?)?['removed_membership'] == true;
  }

  // ------------------ Export & Schedule ------------------

  /// Generate an export (PDF or XLSX) for a report by invoking the matching
  /// Edge Function (`export-pdf` / `export-excel`). Returns the storage path
  /// of the generated artifact in the `exports` bucket.
  Future<String?> exportReport({
    required String reportId,
    required String format, // 'pdf' | 'xlsx'
    String? exportName,
  }) async {
    final slug = format == 'xlsx' ? 'export-excel' : 'export-pdf';
    final res = await client.functions.invoke(
      slug,
      body: {
        'report_id': reportId,
        if (exportName != null && exportName.trim().isNotEmpty)
          'export_name': exportName.trim(),
      },
      headers: _fnHeaders(),
    );
    final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
    return data['storage_path'] as String?;
  }

  /// Share a dashboard with a batch of targets (existing users by user_id
  /// and/or invitees by email). Returns the raw per-target results so the
  /// caller can surface success/error counts.
  ///
  /// Backwards-compatible single-email convenience: `shareDashboard(id, email)`.
  Future<Map<String, dynamic>> shareDashboardBatch({
    required String dashboardId,
    required List<Map<String, String>> targets,
  }) async {
    final res = await client.functions.invoke(
      'share-dashboard',
      body: {'dashboard_id': dashboardId, 'targets': targets},
      headers: _fnHeaders(),
    );
    if (res.status != 200 && res.status != 201) {
      throw Exception(res.data?['error'] ?? 'Unknown error sharing dashboard');
    }
    return (res.data as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Legacy single-email share — kept for any callers that haven't moved to
  /// the batch form. Internally calls the same Edge Function.
  Future<void> shareDashboard(String dashboardId, String email) async {
    final res = await client.functions.invoke(
      'share-dashboard',
      body: {'dashboard_id': dashboardId, 'email': email},
      headers: _fnHeaders(),
    );
    if (res.status != 200 && res.status != 201) {
      throw Exception(res.data?['error'] ?? 'Unknown error sharing dashboard');
    }
  }

  /// Picker data — returns shareable users visible to the caller.
  Future<List<Map<String, dynamic>>> listShareableUsers(String dashboardId) async {
    final rows = await client.rpc(
      'list_shareable_users',
      params: {'p_dashboard_id': dashboardId},
    );
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Manage Access data — current share rows (resolved + pending).
  Future<List<Map<String, dynamic>>> listDashboardShares(String dashboardId) async {
    final rows = await client.rpc(
      'list_dashboard_shares',
      params: {'p_dashboard_id': dashboardId},
    );
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Revoke a single dashboard share by its share row id.
  Future<bool> revokeDashboardShare(String shareId) async {
    final res = await client.functions.invoke(
      'revoke-dashboard-share',
      body: {'share_id': shareId},
      headers: _fnHeaders(),
    );
    if (res.status != 200 && res.status != 201) {
      throw Exception(res.data?['error'] ?? 'Unknown error revoking share');
    }
    return (res.data as Map?)?['removed_membership'] == true;
  }

  /// Create a short-lived signed URL for an artifact in the `exports`
  /// bucket so the user can download / open it from the browser.
  Future<String?> signedExportUrl(
    String storagePath, {
    int expiresInSeconds = 3600,
    String? downloadFileName,
  }) async {
    final signed = await client.storage
        .from('exports')
        .createSignedUrl(storagePath, expiresInSeconds);
    if (downloadFileName == null || downloadFileName.trim().isEmpty) {
      return signed;
    }
    final uri = Uri.parse(signed);
    final qp = Map<String, String>.from(uri.queryParameters);
    qp['download'] = downloadFileName.trim();
    return uri.replace(queryParameters: qp).toString();
  }

  /// List schedules for a report (current tenant — enforced by RLS).
  Future<List<Map<String, dynamic>>> listSchedules(String reportId) async {
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await _retryTransient(
      () => client.functions.invoke('db-read', body: {
        'op': 'listSchedules',
        'args': {'report_id': reportId},
      }),
    );
    final data = res.data;
    final List rows = (data is Map && data['schedules'] is List)
        ? data['schedules'] as List
        : const [];
    return rows.map((r) => (r as Map).cast<String, dynamic>()).toList();
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
    // Route through `db-read` Edge Function (WAF-safe transport).
    final existingRes = await _retryTransient(
      () => client.functions.invoke('db-read',
          body: const {'op': 'listReportNames'}),
    );
    final existingData = existingRes.data;
    final List existing = (existingData is Map && existingData['names'] is List)
        ? existingData['names'] as List
        : const [];
    final names = <String>{
      for (final e in existing) (e as String? ?? '').trim()
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
  ref.watch(activeTenantProvider); // React to tenant switch
  ref.watch(currentUserIdProvider); // React to login/logout
  return ref.watch(repoProvider).listDashboards();
});

final dashboardWidgetsProvider =
    FutureProvider.family<List<WidgetModel>, String>((ref, dashId) {
  ref.watch(activeTenantProvider); // React to tenant switch
  ref.watch(currentUserIdProvider); // React to login/logout
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
  ref.watch(activeTenantProvider); // React to tenant switch
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
    // Route through `db-read` for WAF-safe transport. The Edge Function
    // returns the caller's membership row in the given tenant (RLS already
    // restricts memberships to the caller's user_id, so the result is
    // implicitly scoped to this user).
    final res = await client.functions.invoke('db-read',
        body: {'op': 'getMembership', 'args': {'tenant_id': tid}});
    final data = res.data;
    final row = (data is Map && data['membership'] is Map)
        ? data['membership'] as Map
        : null;
    return row?['role'] as String?;
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
  ref.watch(_authChangeProvider); // React to login/logout
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

/// IRONCLAD dashboard edit permission check.
///
/// A user can edit a dashboard if and ONLY if:
/// 1. They are the OWNER of the dashboard (created_by == current user), AND
/// 2. Their role in the DASHBOARD'S TENANT is 'editor' or higher
///
/// CRITICAL: We check the role in the DASHBOARD'S tenant, NOT the user's
/// active tenant. This prevents the bug where a user with admin role in
/// TenantA can edit dashboards in TenantB (where they might be guest).
///
/// Shared dashboards are ALWAYS view-only — the viewer is not the owner.
/// Guests and viewers can NEVER edit any dashboard, regardless of ownership.
///
/// This is the SINGLE SOURCE OF TRUTH for dashboard edit permissions.
/// All UI code must use this provider when determining edit controls.
final canEditDashboardProvider =
    FutureProvider.family<bool, Dashboard?>((ref, dashboard) async {
  if (dashboard == null) return false;

  // Check 1: User must be the dashboard owner (first because it's fast/sync)
  final uid = ref.watch(currentUserIdProvider);
  if (!dashboard.isOwnedBy(uid)) return false;

  // Check 2: User must have editor+ role in the DASHBOARD'S tenant (not active tenant)
  // This is the critical fix — we query the user's role in the dashboard's tenant_id
  final client = ref.watch(supabaseProvider);
  if (uid == null) return false;
  
  try {
    // Route through `db-read` for WAF-safe transport. RLS already restricts
    // memberships rows to the caller, so the result reflects this user's
    // role in the dashboard's tenant.
    final res = await client.functions.invoke('db-read',
        body: {'op': 'getMembership', 'args': {'tenant_id': dashboard.tenantId}});
    final data = res.data;
    final row = (data is Map && data['membership'] is Map)
        ? data['membership'] as Map
        : null;
    final role = row?['role'] as String?;
    return roleAtLeast(role, 'editor');
  } catch (_) {
    return false;
  }
});

/// True if the *current user* is an `owner` of ANY tenant. Owners are Bryzos
/// admins — they can create new organizations and edit data sources across
/// every org they belong to.
final isBryzosOwnerProvider = FutureProvider<bool>((ref) async {
  ref.watch(currentUserIdProvider); // React to login/logout
  final client = ref.watch(supabaseProvider);
  final uid = client.auth.currentUser?.id;
  if (uid == null) return false;
  try {
    // Route through `db-read` Edge Function (WAF-safe transport).
    final res = await client.functions.invoke('db-read',
        body: const {'op': 'isOwnerOfAnyTenant'});
    final data = res.data;
    return (data is Map && data['is_owner'] == true);
  } catch (_) {
    return false;
  }
});

final libraryProvider = FutureProvider<List<LibraryItem>>((ref) {
  // Re-fetch when the active tenant changes so we never show another
  // tenant's library items after a switch.
  ref.watch(activeTenantProvider);
  ref.watch(currentUserIdProvider); // React to login/logout
  return ref.watch(repoProvider).listLibrary();
});

final reportsProvider = FutureProvider<List<Report>>((ref) {
  // Re-fetch when the active tenant changes. RLS already filters server-side
  // (`tenant_id = current_tenant_id()`), but without this watch the cached
  // list from the previous tenant would persist after `switch-tenant`.
  ref.watch(activeTenantProvider);
  ref.watch(currentUserIdProvider); // React to login/logout
  return ref.watch(repoProvider).listReports();
});
