// AI Context Objective (ACO) editor — Bryzos-only, global scope.
//
// A single always-injected domain document that every LLM used by the AI
// Report Builder reads before it sees the user's prompt. End users have
// zero visibility into this content; only @bryzos.com staff can view or
// edit it.
//
// UX model:
//   * Feels like ONE living document — the editor shows the current
//     active version, always.
//   * Every save writes a NEW row (trigger auto-versions + auto-activates
//     the new one, deactivating the old). Full history is preserved but
//     the user isn't forced to think in terms of versions.
//   * An "ⓘ" icon next to the title reveals the last N changes on hover:
//     who / when / notes. A "View older versions" link inside that popover
//     opens a modal for full history + one-click restore.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/supabase_repo.dart' show supabaseProvider;
import '../../design/theme.dart';
import '../../design/optics_card.dart';
import '../../shared/secure_error.dart'
    show isBryzosUser, showSecureErrorSnackBar;

// ---------------------------------------------------------------------------
// Data providers
// ---------------------------------------------------------------------------

class _AcoRow {
  final String id;
  final String scope;
  final int version;
  final String content;
  final int? tokenEstimate;
  final DateTime createdAt;
  final String? createdByEmail;
  final String? notes;
  final bool isActive;

  _AcoRow({
    required this.id,
    required this.scope,
    required this.version,
    required this.content,
    required this.tokenEstimate,
    required this.createdAt,
    required this.createdByEmail,
    required this.notes,
    required this.isActive,
  });

  factory _AcoRow.fromMap(Map<String, dynamic> m) => _AcoRow(
        id: m['id'] as String,
        scope: (m['scope'] as String?) ?? 'global',
        version: (m['version'] as num).toInt(),
        content: (m['content'] as String?) ?? '',
        tokenEstimate: (m['token_estimate'] as num?)?.toInt(),
        createdAt:
            DateTime.tryParse(m['created_at']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
        createdByEmail: m['created_by_email'] as String?,
        notes: m['notes'] as String?,
        isActive: (m['is_active'] as bool?) ?? false,
      );
}

/// Loads the currently active ACO row for the given scope.
final _activeAcoProvider =
    FutureProvider.family<_AcoRow?, String>((ref, scope) async {
  final client = ref.watch(supabaseProvider);
  final res = await client
      .from('ai_context_objective')
      .select()
      .eq('scope', scope)
      .eq('is_active', true)
      .order('version', ascending: false)
      .limit(1)
      .maybeSingle();
  if (res == null) return null;
  return _AcoRow.fromMap(Map<String, dynamic>.from(res));
});

/// Loads recent history rows (newest first) for the tooltip / modal.
final _acoHistoryProvider =
    FutureProvider.family<List<_AcoRow>, String>((ref, scope) async {
  final client = ref.watch(supabaseProvider);
  final res = await client
      .from('ai_context_objective')
      .select()
      .eq('scope', scope)
      .order('version', ascending: false)
      .limit(50);
  return (res as List)
      .map((r) => _AcoRow.fromMap(Map<String, dynamic>.from(r)))
      .toList();
});

// ---------------------------------------------------------------------------
// Top-level section — drop this into the Settings screen for Bryzos users.
// ---------------------------------------------------------------------------

class AiContextObjectiveSection extends ConsumerWidget {
  const AiContextObjectiveSection({super.key, this.scope = 'global'});

  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Gate: Bryzos-only. Non-Bryzos users should never even render this.
    if (!isBryzosUser(ref)) return const SizedBox.shrink();

    final activeAsync = ref.watch(_activeAcoProvider(scope));

