// Network Analytics — AI Report Builder API client.
//
// Thin wrappers around the AI Edge Functions:
//   - ai-check-library      → library-first semantic search
//   - ai-generate-query     → NL → CustomReportQueryV2 JSON
//
// All calls go through the Supabase client's `functions.invoke`, which
// attaches the current session JWT automatically. Tenant scoping is done
// via the `tenant_id` field in the request body (Edge Functions verify the
// caller is a member of that tenant before doing anything).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/supabase_repo.dart';

/// Recursively re-type a JSON tree so every nested Map is truly
/// `Map<String, dynamic>` and every List is `List<dynamic>`. The
/// Supabase Edge Functions client returns nested objects as
/// `Map<dynamic, dynamic>`, which silently breaks the strict
/// `whereType<Map<String, dynamic>>()` casts inside
/// CustomReportQueryV2.fromJson — meaning joins/columns/filters/etc.
/// all end up empty and the preview panel renders nothing.
Object? _deepNormalize(Object? v) {
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) e.key.toString(): _deepNormalize(e.value),
    };
  }
  if (v is List) {
    return v.map(_deepNormalize).toList();
  }
  return v;
}

Map<String, dynamic>? _asMap(Object? v) {
  final n = _deepNormalize(v);
  return n is Map<String, dynamic> ? n : null;
}

class LibraryMatch {
  final String kind; // 'widget' | 'report'
  final String id;
  final String name;
  final String description;
  final double similarity;

  const LibraryMatch({
    required this.kind,
    required this.id,
    required this.name,
    required this.description,
    required this.similarity,
  });

  static LibraryMatch fromJson(Map<String, dynamic> j) => LibraryMatch(
        kind: (j['kind'] ?? '').toString(),
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        similarity: (j['similarity'] is num)
            ? (j['similarity'] as num).toDouble()
            : 0.0,
      );
}

class LibraryCheckResult {
  final List<LibraryMatch> matches;
  final String? skippedReason;
  const LibraryCheckResult({required this.matches, this.skippedReason});
}

class GenerateResult {
  final bool ok;
  final Map<String, dynamic>? query; // CustomReportQueryV2 JSON (null on clarification/error)
  final bool needsClarification;
  final List<String> questions;
  final String? providerUsed;
  final String? modelUsed;
  final int? inputTokens;
  final int? outputTokens;
  final int? latencyMs;
  final double? costUsd;
  final String sessionId;
  final String? errorCode;
  final String? errorMessage;
  final List<Map<String, dynamic>> attempts;

  const GenerateResult({
    required this.ok,
    this.query,
    this.needsClarification = false,
    this.questions = const [],
    this.providerUsed,
    this.modelUsed,
    this.inputTokens,
    this.outputTokens,
    this.latencyMs,
    this.costUsd,
    required this.sessionId,
    this.errorCode,
    this.errorMessage,
    this.attempts = const [],
  });
}

class AiApi {
  final SupabaseRepo repo;
  AiApi(this.repo);

  Future<LibraryCheckResult> checkLibrary({
    required String prompt,
    required String tenantId,
    int limit = 3,
    double threshold = 0.7,
  }) async {
    final res = await repo.client.functions.invoke(
      'ai-check-library',
      body: {
        'prompt': prompt,
        'tenant_id': tenantId,
        'limit': limit,
        'threshold': threshold,
      },
    );
    final data = _asMap(res.data) ?? const <String, dynamic>{};
    final rawMatches = (data['matches'] as List?) ?? const [];
    final matches = rawMatches
        .whereType<Map>()
        .map((m) => LibraryMatch.fromJson(
              (_asMap(m) ?? <String, dynamic>{}),
            ))
        .toList();
    return LibraryCheckResult(
      matches: matches,
      skippedReason: data['skipped'] as String?,
    );
  }

  Future<GenerateResult> generateQuery({
    required String prompt,
    required String tenantId,
    required String sessionId,
    required int turnIndex,
    List<Map<String, dynamic>> history = const [],
    Map<String, dynamic>? currentQuery,
    String targetView = 'report',
  }) async {
    final res = await repo.client.functions.invoke(
      'ai-generate-query',
      body: {
        'prompt': prompt,
        'tenant_id': tenantId,
        'session_id': sessionId,
        'turn_index': turnIndex,
        'history': history,
        if (currentQuery != null) 'current_query': currentQuery,
        'target_view': targetView,
      },
    );
    final data = _asMap(res.data) ?? const <String, dynamic>{};
    final ok = data['ok'] == true;
    final needsClar = data['needs_clarification'] == true;
    final tokens = _asMap(data['tokens']);
    return GenerateResult(
      ok: ok,
      query: _asMap(data['query']),
      needsClarification: needsClar,
      questions: ((data['questions'] as List?) ?? const [])
          .map((q) => q.toString())
          .toList(),
      providerUsed: data['provider_used'] as String?,
      modelUsed: data['model_used'] as String?,
      inputTokens: tokens?['input'] as int?,
      outputTokens: tokens?['output'] as int?,
      latencyMs: data['latency_ms'] as int?,
      costUsd: (data['cost_usd'] is num)
          ? (data['cost_usd'] as num).toDouble()
          : null,
      sessionId:
          (data['session_id'] as String?) ?? sessionId,
      errorCode: data['error'] as String?,
      errorMessage: data['detail'] is String
          ? data['detail'] as String
          : (data['message'] as String?),
      attempts: ((data['attempts'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => _asMap(m) ?? <String, dynamic>{})
          .toList(),
    );
  }

  /// Fire-and-forget indexing after a save so the item shows up in future
  /// library-check searches. Non-blocking — errors are swallowed.
  Future<void> indexItem({
    required String kind, // 'widget' | 'report'
    required String id,
    required String tenantId,
  }) async {
    try {
      await repo.client.functions.invoke(
        'ai-index-item',
        body: {
          'kind': kind,
          'id': id,
          'tenant_id': tenantId,
        },
      );
    } catch (_) {
      // Swallow — indexing is best-effort.
    }
  }
}

final aiApiProvider = Provider<AiApi>((ref) {
  return AiApi(ref.watch(repoProvider));
});
