// Network Analytics — AI Report Builder state notifier.
//
// Owns the full state of one AI builder session:
//   - chat messages (user + system)
//   - undo/redo stack (depth 5) of generated CustomReportQueryV2 payloads
//   - persisted session id + turn index
//   - preview view mode toggle (report | widget)
//   - clarification / library-match state
//
// Persistence: writes to `ai_report_sessions` on every meaningful state
// change (best-effort; UI is optimistic and does not block on the write).

import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/supabase_repo.dart';
import 'ai_api.dart';

enum ChatRole { user, assistant, system }

class ChatMessage {
  final ChatRole role;
  final String content;
  final DateTime at;
  final String? providerUsed;
  final String? modelUsed;
  final int? latencyMs;
  final int? inputTokens;
  final int? outputTokens;
  final double? costUsd;
  // The actual query JSON this assistant message produced (null for user/system).
  // Used to inject the LLM's own prior outputs back into conversation history
  // so follow-up turns have full context of what was built.
  final Map<String, dynamic>? queryJson;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.at,
    this.providerUsed,
    this.modelUsed,
    this.latencyMs,
    this.inputTokens,
    this.outputTokens,
    this.costUsd,
    this.queryJson,
  });

  Map<String, dynamic> toJson() => {
        'role': role.name,
        'content': content,
        'at': at.toIso8601String(),
        if (providerUsed != null) 'provider_used': providerUsed,
        if (modelUsed != null) 'model_used': modelUsed,
        if (latencyMs != null) 'latency_ms': latencyMs,
        if (inputTokens != null) 'input_tokens': inputTokens,
        if (outputTokens != null) 'output_tokens': outputTokens,
        if (costUsd != null) 'cost_usd': costUsd,
        if (queryJson != null) 'query_json': queryJson,
      };

  static ChatMessage fromJson(Map<String, dynamic> j) => ChatMessage(
        role: ChatRole.values.firstWhere(
          (r) => r.name == (j['role'] as String?),
          orElse: () => ChatRole.system,
        ),
        content: (j['content'] ?? '').toString(),
        at: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.now(),
        providerUsed: j['provider_used'] as String?,
        modelUsed: j['model_used'] as String?,
        latencyMs: j['latency_ms'] as int?,
        inputTokens: j['input_tokens'] as int?,
        outputTokens: j['output_tokens'] as int?,
        costUsd: (j['cost_usd'] is num)
            ? (j['cost_usd'] as num).toDouble()
            : null,
        queryJson: j['query_json'] is Map
            ? Map<String, dynamic>.from(j['query_json'] as Map)
            : null,
      );
}

enum PreviewMode { report, widget }

class AiBuilderState {
  final String sessionId;
  final int turnIndex;
  final List<ChatMessage> messages;

  /// Undo stack: the most recent generated query is at the end. Depth capped
  /// at 5. `stackIndex` points to the *currently active* entry within the
  /// stack — moving it left is undo, right is redo.
  final List<Map<String, dynamic>> queryStack;
  final int stackIndex;

  final PreviewMode previewMode;
  final bool isGenerating;
  final bool isCheckingLibrary;
  final List<LibraryMatch> pendingLibraryMatches;
  final String? errorMessage;
  final bool bootstrapped; // has the user submitted anything yet

  /// The user-editable name for this report/widget. Auto-populated from
  /// primary_table on first AI generation (no chart type). Must be non-empty
  /// and not "Untitled" before saving is allowed.
  final String reportName;

  const AiBuilderState({
    required this.sessionId,
    this.turnIndex = 0,
    this.messages = const [],
    this.queryStack = const [],
    this.stackIndex = -1,
    this.previewMode = PreviewMode.report,
    this.isGenerating = false,
    this.isCheckingLibrary = false,
    this.pendingLibraryMatches = const [],
    this.errorMessage,
    this.bootstrapped = false,
    this.reportName = 'Untitled',
  });

  Map<String, dynamic>? get currentQuery =>
      (stackIndex >= 0 && stackIndex < queryStack.length)
          ? queryStack[stackIndex]
          : null;

  bool get canUndo => stackIndex > 0;
  bool get canRedo => stackIndex >= 0 && stackIndex < queryStack.length - 1;