    return OpticsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(scope: scope),
          const SizedBox(height: OpticsSpacing.md),
          activeAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(
              'Error loading AI Context Objective: $e',
              style: OpticsTextStyles.bodySm
                  .copyWith(color: OpticsColors.danger),
            ),
            data: (row) => _Editor(scope: scope, active: row),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header — title, description, and the ⓘ tooltip revealing recent changes.
// ---------------------------------------------------------------------------

class _Header extends ConsumerWidget {
  const _Header({required this.scope});
  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'AI CONTEXT OBJECTIVE',
                    style: TextStyle(
                      fontFamily: 'Syncopate',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: OpticsColors.textPrimary,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _HistoryHoverIcon(scope: scope),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Silent domain context injected into every AI Report Builder '
                'request. Every LLM (DeepSeek, Gemini, OpenAI, etc.) reads this '
                'before the user\'s prompt. End users never see it.',
                style: TextStyle(
                  fontSize: 12,
                  color: OpticsColors.textMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// ⓘ Hover icon — click to open a popover with the last 5 changes + a link
// to the full history modal.
// ---------------------------------------------------------------------------

class _HistoryHoverIcon extends ConsumerWidget {
  const _HistoryHoverIcon({required this.scope});
  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _HistoryPopoverAnchor(scope: scope);
  }
}

class _HistoryPopoverAnchor extends StatefulWidget {
  const _HistoryPopoverAnchor({required this.scope});
  final String scope;

  @override
  State<_HistoryPopoverAnchor> createState() => _HistoryPopoverAnchorState();
}

class _HistoryPopoverAnchorState extends State<_HistoryPopoverAnchor> {
  final _menuKey = GlobalKey();

  void _showMenu() async {
    final RenderBox button =
        _menuKey.currentContext!.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final Offset offset = button.localToGlobal(
      Offset(0, button.size.height + 4),
      ancestor: overlay,
    );

    await showMenu<void>(
      context: context,
      color: OpticsColors.surfaceElevated,
      elevation: 8,
      constraints: const BoxConstraints(maxWidth: 420, minWidth: 340),
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy,
        overlay.size.width - offset.dx - button.size.width,
        overlay.size.height - offset.dy,
      ),
      items: [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _RecentChangesPanel(scope: widget.scope),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: _menuKey,
        onTap: _showMenu,
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: OpticsColors.surfaceElevated,
            shape: BoxShape.circle,
            border: Border.all(color: OpticsColors.border),
          ),
          child: const Icon(
            Icons.info_outline,
            size: 12,
            color: OpticsColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _RecentChangesPanel extends ConsumerWidget {
  const _RecentChangesPanel({required this.scope});
  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_acoHistoryProvider(scope));
    return Container(
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 420, minWidth: 340),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'RECENT CHANGES',
            style: TextStyle(
              fontFamily: 'Syncopate',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: OpticsColors.textPrimary,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          async.when(
            loading: () => const SizedBox(
              height: 24,
              child: Center(
                child: SizedBox(
                  height: 14,
                  width: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (e, _) => Text(
              'Could not load history: $e',
              style: OpticsTextStyles.bodySm
                  .copyWith(color: OpticsColors.danger),
            ),
            data: (rows) {
              if (rows.isEmpty) {
                return const Text('No history yet.',
                    style: OpticsTextStyles.bodySm);
              }
              final recent = rows.take(5).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in recent) _HistoryRow(row: r),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).pop();
                      showDialog(
                        context: context,
                        builder: (_) => _FullHistoryDialog(scope: scope),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        'View older versions →',
                        style: TextStyle(
                          fontSize: 12,
                          color: OpticsColors.accentCyan,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.row});
  final _AcoRow row;

  String _fmt(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: row.isActive
                      ? OpticsColors.accentCyan.withValues(alpha: 0.15)
                      : OpticsColors.surface,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: row.isActive
                        ? OpticsColors.accentCyan
                        : OpticsColors.border,
                  ),
                ),
                child: Text(
                  'v${row.version}${row.isActive ? ' · ACTIVE' : ''}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: row.isActive
                        ? OpticsColors.accentCyan
                        : OpticsColors.textSecondary,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _fmt(row.createdAt),
                style: const TextStyle(
                  fontSize: 11,
                  color: OpticsColors.textMuted,
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  row.createdByEmail ?? 'unknown',
                  style: const TextStyle(
                    fontSize: 11,
                    color: OpticsColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if ((row.notes ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              row.notes!,
              style: const TextStyle(
                fontSize: 11,
                color: OpticsColors.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Full history modal — full list with content preview + restore.
// ---------------------------------------------------------------------------

class _FullHistoryDialog extends ConsumerWidget {
  const _FullHistoryDialog({required this.scope});
  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_acoHistoryProvider(scope));
    return Dialog(
      backgroundColor: OpticsColors.surface,
      surfaceTintColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'AI CONTEXT OBJECTIVE — VERSION HISTORY',
                    style: OpticsTextStyles.headingLg,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Text('Error: $e',
                      style: TextStyle(color: OpticsColors.danger)),
                  data: (rows) => ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(
                        color: OpticsColors.border, height: 20),
                    itemBuilder: (_, i) => _FullHistoryItem(
                      row: rows[i],
                      scope: scope,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FullHistoryItem extends ConsumerStatefulWidget {
  const _FullHistoryItem({required this.row, required this.scope});
  final _AcoRow row;
  final String scope;

  @override
  ConsumerState<_FullHistoryItem> createState() => _FullHistoryItemState();
}

class _FullHistoryItemState extends ConsumerState<_FullHistoryItem> {
  bool _expanded = false;
  bool _restoring = false;

  Future<void> _restore() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surface,
        title: const Text('Restore this version?'),
        content: Text(
          'This will make v${widget.row.version} the active AI Context '
          'Objective. A new version will be recorded pointing to this content. '
          'The current active version stays in history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _restoring = true);
    try {
      final client = ref.read(supabaseProvider);
      final uid = client.auth.currentUser?.id;
      final email = client.auth.currentUser?.email;
      await client.from('ai_context_objective').insert({
        'scope': widget.scope,
        'content': widget.row.content,
        'is_active': true,
        'created_by': uid,
        'created_by_email': email,
        'notes': 'Restored from v${widget.row.version}',
        'token_estimate':
            (widget.row.content.length / 4).round(), // rough token estimate
      });
      ref.invalidate(_activeAcoProvider(widget.scope));
      ref.invalidate(_acoHistoryProvider(widget.scope));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Restored v${widget.row.version} as new active version.'),
            backgroundColor: OpticsColors.accentGreen,
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) showSecureErrorSnackBar(context, ref, 'Restore failed.', e);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: r.isActive
                    ? OpticsColors.accentCyan.withValues(alpha: 0.15)
                    : OpticsColors.surfaceElevated,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: r.isActive
                      ? OpticsColors.accentCyan
                      : OpticsColors.border,
                ),
              ),
              child: Text(
                'v${r.version}${r.isActive ? ' · ACTIVE' : ''}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: r.isActive
                      ? OpticsColors.accentCyan
                      : OpticsColors.textSecondary,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${r.createdAt.toLocal()} · ${r.createdByEmail ?? 'unknown'}',
                style: const TextStyle(
                    fontSize: 12, color: OpticsColors.textSecondary),
              ),
            ),
            if (!r.isActive)
              _restoring
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton.icon(
                      onPressed: _restore,
                      icon: const Icon(Icons.restore, size: 14),
                      label: const Text('Restore'),
                    ),
            IconButton(
              icon: Icon(_expanded
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down),
              onPressed: () => setState(() => _expanded = !_expanded),
              tooltip: _expanded ? 'Collapse' : 'Show content',
            ),
          ],
        ),
        if ((r.notes ?? '').trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 4),
            child: Text(
              r.notes!,
              style: const TextStyle(
                fontSize: 12,
                color: OpticsColors.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: OpticsColors.surfaceElevated,
                border: Border.all(color: OpticsColors.border),
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
              ),
              child: SelectableText(
                r.content,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: OpticsColors.textPrimary,
                  height: 1.4,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Editor — one big TextField showing the current active content.
// Save creates a new row (auto-activated).
// ---------------------------------------------------------------------------

class _Editor extends ConsumerStatefulWidget {
  const _Editor({required this.scope, required this.active});
  final String scope;
  final _AcoRow? active;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final TextEditingController _content;
  late final TextEditingController _notes;
  late String _initialContent;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initialContent = widget.active?.content ?? '';
    _content = TextEditingController(text: _initialContent);
    _notes = TextEditingController();
  }

  @override
  void didUpdateWidget(covariant _Editor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the active row changes underneath us (e.g. after a restore from the
    // modal), and the user hasn't touched the editor, sync the text.
    final newContent = widget.active?.content ?? '';
    if (newContent != _initialContent && _content.text == _initialContent) {
      _initialContent = newContent;
      _content.text = newContent;
    }
  }

  @override
  void dispose() {
    _content.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _dirty => _content.text != _initialContent;

  Future<void> _save() async {
    if (!_dirty) return;
    setState(() => _saving = true);
    try {
      final client = ref.read(supabaseProvider);
      final uid = client.auth.currentUser?.id;
      final email = client.auth.currentUser?.email;
      final newContent = _content.text;
      // Rough token estimate: ~4 chars per token — good enough for a budget
      // indicator; not used for billing.
      final tokenEstimate = (newContent.length / 4).round();
      await client.from('ai_context_objective').insert({
        'scope': widget.scope,
        'content': newContent,
        'is_active': true,
        'created_by': uid,
        'created_by_email': email,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        'token_estimate': tokenEstimate,
      });
      _initialContent = newContent;
      _notes.clear();
      ref.invalidate(_activeAcoProvider(widget.scope));
      ref.invalidate(_acoHistoryProvider(widget.scope));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI Context Objective saved as new active version.'),
            backgroundColor: OpticsColors.accentGreen,
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) showSecureErrorSnackBar(context, ref, 'Save failed.', e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _revert() {
    _content.text = _initialContent;
    _notes.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final charCount = _content.text.length;
    final tokenEstimate = (charCount / 4).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Meta row: current version + char/token count.
        Row(
          children: [
            if (active != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: OpticsColors.accentCyan.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: OpticsColors.accentCyan),
                ),
                child: Text(
                  'v${active.version} · ACTIVE',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: OpticsColors.accentCyan,
                    letterSpacing: 0.8,
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: OpticsColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: OpticsColors.border),
                ),
                child: const Text(
                  'NO ACTIVE VERSION',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: OpticsColors.textMuted,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            const SizedBox(width: 12),
            Text(
              '$charCount chars · ~$tokenEstimate tokens',
              style: const TextStyle(
                fontSize: 11,
                color: OpticsColors.textMuted,
              ),
            ),
            const Spacer(),
            if (_dirty) ...[
              TextButton(
                onPressed: _saving ? null : _revert,
                child: const Text('Discard changes'),
              ),
              const SizedBox(width: 8),
            ],
            ElevatedButton.icon(
              onPressed: (!_dirty || _saving) ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_dirty ? 'Save changes' : 'Saved'),
              style: ElevatedButton.styleFrom(
                backgroundColor: OpticsColors.accentCyan,
                foregroundColor: const Color(0xFF0A0A0F),
                disabledBackgroundColor: OpticsColors.surfaceElevated,
                disabledForegroundColor: OpticsColors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: OpticsSpacing.md),
        // Content editor.
        Container(
          decoration: BoxDecoration(
            color: OpticsColors.surfaceElevated,
            border: Border.all(color: OpticsColors.border),
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
          ),
          child: TextField(
            controller: _content,
            onChanged: (_) => setState(() {}),
            maxLines: null,
            minLines: 20,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.5,
              color: OpticsColors.textPrimary,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              enabledBorder: InputBorder.none,
              contentPadding: EdgeInsets.all(14),
              hintText:
                  'Write the domain context here (markdown). This is what every LLM sees before the user\'s prompt…',
              hintStyle: TextStyle(color: OpticsColors.textMuted),
            ),
          ),
        ),
        const SizedBox(height: OpticsSpacing.md),
        // Notes for this change.
        const Text(
          'Change notes (optional — shown in history)',
          style: OpticsTextStyles.bodySm,
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: const InputDecoration(
            isDense: true,
            hintText:
                'e.g. "Added quote-list canonical pattern; clarified screen_name is seller-only."',
          ),
        ),
      ],
    );
  }
}
