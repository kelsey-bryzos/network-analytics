// Share Dashboard 2.0 dialog.
//
// Replaces the previous single-email prompt. Provides:
//   • Email input at the top (accepts non-platform emails — sends invites)
//   • Multi-select user picker showing name · email · tenant(s) · role(s)
//     with rows for existing shares shown DISABLED with a tooltip.
//   • "Manage Access" section listing every current share with revoke toggle.
//
// Backend contracts:
//   • list_shareable_users(p_dashboard_id) RPC
//   • list_dashboard_shares(p_dashboard_id) RPC
//   • share-dashboard Edge Function (batch payload: targets[])
//   • revoke-dashboard-share Edge Function

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/supabase_repo.dart';
import '../../design/theme.dart';
import '../../shared/secure_error.dart';

Future<void> showShareDashboardDialog(
  BuildContext context,
  WidgetRef ref, {
  required String dashboardId,
  required String dashboardName,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _ShareDialog(
      dashboardId: dashboardId,
      dashboardName: dashboardName,
    ),
  );
}

class _ShareDialog extends ConsumerStatefulWidget {
  final String dashboardId;
  final String dashboardName;
  const _ShareDialog({required this.dashboardId, required this.dashboardName});

  @override
  ConsumerState<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends ConsumerState<_ShareDialog> {
  final _emailController = TextEditingController();
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _candidates = const [];
  List<Map<String, dynamic>> _shares = const [];
  bool _loadingCandidates = true;
  bool _loadingShares = true;
  bool _submitting = false;
  bool _showManage = false;
  final Set<String> _selectedUserIds = {};

  String? _candidatesError;
  String? _sharesError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    try {
      final rows = await repo.listShareableUsers(widget.dashboardId);
      if (!mounted) return;
      setState(() {
        _candidates = rows;
        _loadingCandidates = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _candidatesError = 'Could not load users.';
        _loadingCandidates = false;
      });
    }
    try {
      final rows = await repo.listDashboardShares(widget.dashboardId);
      if (!mounted) return;
      setState(() {
        _shares = rows;
        _loadingShares = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sharesError = 'Could not load current shares.';
        _loadingShares = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredCandidates {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return _candidates;
    return _candidates.where((u) {
      final name = (u['display_name'] ?? '').toString().toLowerCase();
      final email = (u['email'] ?? '').toString().toLowerCase();
      final memberships = (u['memberships'] as List?) ?? const [];
      final tenantHit = memberships.any((m) {
        final mm = (m as Map).cast<String, dynamic>();
        return (mm['tenant_name'] ?? '').toString().toLowerCase().contains(q);
      });
      return name.contains(q) || email.contains(q) || tenantHit;
    }).toList();
  }

  Future<void> _submit() async {
    final typed = _emailController.text.trim().toLowerCase();
    final targets = <Map<String, String>>[];
    for (final uid in _selectedUserIds) {
      targets.add({'user_id': uid});
    }
    if (typed.isNotEmpty && typed.contains('@')) {
      targets.add({'email': typed});
    }
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Pick at least one user or type an email to share with.',
          style: TextStyle(color: Colors.white),
        ),
      ));
      return;
    }
    setState(() => _submitting = true);
    try {
      final result = await ref.read(repoProvider).shareDashboardBatch(
            dashboardId: widget.dashboardId,
            targets: targets,
          );
      final List<dynamic> rows = (result['results'] as List?) ?? const [];
      final ok = rows.where((r) => (r as Map)['ok'] == true).length;
      final fails = rows.where((r) => (r as Map)['ok'] != true).toList();
      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context);
      if (fails.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text(
            'Shared with $ok ${ok == 1 ? "person" : "people"}.',
            style: const TextStyle(color: Colors.white),
          ),
        ));
        if (mounted) Navigator.of(context).pop();
        return;
      }
      // Show the first failure inline; keep the dialog open for retry.
      final firstFail = (fails.first as Map).cast<String, dynamic>();
      final errMsg = (firstFail['error'] ?? 'share failed').toString();
      messenger.showSnackBar(SnackBar(
        content: Text(
          ok > 0
              ? 'Shared with $ok; ${fails.length} failed. First error: $errMsg'
              : 'Could not share: $errMsg',
          style: const TextStyle(color: Colors.white),
        ),
      ));
      if (ok > 0) {
        // Refresh the manage-access list so they can see what landed.
        _loadingShares = true;
        await _load();
      }
    } catch (e) {
      if (mounted) showSecureErrorSnackBar(context, ref, 'Failed to share.', e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _revoke(String shareId) async {
    setState(() => _submitting = true);
    try {
      await ref.read(repoProvider).revokeDashboardShare(shareId);
      // Refresh shares + candidates so the picker re-enables that user.
      _loadingShares = true;
      _loadingCandidates = true;
      await _load();
    } catch (e) {
      if (mounted) showSecureErrorSnackBar(context, ref, 'Failed to revoke share.', e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    final dialogWidth = mq.width.clamp(360.0, 640.0);
    final dialogMaxHeight = mq.height * 0.82;

    return Dialog(
      backgroundColor: OpticsColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: dialogWidth, maxHeight: dialogMaxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                'SHARE "${widget.dashboardName.toUpperCase()}"',
                style: OpticsTextStyles.headingMd,
              ),
              const SizedBox(height: 4),
              const Text(
                'Pick existing users below or enter an email to send a Guest invite.',
                style: TextStyle(color: OpticsColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),

              // Email input
              TextField(
                controller: _emailController,
                style: const TextStyle(color: OpticsColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'name@example.com',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.emailAddress,
              ),

              const SizedBox(height: 14),

              // Search
              TextField(
                controller: _searchController,
                style: const TextStyle(color: OpticsColors.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'Search by name, email, or tenant…',
                  prefixIcon: Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),

              const SizedBox(height: 8),

              // Picker list
              Flexible(
                child: _PickerList(
                  loading: _loadingCandidates,
                  error: _candidatesError,
                  rows: _filteredCandidates,
                  selectedIds: _selectedUserIds,
                  onToggle: (id, on) {
                    setState(() {
                      if (on) {
                        _selectedUserIds.add(id);
                      } else {
                        _selectedUserIds.remove(id);
                      }
                    });
                  },
                ),
              ),

              const SizedBox(height: 10),

              // Manage Access toggle
              InkWell(
                onTap: () => setState(() => _showManage = !_showManage),
                child: Row(
                  children: [
                    Icon(
                      _showManage ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: OpticsColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'MANAGE ACCESS (${_shares.length})',
                      style: OpticsTextStyles.headingMd.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),

              if (_showManage) ...[
                const SizedBox(height: 6),
                _ManageAccessList(
                  loading: _loadingShares,
                  error: _sharesError,
                  shares: _shares,
                  busy: _submitting,
                  onRevoke: _revoke,
                ),
              ],

              const SizedBox(height: 12),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _shareButtonLabel(),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _shareButtonLabel() {
    final picked = _selectedUserIds.length;
    final hasEmail = _emailController.text.trim().contains('@');
    final total = picked + (hasEmail ? 1 : 0);
    if (total <= 0) return 'Share';
    return 'Share with $total';
  }
}

class _PickerList extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> rows;
  final Set<String> selectedIds;
  final void Function(String userId, bool on) onToggle;
  const _PickerList({
    required this.loading,
    required this.error,
    required this.rows,
    required this.selectedIds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(error!,
            style: const TextStyle(color: OpticsColors.textSecondary, fontSize: 12)),
      );
    }
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Text(
          'No users match your search.',
          style: TextStyle(color: OpticsColors.textSecondary, fontSize: 12),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x1AFFFFFF)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(
          color: Color(0x14FFFFFF),
          height: 1,
        ),
        itemBuilder: (ctx, i) {
          final u = rows[i];
          final uid = (u['user_id'] ?? '').toString();
          final name = (u['display_name'] ?? '').toString();
          final email = (u['email'] ?? '').toString();
          final memberships = (u['memberships'] as List?) ?? const [];
          final alreadyShared = u['is_already_shared'] == true;
          final selected = selectedIds.contains(uid);

          final tenantChips = <Widget>[];
          for (final m in memberships) {
            final mm = (m as Map).cast<String, dynamic>();
            final tenant = (mm['tenant_name'] ?? '').toString();
            final role = (mm['role'] ?? '').toString();
            tenantChips.add(_RoleChip(tenant: tenant, role: role));
          }

          // De-dupe: if name is empty or identical to email, only show one identifier.
          final primary = name.trim().isEmpty ? email : name;
          final showEmailSecondary =
              name.trim().isNotEmpty && name.trim().toLowerCase() != email.toLowerCase();

          final row = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Checkbox(
                    value: selected,
                    onChanged: alreadyShared
                        ? null
                        : (v) => onToggle(uid, v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Row 1: primary identifier + tenant chips inline
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            primary,
                            style: TextStyle(
                              color: alreadyShared
                                  ? OpticsColors.textSecondary
                                  : OpticsColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          ...tenantChips,
                        ],
                      ),
                      // Row 2 (optional): real email if name differs
                      if (showEmailSecondary) ...[
                        const SizedBox(height: 2),
                        Text(
                          email,
                          style: const TextStyle(
                            color: OpticsColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );

          if (alreadyShared) {
            return Tooltip(
              message: 'Already shared — manage in Manage Access below.',
              child: Opacity(opacity: 0.55, child: row),
            );
          }
          return row;
        },
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  final String tenant;
  final String role;
  const _RoleChip({required this.tenant, required this.role});

  @override
  Widget build(BuildContext context) {
    final roleColor = _colorForRole(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: roleColor.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
        color: roleColor.withValues(alpha: 0.08),
      ),
      child: Text(
        '${tenant.toUpperCase()} · ${role.toUpperCase()}',
        style: TextStyle(
          color: roleColor,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Color _colorForRole(String r) {
    switch (r) {
      case 'owner':
        return const Color(0xFFFFB454);
      case 'admin':
        return const Color(0xFFAE8BFF);
      case 'editor':
        return const Color(0xFF3DB8FF);
      case 'viewer':
        return const Color(0xFF5DD0A8);
      case 'guest':
        return const Color(0xFF9CA3B5);
      default:
        return const Color(0xFF9CA3B5);
    }
  }
}

class _ManageAccessList extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> shares;
  final bool busy;
  final void Function(String shareId) onRevoke;
  const _ManageAccessList({
    required this.loading,
    required this.error,
    required this.shares,
    required this.busy,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(error!,
            style: const TextStyle(color: OpticsColors.textSecondary, fontSize: 12)),
      );
    }
    if (shares.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'Not shared with anyone yet.',
          style: TextStyle(color: OpticsColors.textSecondary, fontSize: 12),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0x1AFFFFFF)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          for (int i = 0; i < shares.length; i++) ...[
            if (i > 0) const Divider(color: Color(0x14FFFFFF), height: 1),
            _shareRow(shares[i]),
          ],
        ],
      ),
    );
  }

  Widget _shareRow(Map<String, dynamic> s) {
    final shareId = (s['share_id'] ?? '').toString();
    final name = (s['display_name'] ?? s['email'] ?? '').toString();
    final email = (s['email'] ?? '').toString();
    final isPending = s['is_pending'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: const TextStyle(
                          color: OpticsColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isPending) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFFFFB454).withValues(alpha: 0.6)),
                          borderRadius: BorderRadius.circular(4),
                          color: const Color(0xFFFFB454).withValues(alpha: 0.08),
                        ),
                        child: const Text(
                          'PENDING',
                          style: TextStyle(
                            color: Color(0xFFFFB454),
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                if (email.isNotEmpty)
                  Text(
                    email,
                    style: const TextStyle(
                      color: OpticsColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Revoke access',
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            onPressed: busy ? null : () => onRevoke(shareId),
          ),
        ],
      ),
    );
  }
}