  AiBuilderState copyWith({
    String? sessionId,
    int? turnIndex,
    List<ChatMessage>? messages,
    List<Map<String, dynamic>>? queryStack,
    int? stackIndex,
    PreviewMode? previewMode,
    bool? isGenerating,
    bool? isCheckingLibrary,
    List<LibraryMatch>? pendingLibraryMatches,
    Object? errorMessage = _sentinel,
    bool? bootstrapped,
    String? reportName,
  }) {
    return AiBuilderState(
      sessionId: sessionId ?? this.sessionId,
      turnIndex: turnIndex ?? this.turnIndex,
      messages: messages ?? this.messages,
      queryStack: queryStack ?? this.queryStack,
      stackIndex: stackIndex ?? this.stackIndex,
      previewMode: previewMode ?? this.previewMode,
      isGenerating: isGenerating ?? this.isGenerating,
      isCheckingLibrary: isCheckingLibrary ?? this.isCheckingLibrary,
      pendingLibraryMatches:
          pendingLibraryMatches ?? this.pendingLibraryMatches,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
      bootstrapped: bootstrapped ?? this.bootstrapped,
      reportName: reportName ?? this.reportName,
    );
  }

  static const _sentinel = Object();
}

class AiBuilderNotifier extends StateNotifier<AiBuilderState> {
  AiBuilderNotifier(this._ref)
      : super(AiBuilderState(sessionId: _uuid())) {
    // No-op: session is created lazily on first send so we don't spam DB.
  }

  final Ref _ref;
  static const int _undoDepth = 5;

  static String _uuid() {
    // Simple RFC4122 v4 without dep on `uuid` package (project doesn't ship it).
    final r = math.Random.secure();
    List<int> bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String h(int b) => b.toRadixString(16).padLeft(2, '0');
    return '${h(bytes[0])}${h(bytes[1])}${h(bytes[2])}${h(bytes[3])}-'
        '${h(bytes[4])}${h(bytes[5])}-'
        '${h(bytes[6])}${h(bytes[7])}-'
        '${h(bytes[8])}${h(bytes[9])}-'
        '${h(bytes[10])}${h(bytes[11])}${h(bytes[12])}${h(bytes[13])}${h(bytes[14])}${h(bytes[15])}';
  }

  SupabaseClient get _client => _ref.read(supabaseProvider);
  AiApi get _api => _ref.read(aiApiProvider);

  String? get _tenantId =>
      _client.auth.currentUser?.appMetadata['active_tenant_id'] as String?;

  // ── Public actions ─────────────────────────────────────────────────────────

  void setReportName(String name) {
    state = state.copyWith(reportName: name);
    _persist();
  }

  void setPreviewMode(PreviewMode mode) {
    if (state.previewMode == mode) return;
    state = state.copyWith(previewMode: mode);
    _persist();
  }

  void reset() {
    state = AiBuilderState(sessionId: _uuid(), reportName: 'Untitled');
  }

  void undo() {
    if (!state.canUndo) return;
    state = state.copyWith(stackIndex: state.stackIndex - 1);
    _persist();
  }

  void redo() {
    if (!state.canRedo) return;
    state = state.copyWith(stackIndex: state.stackIndex + 1);
    _persist();
  }

  /// Discard the pending library-match list without picking one — proceeds
  /// to the actual generation.
  Future<void> proceedFromLibraryPrompt(String prompt) async {
    state = state.copyWith(pendingLibraryMatches: const []);
    await _generate(prompt);
  }

  /// Top-level submit for a new user message. Runs library-check first on
  /// the very first turn; subsequent turns skip the library check.
  Future<void> submit(String rawPrompt) async {
    final prompt = rawPrompt.trim();
    if (prompt.isEmpty) return;
    final tenantId = _tenantId;
    if (tenantId == null) {
      state = state.copyWith(errorMessage: 'No active tenant.');
      return;
    }

    // Append user message immediately.
    final userMsg = ChatMessage(
      role: ChatRole.user,
      content: prompt,
      at: DateTime.now(),
    );
    state = state.copyWith(
      messages: [...state.messages, userMsg],
      bootstrapped: true,
      errorMessage: null,
      pendingLibraryMatches: const [],
    );

    final isFirstTurn = state.turnIndex == 0;

    if (isFirstTurn) {
      state = state.copyWith(isCheckingLibrary: true);
      try {
        final res = await _api.checkLibrary(
          prompt: prompt,
          tenantId: tenantId,
          limit: 5,
          threshold: 0.40,
        );
        if (res.matches.isNotEmpty) {
          final assistantMsg = ChatMessage(
            role: ChatRole.assistant,
            content:
                "I found a few things in your library that might already do this. Do any of these work?",
            at: DateTime.now(),
          );
          state = state.copyWith(
            isCheckingLibrary: false,
            pendingLibraryMatches: res.matches,
            messages: [...state.messages, assistantMsg],
          );
          _persist();
          return;
        }
      } catch (e) {
        // Best-effort — surface diagnostic for Bryzos-only visibility.
        final diag = ChatMessage(
          role: ChatRole.system,
          content: '[library-check failed: $e]',
          at: DateTime.now(),
        );
        state = state.copyWith(
          messages: [...state.messages, diag],
        );
      }
      state = state.copyWith(isCheckingLibrary: false);
    }

    await _generate(prompt);
  }

  Future<void> _generate(String prompt) async {
    final tenantId = _tenantId;
    if (tenantId == null) {
      state = state.copyWith(errorMessage: 'No active tenant.');
      return;
    }
    state = state.copyWith(isGenerating: true, errorMessage: null);

    // Compose history for the LLM — last 20 non-system messages.
    // For assistant turns that produced a query, we embed the actual query
    // JSON inline so the LLM sees exactly what it built and can refine it
    // precisely. Without this, it only sees a vague human summary and
    // essentially starts from scratch on every follow-up turn.
    final history = state.messages
        .where((m) => m.role != ChatRole.system)
        .map((m) {
          if (m.role == ChatRole.assistant && m.queryJson != null) {
            // Embed the query JSON so the LLM knows what it actually produced.
            final json = _prettyJson(m.queryJson!);
            return {
              'role': 'assistant',
              'content': '${m.content}\n\nQuery I built:\n```json\n$json\n```',
            };
          }
          return {
            'role': m.role == ChatRole.user ? 'user' : 'assistant',
            'content': m.content,
          };
        })
        .toList()
        .cast<Map<String, dynamic>>();
    // Keep most recent 20 turns — older turns are still covered by current_query.
    final trimmedHistory = history.length > 20
        ? history.sublist(history.length - 20)
        : history;

    try {
      final result = await _api.generateQuery(
        prompt: prompt,
        tenantId: tenantId,
        sessionId: state.sessionId,
        turnIndex: state.turnIndex,
        history: trimmedHistory,
        currentQuery: state.currentQuery,
        targetView: state.previewMode == PreviewMode.widget ? 'widget' : 'report',
      );

      if (result.needsClarification) {
        final qText = result.questions.isEmpty
            ? "Could you share a bit more detail?"
            : result.questions.map((q) => "• $q").join('\n');
        final msg = ChatMessage(
          role: ChatRole.assistant,
          content: qText,
          at: DateTime.now(),
          providerUsed: result.providerUsed,
          modelUsed: result.modelUsed,
          latencyMs: result.latencyMs,
          inputTokens: result.inputTokens,
          outputTokens: result.outputTokens,
          costUsd: result.costUsd,
        );
        state = state.copyWith(
          isGenerating: false,
          sessionId: result.sessionId,
          turnIndex: state.turnIndex + 1,
          messages: [...state.messages, msg],
        );
        _persist();
        return;
      }

      if (result.ok && result.query != null) {
        // Push onto the undo stack (truncate any redo tail, then trim to depth).
        final base = state.queryStack.take(state.stackIndex + 1).toList();
        base.add(result.query!);
        List<Map<String, dynamic>> trimmed = base;
        int newIndex = base.length - 1;
        if (base.length > _undoDepth) {
          trimmed = base.sublist(base.length - _undoDepth);
          newIndex = trimmed.length - 1;
        }
        final msg = ChatMessage(
          role: ChatRole.assistant,
          content: _summariseQuery(result.query!),
          at: DateTime.now(),
          providerUsed: result.providerUsed,
          modelUsed: result.modelUsed,
          latencyMs: result.latencyMs,
          inputTokens: result.inputTokens,
          outputTokens: result.outputTokens,
          costUsd: result.costUsd,
          queryJson: result.query, // persist the actual query for history enrichment
        );
        // Auto-name from primary_table on first generation only.
        // Never includes chart type per design rule.
        final autoName = state.reportName == 'Untitled'
            ? _autoNameFromQuery(result.query!)
            : state.reportName;
        state = state.copyWith(
          isGenerating: false,
          sessionId: result.sessionId,
          turnIndex: state.turnIndex + 1,
          messages: [...state.messages, msg],
          queryStack: trimmed,
          stackIndex: newIndex,
          reportName: autoName,
        );
        _persist();
        return;
      }

      // Failure path.
      final err = result.errorMessage ?? result.errorCode ?? 'Generation failed.';
      state = state.copyWith(
        isGenerating: false,
        sessionId: result.sessionId,
        turnIndex: state.turnIndex + 1,
        messages: [
          ...state.messages,
          ChatMessage(
            role: ChatRole.assistant,
            content: "I couldn't build that. $err",
            at: DateTime.now(),
          ),
        ],
        errorMessage: err,
      );
      _persist();
    } catch (e) {
      state = state.copyWith(
        isGenerating: false,
        messages: [
          ...state.messages,
          ChatMessage(
            role: ChatRole.assistant,
            content: "Something went wrong reaching the server.",
            at: DateTime.now(),
          ),
        ],
        errorMessage: e.toString(),
      );
    }
  }

  /// Produces a compact JSON string of a query map.
  /// Used to embed the LLM's previous output into conversation history.
  String _prettyJson(Map<String, dynamic> q) {
    try {
      return jsonEncode(q);
    } catch (_) {
      return q.toString();
    }
  }

  /// Auto-generates a human-readable name from the query's primary_table.
  /// Uses only the table name — never the chart type per design rules.
  /// e.g. "rds_user_purchase_order" → "User Purchase Order"
  String _autoNameFromQuery(Map<String, dynamic> q) {
    final raw = (q['primary_table'] ?? '').toString();
    if (raw.isEmpty) return 'Untitled';
    // Strip common rds_ prefix, then title-case each word.
    final stripped = raw.startsWith('rds_') ? raw.substring(4) : raw;
    return stripped
        .split('_')
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }

  String _summariseQuery(Map<String, dynamic> q) {
    final table = q['primary_table'] ?? 'the data source';
    final viz = (q['viz'] is Map)
        ? ((q['viz'] as Map)['chart_type'] ?? 'table')
        : 'table';
    final cols = (q['columns'] is List) ? (q['columns'] as List).length : 0;
    final aggs = (q['aggregates'] is List) ? (q['aggregates'] as List).length : 0;
    final filters =
        (q['filters'] is List) ? (q['filters'] as List).length : 0;
    return "Built a $viz on $table — $cols column${cols == 1 ? '' : 's'}, "
        "$aggs aggregate${aggs == 1 ? '' : 's'}, "
        "$filters filter${filters == 1 ? '' : 's'}.";
  }

  // ── Persistence (best-effort) ─────────────────────────────────────────────

  Timer? _debounce;
  void _persist() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _flush);
  }

  Future<void> _flush() async {
    final tenantId = _tenantId;
    final userId = _client.auth.currentUser?.id;
    if (tenantId == null || userId == null) return;
    try {
      final payload = {
        'id': state.sessionId,
        'tenant_id': tenantId,
        'user_id': userId,
        'messages': state.messages.map((m) => m.toJson()).toList(),
        'current_query': state.currentQuery,
        'query_history': state.queryStack,
        'view_mode': state.previewMode.name,
        'status': 'active',
        'last_active_at': DateTime.now().toIso8601String(),
      };
      await _client.from('ai_report_sessions').upsert(payload);
    } catch (_) {
      // Persistence is best-effort — don't disturb the UI.
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final aiBuilderProvider =
    StateNotifierProvider.autoDispose<AiBuilderNotifier, AiBuilderState>(
  (ref) => AiBuilderNotifier(ref),
);
