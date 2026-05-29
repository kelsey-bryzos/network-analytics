import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import '../../platform/drop_target.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';
import 'role_info_tooltip.dart';

// ---------------------------------------------------------------------------
// Tenant-scoped providers for the settings screen.
// These are keyed by tenantId so each org card always queries its own data,
// independent of which tenant is currently "active" in the JWT.
// ---------------------------------------------------------------------------

/// Members list for a specific tenant (bypasses the global activeTenantProvider).
final _tenantMembersProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, tenantId) async {
  final client = ref.watch(supabaseProvider);
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

/// Pending invites for a specific tenant (bypasses the global activeTenantPendingInvitesProvider).
final _tenantPendingInvitesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, tenantId) async {
  final client = ref.watch(supabaseProvider);
  final rows = await client.rpc(
    'list_tenant_pending_invites',
    params: {'tid': tenantId},
  );
  // Attach tenant_id to each invite so the revoke handler can use it.
  return (rows as List).map((r) {
    final m = (r as Map).cast<String, dynamic>();
    return {...m, 'tenant_id': tenantId};
  }).toList();
});

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  List<Map<String, dynamic>>? _tenants;
  bool _loading = true;
  String? _err;
  // Which tenant card is currently expanded. Null = all collapsed (default).
  String? _expandedTenantId;

  @override
  void initState() {
    super.initState();
    _loadTenants();
  }

  Future<void> _loadTenants() async {
    try {
      final client = ref.read(supabaseProvider);
      final rows = await client.from('memberships').select('role, tenants(id, name, slug, logo_url, app_name, display_order)');
      if (mounted) {
        final raw = (rows as List).map((r) => (r as Map).cast<String, dynamic>()).toList();
        // Deduplicate by tenant ID — a user can theoretically have multiple
        // membership rows for the same tenant (e.g. during migration). Keep
        // the first (highest-privilege) occurrence to avoid duplicate cards.
        final seen = <String>{};
        final list = raw.where((m) {
          final tid = (m['tenants'] as Map?)?['id'] as String?;
          if (tid == null) return false;
          return seen.add(tid);
        }).toList();
        list.sort((a, b) {
          final aOrder = ((a['tenants'] as Map?)?['display_order'] as int?) ?? 999;
          final bOrder = ((b['tenants'] as Map?)?['display_order'] as int?) ?? 999;
          return aOrder.compareTo(bOrder);
        });
        setState(() {
          _tenants = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _err = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _switchTenant(String tenantId) async {
    try {
      final client = ref.read(supabaseProvider);
      await client.functions.invoke('switch-tenant', body: {'tenant_id': tenantId});
      await client.auth.refreshSession();
      if (mounted) {
        ref.read(activeTenantProvider.notifier).state = tenantId;
        // Force the header logo + every tenant-scoped query to refetch.
        ref.invalidate(activeTenantObjectProvider);
        ref.invalidate(dataSourcesProvider);
        ref.invalidate(dashboardsListProvider);
        // Reports and library are tenant-scoped too — drop the cached
        // lists so the new tenant doesn't briefly see the previous
        // tenant's reports while RLS would otherwise refilter on next
        // fetch.
        ref.invalidate(reportsProvider);
        ref.invalidate(libraryProvider);
      }
    } catch (e) {
      debugPrint('[Optics] Switch tenant error: $e');
    }
  }

  void _showAddOrgDialog() {
    showDialog(
      context: context,
      builder: (context) => const _AddOrganizationDialog(),
    ).then((_) => _loadTenants()); // Reload tenants after modal closes
  }

  @override
  Widget build(BuildContext context) {
    final activeTenantId = ref.watch(activeTenantProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('ORGANIZATION SETTINGS', style: OpticsTextStyles.headingXl),
              // Only Bryzos Owners can create new organizations.
              Consumer(builder: (context, ref, _) {
                final isOwner = ref.watch(isBryzosOwnerProvider).value ?? false;
                if (!isOwner) return const SizedBox.shrink();
                return ElevatedButton.icon(
                  onPressed: _showAddOrgDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add New Organization'),
                );
              }),
            ],
          ),
          const SizedBox(height: OpticsSpacing.xl),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_err != null)
            Text('Error loading organizations: $_err', style: const TextStyle(color: OpticsColors.danger))
          else if (_tenants == null || _tenants!.isEmpty)
            const Text('No organizations found.', style: OpticsTextStyles.body)
          else
            ..._tenants!.map((m) {
              final t = (m['tenants'] as Map).cast<String, dynamic>();
              final role = m['role'] as String;
              final tenantId = t['id'] as String;
              final isActive = tenantId == activeTenantId;
              final isExpanded = _expandedTenantId == tenantId;

              return Padding(
                padding: const EdgeInsets.only(bottom: OpticsSpacing.lg),
                child: isExpanded
                  ? _ActiveTenantCard(
                      tenant: t,
                      role: role,
                      isActive: isActive,
                      onCollapse: () => setState(() => _expandedTenantId = null),
                    )
                  : _InactiveTenantCard(
                      tenant: t,
                      role: role,
                      isActive: isActive,
                      onManage: () async {
                        // Switch tenants if this isn't the active one, then expand.
                        if (!isActive) await _switchTenant(tenantId);
                        if (mounted) setState(() => _expandedTenantId = tenantId);
                      },
                      onSwitch: () => _switchTenant(tenantId),
                    ),
              );
            }),

        ],
      ),
    );
  }
}

class _InactiveTenantCard extends ConsumerWidget {
  final Map<String, dynamic> tenant;
  final String role;
  final bool isActive;
  final Future<void> Function() onManage;
  final Future<void> Function() onSwitch;

  const _InactiveTenantCard({
    required this.tenant,
    required this.role,
    required this.isActive,
    required this.onManage,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logoUrl = tenant['logo_url'] as String?;
    final name = tenant['name'] as String? ?? 'Unknown';

    return OpticsCard(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
            ),
            alignment: Alignment.center,
            child: (logoUrl != null && logoUrl.isNotEmpty)
                ? logoUrl.startsWith('http') ? Image.network(logoUrl, height: 32, width: 32, fit: BoxFit.contain, errorBuilder: (_,__,___) => Text(name[0], style: const TextStyle(fontWeight: FontWeight.bold))) : Image.asset(logoUrl, height: 32, width: 32, fit: BoxFit.contain, errorBuilder: (_,__,___) => Text(name[0], style: const TextStyle(fontWeight: FontWeight.bold)))
                : Text(name.isNotEmpty ? name[0] : '?', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name.toUpperCase(), style: OpticsTextStyles.headingLg.copyWith(fontSize: 15, letterSpacing: 1.1)),
                    if (isActive) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: OpticsColors.accentCyan.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'ACTIVE',
                          style: OpticsTextStyles.bodySm.copyWith(
                            color: OpticsColors.accentCyan,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text('Role: ${role.toUpperCase()}', style: OpticsTextStyles.bodySm),
              ],
            ),
          ),
          OutlinedButton(
            // Manage Settings: switch tenant (if needed) and expand this card.
            onPressed: () => onManage(),
            child: const Text('Manage Settings'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            // View Data: switch tenant, WAIT for switch to complete (so the
            // header logo + dashboards reflect the new tenant), then navigate.
            onPressed: () async {
              await onSwitch();
              if (context.mounted) context.go('/dashboards');
            },
            icon: const Icon(Icons.bar_chart, size: 16),
            label: const Text('View Data'),
            style: ElevatedButton.styleFrom(
              backgroundColor: OpticsColors.accentCyan,
              foregroundColor: const Color(0xFF0A0A0F),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveTenantCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> tenant;
  final String role;
  final bool isActive;
  final VoidCallback onCollapse;
  const _ActiveTenantCard({
    required this.tenant,
    required this.role,
    required this.isActive,
    required this.onCollapse,
  });

  @override
  ConsumerState<_ActiveTenantCard> createState() => _ActiveTenantCardState();
}

class _ActiveTenantCardState extends ConsumerState<_ActiveTenantCard> {
  late TextEditingController _nameController;
  late TextEditingController _appNameController;
  late TextEditingController _logoController;
  late String _initialName;
  late String _initialAppName;
  late String _initialLogo;
  bool _saving = false;

  // Name and App Name both drive the "Save Changes" button — logo changes
  // auto-save inside _LogoUploader the moment a file is uploaded/removed.
  bool get _dirty =>
      _nameController.text.trim() != _initialName ||
      _appNameController.text.trim() != _initialAppName;

  @override
  void initState() {
    super.initState();
    _initialName = (widget.tenant['name'] as String? ?? '').trim();
    _initialAppName = (widget.tenant['app_name'] as String? ?? '').trim();
    _initialLogo = (widget.tenant['logo_url'] as String? ?? '').trim();
    _nameController = TextEditingController(text: _initialName);
    _appNameController = TextEditingController(text: _initialAppName);
    _logoController = TextEditingController(text: _initialLogo);
  }

  @override
  void didUpdateWidget(covariant _ActiveTenantCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tenant['id'] != widget.tenant['id']) {
      _initialName = (widget.tenant['name'] as String? ?? '').trim();
      _initialAppName = (widget.tenant['app_name'] as String? ?? '').trim();
      _initialLogo = (widget.tenant['logo_url'] as String? ?? '').trim();
      _nameController.text = _initialName;
      _appNameController.text = _initialAppName;
      _logoController.text = _initialLogo;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _appNameController.dispose();
    _logoController.dispose();
    super.dispose();
  }

  Future<void> _saveDetails() async {
    setState(() => _saving = true);
    try {
      final client = ref.read(supabaseProvider);
      final newAppName = _appNameController.text.trim();
      await client.from('tenants').update({
        'name': _nameController.text.trim(),
        'app_name': newAppName.isEmpty ? null : newAppName,
      }).eq('id', widget.tenant['id']);

      _initialName = _nameController.text.trim();
      _initialAppName = newAppName;
      ref.invalidate(activeTenantObjectProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Organization details saved')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Called by `_LogoUploader` whenever the logo URL changes (upload or remove).
  /// Persists immediately to the tenants table so the header updates live.
  Future<void> _persistLogo(String url) async {
    _logoController.text = url;
    _initialLogo = url;
    try {
      final client = ref.read(supabaseProvider);
      await client.from('tenants').update({
        'logo_url': url.isEmpty ? null : url,
      }).eq('id', widget.tenant['id']);
      ref.invalidate(activeTenantObjectProvider);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Logo save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.tenant['name'] as String? ?? 'Unknown';
    final logoUrl = _logoController.text;

    return Container(
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(color: OpticsColors.accentCyan, width: 2), // Highlight active
        boxShadow: [
          BoxShadow(
            color: OpticsColors.accentCyan.withValues(alpha: 0.1),
            blurRadius: 20,
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Active Header
          Padding(
            padding: const EdgeInsets.all(OpticsSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: OpticsColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(OpticsRadii.sm),
                  ),
                  alignment: Alignment.center,
                  child: (logoUrl.isNotEmpty)
                      ? logoUrl.startsWith('http') ? Image.network(logoUrl, height: 32, width: 32, fit: BoxFit.contain, errorBuilder: (_,__,___) => Text(name.isNotEmpty ? name[0] : '?', style: const TextStyle(fontWeight: FontWeight.bold))) : Image.asset(logoUrl, height: 32, width: 32, fit: BoxFit.contain, errorBuilder: (_,__,___) => Text(name.isNotEmpty ? name[0] : '?', style: const TextStyle(fontWeight: FontWeight.bold)))
                      : Text(name.isNotEmpty ? name[0] : '?', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name.toUpperCase(), style: OpticsTextStyles.headingLg.copyWith(fontSize: 15, letterSpacing: 1.1)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (widget.isActive) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: OpticsColors.accentCyan.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('ACTIVE', style: TextStyle(color: OpticsColors.accentCyan, fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text('Role: ${widget.role.toUpperCase()}', style: OpticsTextStyles.bodySm),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Collapse',
                  icon: const Icon(Icons.keyboard_arrow_up, color: OpticsColors.textSecondary),
                  onPressed: widget.onCollapse,
                ),
              ],
            ),
          ),
          const Divider(color: OpticsColors.border, height: 1),
          
          // Details Form
          Padding(
            padding: const EdgeInsets.all(OpticsSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ORGANIZATION DETAILS', style: _orgSectionLabel),
                const SizedBox(height: OpticsSpacing.md),
                // Company Name + Application Name + Save Changes
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Company Name', style: OpticsTextStyles.bodySm),
                          const SizedBox(height: 4),
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(isDense: true),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: OpticsSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('Application Name', style: OpticsTextStyles.bodySm),
                              const SizedBox(width: 6),
                              Text(
                                '(optional)',
                                style: OpticsTextStyles.bodySm.copyWith(color: OpticsColors.textMuted),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            controller: _appNameController,
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'e.g. Gone In 60 Seconds',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: OpticsSpacing.md),
                    ElevatedButton(
                      onPressed: (_saving || !_dirty) ? null : _saveDetails,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: OpticsColors.surfaceElevated,
                        foregroundColor: OpticsColors.textPrimary,
                      ),
                      child: _saving
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Save Changes'),
                    ),
                  ],
                ),
                const SizedBox(height: OpticsSpacing.lg),
                // Logo block — auto-saves on upload/remove. No separate button.
                const Text('Header Logo', style: OpticsTextStyles.bodySm),
                const SizedBox(height: 2),
                const Text(
                  'App header, sidebar, invoices, POs, packing lists',
                  style: TextStyle(color: OpticsColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                _LogoUploader(
                  initialUrl: _logoController.text,
                  onChanged: _persistLogo,
                ),
              ],
            ),
          ),
          const Divider(color: OpticsColors.border, height: 1),

          // Data Sources
          Padding(
            padding: const EdgeInsets.all(OpticsSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('DATA SOURCES', style: _orgSectionLabel),
                    // Only Bryzos Owners may add data sources to any organization.
                    Consumer(builder: (context, ref, _) {
                      final isOwner = ref.watch(isBryzosOwnerProvider).value ?? false;
                      if (!isOwner) return const SizedBox.shrink();
                      return ElevatedButton.icon(
                        onPressed: () => showDialog(
                          context: context,
                          builder: (_) => _DataSourceDialog(
                            tenantId: widget.tenant['id'] as String,
                          ),
                        ).then((created) {
                          if (created == true) ref.invalidate(dataSourcesProvider);
                        }),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Data Source'),
                      );
                    }),
                  ],
                ),
                const SizedBox(height: OpticsSpacing.md),
                _TenantDataSourcesList(tenantId: widget.tenant['id'] as String),
              ],
            ),
          ),
          const Divider(color: OpticsColors.border, height: 1),

          // Team Members
          Padding(
            padding: const EdgeInsets.all(OpticsSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Text('TEAM ROLES & MEMBERS', style: _orgSectionLabel),
                    SizedBox(width: 4),
                    RoleInfoTooltip(),
                  ],
                ),
                const SizedBox(height: OpticsSpacing.md),
                _TeamList(tenantId: widget.tenant['id'] as String),
                const SizedBox(height: OpticsSpacing.lg),
                const Text('PENDING INVITES', style: _orgSectionLabel),
                const SizedBox(height: OpticsSpacing.md),
                _PendingInvitesList(tenantId: widget.tenant['id'] as String),
                const SizedBox(height: OpticsSpacing.lg),
                const Text('INVITE TEAMMATE', style: _orgSectionLabel),
                const SizedBox(height: OpticsSpacing.md),
                _InvitePanel(tenantId: widget.tenant['id'] as String),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamList extends ConsumerWidget {
  final String tenantId;
  const _TeamList({required this.tenantId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Use a tenant-specific provider keyed to this card's tenant, not the
    // global activeTenantProvider, so the list always reflects the correct org.
    final membersAsync = ref.watch(_tenantMembersProvider(tenantId));
    return membersAsync.when(
      data: (members) {
        if (members.isEmpty) {
          return const Text(
            'No additional team members invited yet.',
            style: OpticsTextStyles.bodySm,
          );
        }
        return Column(
          children: members.map((m) {
            final role           = (m['role'] as String).toUpperCase();
            final displayName    = (m['display_name'] as String?) ?? '';
            final fullName       = (m['full_name']    as String?) ?? displayName;
            final email          = (m['email']        as String?) ?? '';
            final isBryzosStaff  = m['is_bryzos_staff'] == true;

            // Avatar initial: prefer first char of fullName, else email
            final avatarChar = fullName.isNotEmpty
                ? fullName[0].toUpperCase()
                : (email.isNotEmpty ? email[0].toUpperCase() : '?');

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Avatar circle
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isBryzosStaff
                          ? const Color(0xFF7C3AED).withValues(alpha: 0.18)
                          : OpticsColors.surfaceElevated,
                      shape: BoxShape.circle,
                      border: isBryzosStaff
                          ? Border.all(color: const Color(0xFF7C3AED).withValues(alpha: 0.5), width: 1)
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      avatarChar,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isBryzosStaff
                            ? const Color(0xFFA78BFA)
                            : OpticsColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Name + email stack
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (fullName.isNotEmpty)
                              Text(fullName, style: OpticsTextStyles.body),
                            if (isBryzosStaff) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7C3AED).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                    color: const Color(0xFF7C3AED).withValues(alpha: 0.4),
                                  ),
                                ),
                                child: const Text(
                                  'BRYZOS',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFA78BFA),
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (email.isNotEmpty)
                          Text(
                            email,
                            style: OpticsTextStyles.bodySm.copyWith(
                              color: OpticsColors.textMuted,
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Role badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: role == 'OWNER'
                          ? OpticsColors.accentCyan.withValues(alpha: 0.1)
                          : OpticsColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      role,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: role == 'OWNER'
                            ? OpticsColors.accentCyan
                            : OpticsColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => const Text(
        'No additional team members invited yet.',
        style: OpticsTextStyles.bodySm,
      ),
    );
  }
}

/// Lists outstanding (un-accepted) invites for the active tenant, with a
/// revoke (×) button per row. Release Plan §1.9.
class _PendingInvitesList extends ConsumerWidget {
  final String tenantId;
  const _PendingInvitesList({required this.tenantId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invitesAsync = ref.watch(_tenantPendingInvitesProvider(tenantId));
    return invitesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
          height: 14,
          width: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (_, __) => const Text(
        'Could not load pending invites.',
        style: OpticsTextStyles.bodySm,
      ),
      data: (invites) {
        if (invites.isEmpty) {
          return const Text(
            'No pending invites.',
            style: OpticsTextStyles.bodySm,
          );
        }
        return Column(
          children: invites
              .map((inv) => _PendingInviteRow(invite: inv))
              .toList(),
        );
      },
    );
  }
}

class _PendingInviteRow extends ConsumerStatefulWidget {
  const _PendingInviteRow({required this.invite});
  final Map<String, dynamic> invite;
  @override
  ConsumerState<_PendingInviteRow> createState() => _PendingInviteRowState();
}

class _PendingInviteRowState extends ConsumerState<_PendingInviteRow> {
  bool _busy = false;

  Future<void> _revoke() async {
    final inv = widget.invite;
    final email = (inv['email'] ?? '').toString();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: OpticsColors.surfaceElevated,
        title: const Text('Revoke invite?'),
        content: Text(
          'The invite link sent to $email will stop working immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Revoke',
                style: TextStyle(color: OpticsColors.accentOrange)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      final client = ref.read(supabaseProvider);
      // Use invite's own tenant_id if available, fall back to active tenant.
      final tid = (inv['tenant_id'] as String?) ?? ref.read(activeTenantProvider);
      final res = await client.functions.invoke(
        'revoke-invite',
        body: {'invite_id': inv['id']},
        headers: tid == null ? {} : {'x-optics-tenant': tid},
      );
      final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
      if (data['error'] != null) throw Exception(data['error']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invite to $email revoked.')),
        );
        ref.invalidate(activeTenantPendingInvitesProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Revoke failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.invite;
    final email = (inv['email'] ?? '').toString();
    final role = (inv['role'] ?? 'viewer').toString().toUpperCase();
    final expIso = inv['expires_at']?.toString();
    String expLabel = '';
    if (expIso != null) {
      final exp = DateTime.tryParse(expIso);
      if (exp != null) {
        final days = exp.difference(DateTime.now()).inDays;
        if (days < 0) {
          expLabel = 'EXPIRED';
        } else if (days == 0) {
          expLabel = 'expires today';
        } else {
          expLabel = 'expires in ${days}d';
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.mail_outline,
              size: 16, color: OpticsColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(email, style: OpticsTextStyles.body)),
          if (expLabel.isNotEmpty) ...[
            Text(
              expLabel,
              style: TextStyle(
                fontSize: 11,
                color: expLabel == 'EXPIRED'
                    ? OpticsColors.accentOrange
                    : OpticsColors.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              role,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: OpticsColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Revoke invite',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : _revoke,
            icon: _busy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.close,
                    color: OpticsColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _InvitePanel extends ConsumerStatefulWidget {
  final String tenantId;
  const _InvitePanel({required this.tenantId});
  @override
  ConsumerState<_InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends ConsumerState<_InvitePanel> {
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  String? _role;
  bool _busy = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    final first = _firstName.text.trim();
    final last = _lastName.text.trim();
    final email = _email.text.trim();
    final role = _role;
    if (first.isEmpty || last.isEmpty || email.isEmpty || role == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Please enter a first name, last name, email, and choose a role.',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
        ),
        backgroundColor: OpticsColors.accentOrange,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 4),
      ));
      return;
    }
    setState(() => _busy = true);
    try {
      final client = ref.read(supabaseProvider);
      final tid = widget.tenantId;
      final res = await client.functions.invoke(
        'invite-user',
        body: {
          'email': email,
          'role': role,
          'first_name': first,
          'last_name': last,
        },
        headers: {'x-optics-tenant': tid},
      );
      if (mounted) {
        _firstName.clear();
        _lastName.clear();
        _email.clear();
        setState(() => _role = null);
        final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
        final status = data['status']?.toString() ?? 'Invited';
        final emailInfo = (data['email'] as Map?)?.cast<String, dynamic>();
        String msg;
        Color? bg;
        if (status == 'member_added') {
          msg = 'Added to organization — they can sign in now.';
          bg = OpticsColors.accentGreen;
        } else if (emailInfo?['ok'] == true) {
          msg = 'Invite sent to their email.';
          bg = OpticsColors.accentGreen;
        } else if (emailInfo?['skipped'] == true) {
          msg = 'Invite created (no email provider configured — share the link manually).';
          bg = OpticsColors.accentOrange;
        } else {
          msg = 'Invite created, but email delivery failed: ${emailInfo?['error'] ?? 'unknown error'}';
          bg = OpticsColors.danger;
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            msg,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w600,
            ),
          ),
          backgroundColor: bg,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ));
        // Invalidate both the tenant-specific providers for this card
        // and the global providers so other parts of the UI stay fresh.
        ref.invalidate(_tenantMembersProvider(tid));
        ref.invalidate(_tenantPendingInvitesProvider(tid));
        ref.invalidate(activeTenantMembersProvider);
        ref.invalidate(activeTenantPendingInvitesProvider);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _firstName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'First Name', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _lastName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'Last Name', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(hintText: 'teammate@company.com', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: Consumer(builder: (context, ref, _) {
                final isOwner =
                    ref.watch(isBryzosOwnerProvider).value ?? false;
                // Only Bryzos owners can invite other owners.
                final roles = isOwner
                    ? const ['viewer', 'editor', 'admin', 'owner']
                    : const ['viewer', 'editor', 'admin'];
                if (_role != null && !roles.contains(_role)) _role = null;
                return DropdownButtonFormField<String>(
                  value: _role,
                  isDense: true,
                  decoration: const InputDecoration(isDense: true),
                  dropdownColor: OpticsColors.surfaceElevated,
                  hint: const Text(
                    'Choose Role',
                    style: TextStyle(
                      color: OpticsColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                  items: roles
                      .map((r) => DropdownMenuItem(
                          value: r,
                          child: Text(r.toUpperCase(),
                              style: const TextStyle(fontSize: 12))))
                      .toList(),
                  onChanged: (v) => setState(() => _role = v),
                );
              }),
            ),
            const SizedBox(width: 8),
            const RoleInfoTooltip(size: 16),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _busy ? null : _invite,
              child: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Send'),
            ),
          ],
        ),
      ],
    );
  }
}

class _AddOrganizationDialog extends ConsumerStatefulWidget {
  const _AddOrganizationDialog();
  @override
  ConsumerState<_AddOrganizationDialog> createState() => _AddOrganizationDialogState();
}

class _AddOrganizationDialogState extends ConsumerState<_AddOrganizationDialog> {
  final _name = TextEditingController();
  final _logoUrl = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _logoUrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final client = ref.read(supabaseProvider);
      final slug = _name.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
      final tenantId = await client.rpc('create_tenant_with_owner', params: {
        'p_name': _name.text.trim(),
        'p_slug': slug
      });
      
      // If a logo url was provided, immediately update it
      if (_logoUrl.text.trim().isNotEmpty) {
        await client.from('tenants').update({'logo_url': _logoUrl.text.trim()}).eq('id', tenantId);
      }

      await client.functions.invoke('switch-tenant', body: {'tenant_id': tenantId});
      await client.auth.refreshSession();
      
      if (mounted) {
        ref.read(activeTenantProvider.notifier).state = tenantId as String;
        Navigator.of(context).pop(); // Close dialog
      }
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OpticsColors.surface,
      surfaceTintColor: Colors.transparent,
      title: Text('Add New Organization'.toUpperCase(), style: OpticsTextStyles.headingLg),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Company Name', style: OpticsTextStyles.bodySm),
            const SizedBox(height: 4),
            TextField(
              controller: _name,
              decoration: const InputDecoration(hintText: 'e.g., Bryzos, Ryerson...'),
              autofocus: true,
            ),
            const SizedBox(height: OpticsSpacing.md),
            const Text('Company Logo (Optional)', style: OpticsTextStyles.bodySm),
            const SizedBox(height: 4),
            _LogoUploader(
              initialUrl: _logoUrl.text,
              onChanged: (url) {
                _logoUrl.text = url;
                setState(() {});
              },
            ),
            if (_err != null) ...[
              const SizedBox(height: 12),
              Text(_err!, style: const TextStyle(color: OpticsColors.danger, fontSize: 12)),
            ]
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: OpticsColors.textSecondary)),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _create,
          child: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Create Organization'),
        ),
      ],
    );
  }
}

class _LogoUploader extends ConsumerStatefulWidget {
  final String? initialUrl;
  final ValueChanged<String> onChanged;

  const _LogoUploader({this.initialUrl, required this.onChanged});

  @override
  ConsumerState<_LogoUploader> createState() => _LogoUploaderState();
}

class _LogoUploaderState extends ConsumerState<_LogoUploader> {
  bool _uploading = false;
  bool _dragOver = false;
  late String _currentUrl;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl ?? '';
  }

  @override
  void didUpdateWidget(covariant _LogoUploader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.initialUrl ?? '') != (widget.initialUrl ?? '')) {
      _currentUrl = widget.initialUrl ?? '';
    }
  }

  Future<void> _uploadBytes(List<int> bytes, String fileName) async {
    setState(() => _uploading = true);
    try {
      final client = ref.read(supabaseProvider);
      final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'png';
      final stored = '${DateTime.now().millisecondsSinceEpoch}_$fileName';
      await client.storage.from('logos').uploadBinary(
        stored,
        Uint8List.fromList(bytes),
        fileOptions: FileOptions(contentType: 'image/$ext', upsert: true),
      );
      final url = client.storage.from('logos').getPublicUrl(stored);
      setState(() => _currentUrl = url);
      widget.onChanged(url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickAndUpload() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.bytes == null) throw Exception('Could not read file bytes');
      await _uploadBytes(file.bytes!, file.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  void _remove() {
    setState(() => _currentUrl = '');
    widget.onChanged('');
  }

  Widget _previewImage(String url) {
    if (url.startsWith('http')) {
      return Image.network(url, fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              const Icon(Icons.broken_image, color: OpticsColors.textMuted, size: 48));
    }
    return Image.asset(url, fit: BoxFit.contain,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image, color: OpticsColors.textMuted, size: 48));
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _currentUrl.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Drop zone / preview
        DropTarget(
          onDragEntered: (_) => setState(() => _dragOver = true),
          onDragExited: (_) => setState(() => _dragOver = false),
          onDragDone: (detail) async {
            setState(() => _dragOver = false);
            if (detail.files.isEmpty) return;
            final f = detail.files.first;
            final bytes = await f.readAsBytes();
            await _uploadBytes(bytes, f.name);
          },
          child: Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              borderRadius: BorderRadius.circular(OpticsRadii.md),
              border: Border.all(
                color: _dragOver ? OpticsColors.accentCyan : OpticsColors.border,
                width: _dragOver ? 2 : 1,
                style: hasImage ? BorderStyle.solid : BorderStyle.solid,
              ),
            ),
            padding: const EdgeInsets.all(12),
            alignment: Alignment.center,
            child: _uploading
                ? const CircularProgressIndicator(strokeWidth: 2)
                : hasImage
                    ? _previewImage(_currentUrl)
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.image_outlined, size: 40, color: OpticsColors.textMuted),
                          const SizedBox(height: 8),
                          const Text(
                            'Drag & drop a logo here, or click Browse Files',
                            style: TextStyle(color: OpticsColors.textSecondary, fontSize: 13),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'PNG or JPG · landscape or square · min 200×200px · transparent background preferred',
                            style: TextStyle(color: OpticsColors.textMuted, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
          ),
        ),
        const SizedBox(height: 8),
        // Action buttons
        Row(
          children: [
            if (!hasImage)
              ElevatedButton.icon(
                onPressed: _uploading ? null : _pickAndUpload,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('Browse Files'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: OpticsColors.accentCyan,
                  foregroundColor: const Color(0xFF0A0A0F),
                ),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: _uploading ? null : _pickAndUpload,
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: const Text('Replace'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _uploading ? null : _remove,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Remove'),
                style: OutlinedButton.styleFrom(foregroundColor: OpticsColors.danger),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

// White section labels for Organization Settings (#FFFFFF).
const TextStyle _orgSectionLabel = TextStyle(
  fontFamily: 'Syncopate',
  fontSize: 12,
  fontWeight: FontWeight.w700,
  color: OpticsColors.textPrimary,
  letterSpacing: 1.6,
);

/// Inline list of data sources scoped to a specific tenant, used inside the
/// Organization Settings card. Replaces the standalone Data Sources page.
class _TenantDataSourcesList extends ConsumerWidget {
  final String tenantId;
  const _TenantDataSourcesList({required this.tenantId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dataSourcesProvider);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          height: 16, width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Text(
        'Error loading data sources: $e',
        style: const TextStyle(color: OpticsColors.danger, fontSize: 12),
      ),
      data: (all) {
        final items = all.where((s) => s.tenantId == tenantId).toList();
        if (items.isEmpty) {
          return const Text(
            'No data sources connected yet.',
            style: OpticsTextStyles.bodySm,
          );
        }
        return Column(
          children: [
            for (final s in items)
              Padding(
                padding: const EdgeInsets.only(bottom: OpticsSpacing.sm),
                child: _TenantDataSourceRow(source: s),
              ),
          ],
        );
      },
    );
  }
}

class _TenantDataSourceRow extends ConsumerStatefulWidget {
  final DataSource source;
  const _TenantDataSourceRow({required this.source});

  @override
  ConsumerState<_TenantDataSourceRow> createState() =>
      _TenantDataSourceRowState();
}

class _TenantDataSourceRowState extends ConsumerState<_TenantDataSourceRow> {
  bool _testing = false;
  bool _refreshing = false;
  bool _cancelling = false;

  Color get _statusColor {
    switch (widget.source.lastTestStatus) {
      case 'ok':
        return OpticsColors.success;
      case 'error':
        return OpticsColors.danger;
      default:
        return OpticsColors.textMuted;
    }
  }

  /// "5 m ago" / "just now" / "1 h ago" / "2 d ago".
  String _formatAgo(DateTime t) {
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inSeconds < 30) return 'just now';
    if (d.inMinutes < 1) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  String _cadenceLabel(int m) {
    if (m == 0) return 'Off';
    if (m == 1440) return 'Daily';
    if (m >= 60) return 'Every ${m ~/ 60}h';
    return 'Every ${m}m';
  }

  Future<void> _runRefresh() async {
    setState(() => _refreshing = true);
    try {
      final res =
          await ref.read(repoProvider).requestDataSourceSync(widget.source.id);
      // ignore: unused_result
      ref.refresh(dataSourceSyncProvider(widget.source.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res['queued'] == true
                ? 'Refresh started for "${widget.source.name}"'
                : 'Refresh response: ${res.toString()}'),
          ),
        );
      }
      // Poll for completion so the row updates without manual refresh.
      _pollUntilDone();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _pollUntilDone() async {
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      // ignore: unused_result
      ref.refresh(dataSourceSyncProvider(widget.source.id));
      // ignore: unused_result
      ref.refresh(dataSourceSyncProgressProvider(widget.source.id));
      final row =
          await ref.read(repoProvider).getDataSourceSync(widget.source.id);
      final status = row?['last_sync_status'] as String?;
      if (status == 'ok' || status == 'error' || status == 'cancelled' || status == 'partial') return;
    }
  }

  Future<void> _cancelSync() async {
    setState(() => _cancelling = true);
    try {
      await ref.read(repoProvider).cancelDataSourceSync(widget.source.id);
      // ignore: unused_result
      ref.refresh(dataSourceSyncProvider(widget.source.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync cancelled')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cancel failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() { _cancelling = false; _refreshing = false; });
    }
  }

  Future<void> _changeCadence(int minutes) async {
    try {
      await ref.read(repoProvider).setDataSourceCadence(
            widget.source.id,
            widget.source.tenantId,
            minutes,
          );
      // ignore: unused_result
      ref.refresh(dataSourceSyncProvider(widget.source.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(minutes == 0
                ? 'Auto-refresh disabled'
                : 'Auto-refresh set to ${_cadenceLabel(minutes)}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update cadence: $e')),
        );
      }
    }
  }

  Future<void> _runTest() async {
    setState(() => _testing = true);
    try {
      final result = await ref
          .read(repoProvider)
          .testDataSource(widget.source.id, kind: widget.source.kind);
      // ignore: unused_result
      ref.refresh(dataSourcesProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              (result['ok'] == true)
                  ? 'Connection OK${result['elapsed_ms'] != null ? ' (${result['elapsed_ms']} ms)' : ''}'
                  : 'Failed: ${result['error'] ?? 'unknown'}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.source;
    final syncAsync = ref.watch(dataSourceSyncProvider(s.id));
    final sync = syncAsync.value;
    final cadence = (sync?['cadence_minutes'] as int?) ?? 0;
    final lastStatus = sync?['last_sync_status'] as String?;
    final lastAtRaw = sync?['last_sync_at'] as String?;
    final lastAt =
        lastAtRaw != null ? DateTime.tryParse(lastAtRaw)?.toLocal() : null;
    final lastRows = sync?['last_sync_rows'] as int?;
    final lastErr = sync?['last_sync_error'] as String?;

    final isSyncing = lastStatus == 'running' || _refreshing;
    final progressAsync = isSyncing
        ? ref.watch(dataSourceSyncProgressProvider(s.id))
        : const AsyncData<Map<String, dynamic>>({});
    final progress = progressAsync.value;

    // Detect stale syncs: if 'running' for >3 min, the sync is likely orphaned.
    final bool isStaleSync = isSyncing &&
        lastAt != null &&
        DateTime.now().toUtc().difference(lastAt.toUtc()).inMinutes > 3;

    String subtitle;
    Color subtitleColor = OpticsColors.textSecondary;
    if (isStaleSync) {
      subtitle = 'Sync appears stuck — cancel and retry';
      subtitleColor = OpticsColors.warning;
    } else if (isSyncing) {
      subtitle = 'Syncing…';
      subtitleColor = OpticsColors.accentCyan;
    } else if (lastStatus == 'cancelled') {
      subtitle = 'Sync cancelled${lastAt != null ? ' ${_formatAgo(lastAt)}' : ''}';
      subtitleColor = OpticsColors.warning;
    } else if (lastStatus == 'ok' && lastAt != null) {
      final rowsStr = (lastRows != null && lastRows > 0) ? ' · $lastRows new' : '';
      subtitle = 'Last sync: ${_formatAgo(lastAt)}$rowsStr';
    } else if (lastStatus == 'partial' && lastAt != null) {
      final errStr = (sync?['last_sync_error'] as String?)?.isNotEmpty == true
          ? ' — ${sync!['last_sync_error']}'
          : '';
      subtitle = 'Partial sync ${_formatAgo(lastAt)}$errStr';
      subtitleColor = OpticsColors.warning;
    } else if (lastStatus == 'error' && lastAt != null) {
      subtitle = 'Last sync failed ${_formatAgo(lastAt)}';
      subtitleColor = OpticsColors.danger;
    } else {
      subtitle = s.summary;
    }

    String? progressLine;
    if (isSyncing && progress != null && (progress['total'] as int? ?? 0) > 0) {
      final total = progress['total'] as int;
      final done = ((progress['completed'] as int? ?? 0) + (progress['errored'] as int? ?? 0));
      final elapsed = progress['elapsed_ms'] as int? ?? 0;
      final eta = progress['eta_ms'] as int?;
      final pct = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
      final pctStr = '(${(pct * 100).round()}%)';
      String fmtMs(int ms) {
        final s = (ms / 1000).round();
        return s >= 60 ? '${s ~/ 60}m ${s % 60}s' : '${s}s';
      }
      final etaStr = eta != null ? ' · ~${fmtMs(eta)} left' : '';
      progressLine = '$done/$total tables $pctStr · ${fmtMs(elapsed)} elapsed$etaStr';
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OpticsSpacing.md,
        vertical: OpticsSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: OpticsColors.accentCyan.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
              border: Border.all(color: OpticsColors.accentCyan),
            ),
            child: const Icon(Icons.storage,
                size: 16, color: OpticsColors.accentCyan),
          ),
          const SizedBox(width: OpticsSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.name, style: OpticsTextStyles.body),
                const SizedBox(height: 2),
                Tooltip(
                  message: lastErr ?? '',
                  child: Text(
                    subtitle,
                    style: OpticsTextStyles.bodySm.copyWith(color: subtitleColor),
                  ),
                ),
                if (progressLine != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    progressLine,
                    style: const TextStyle(
                      fontSize: 11,
                      color: OpticsColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Auto-refresh cadence picker (editor+ can change; viewer sees disabled).
          if (ref.watch(canEditProvider)) ...[
            Tooltip(
              message: 'Scheduled auto-refresh',
              child: DropdownButton<int>(
                value: cadence,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: OpticsTextStyles.bodySm
                    .copyWith(color: OpticsColors.textPrimary),
                dropdownColor: OpticsColors.surface,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Auto: Off')),
                  DropdownMenuItem(value: 1, child: Text('Auto: 1m')),
                  DropdownMenuItem(value: 5, child: Text('Auto: 5m')),
                  DropdownMenuItem(value: 15, child: Text('Auto: 15m')),
                  DropdownMenuItem(value: 60, child: Text('Auto: 1h')),
                  DropdownMenuItem(value: 1440, child: Text('Auto: Daily')),
                ],
                onChanged: (v) {
                  if (v != null && v != cadence) _changeCadence(v);
                },
              ),
            ),
            const SizedBox(width: 8),
            // Manual refresh / cancel
            if (isSyncing)
              Tooltip(
                message: 'Cancel sync',
                child: IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: _cancelling ? null : _cancelSync,
                  icon: _cancelling
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.stop_circle_outlined,
                          color: OpticsColors.danger),
                ),
              )
            else
              Tooltip(
                message: 'Refresh data now (RDS → Network Analytics)',
                child: IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: _runRefresh,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            const SizedBox(width: 4),
          ],
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: _testing ? null : _runTest,
            child: _testing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Test'),
          ),
          const SizedBox(width: 8),
          // Edit/Delete: owner-only.
          if (ref.watch(isBryzosOwnerProvider).value ?? false) ...[
          IconButton(
            tooltip: 'Edit',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: () => showDialog(
              context: context,
              builder: (_) => _DataSourceDialog(
                tenantId: s.tenantId,
                existing: s,
              ),
            ).then((updated) {
              if (updated == true) {
                // ignore: unused_result
                ref.refresh(dataSourcesProvider);
              }
            }),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Delete',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            color: OpticsColors.danger,
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: OpticsColors.surface,
                  surfaceTintColor: Colors.transparent,
                  title: const Text('Delete data source?'),
                  content: Text(
                    'This will remove "${s.name}" and its stored credentials. '
                    'Widgets bound to this source will stop loading data.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: OpticsColors.danger,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (confirm != true) return;
              try {
                await ref.read(repoProvider).deleteDataSource(s.id);
                // ignore: unused_result
                ref.refresh(dataSourcesProvider);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Deleted "${s.name}"')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Delete failed: $e')),
                  );
                }
              }
            },
            icon: const Icon(Icons.delete_outline),
          ),
          ], // end owner-only Edit/Delete spread
        ],
      ),
    );
  }
}

/// Add or edit a data source. Currently supports `rest` (Bryzos-style) only;
/// the structure is ready for `mysql` to be re-introduced when needed.
class _DataSourceDialog extends ConsumerStatefulWidget {
  final String tenantId;
  final DataSource? existing;

  const _DataSourceDialog({required this.tenantId, this.existing});

  @override
  ConsumerState<_DataSourceDialog> createState() => _DataSourceDialogState();
}

class _DataSourceDialogState extends ConsumerState<_DataSourceDialog> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _authHeader;
  bool _busy = false;
  String? _err;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _apiKey = TextEditingController();
    _authHeader = TextEditingController(text: 'x-api-key');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _authHeader.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final repo = ref.read(repoProvider);
      final name = _name.text.trim();
      final baseUrl = _baseUrl.text.trim();
      final apiKey = _apiKey.text.trim();
      final authHeader = _authHeader.text.trim().isEmpty
          ? 'x-api-key'
          : _authHeader.text.trim();

      if (name.isEmpty) throw 'Name is required';
      if (baseUrl.isEmpty) throw 'Base URL is required';
      if (!_isEdit && apiKey.isEmpty) throw 'API Key is required';

      final config = <String, dynamic>{
        'base_url': baseUrl,
        'auth_header': authHeader,
        'provider': widget.existing?.provider.isNotEmpty == true
            ? widget.existing!.provider
            : 'rest',
      };

      if (_isEdit) {
        await repo.updateDataSource(widget.existing!.id, name, config);
        if (apiKey.isNotEmpty) {
          await repo.rotateDataSourceSecret(widget.existing!.id, apiKey: apiKey);
        }
      } else {
        await repo.createDataSource(
          tenantId: widget.tenantId,
          name: name,
          kind: 'rest',
          config: config,
          apiKey: apiKey,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: OpticsColors.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(
        (_isEdit ? 'Edit Data Source' : 'Add Data Source').toUpperCase(),
        style: OpticsTextStyles.headingLg,
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Connection Name', style: OpticsTextStyles.bodySm),
            const SizedBox(height: 4),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                hintText: 'e.g., Bryzos Marketing Hub API',
              ),
              autofocus: true,
            ),
            const SizedBox(height: OpticsSpacing.md),
            const Text('Base URL', style: OpticsTextStyles.bodySm),
            const SizedBox(height: 4),
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                hintText: 'https://api.example.com/Prod',
              ),
            ),
            const SizedBox(height: OpticsSpacing.md),
            const Text('Auth Header Name', style: OpticsTextStyles.bodySm),
            const SizedBox(height: 4),
            TextField(
              controller: _authHeader,
              decoration: const InputDecoration(hintText: 'x-api-key'),
            ),
            const SizedBox(height: OpticsSpacing.md),
            Text(
              _isEdit ? 'API Key (leave blank to keep current)' : 'API Key',
              style: OpticsTextStyles.bodySm,
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _apiKey,
              obscureText: true,
              decoration: InputDecoration(
                hintText: _isEdit ? '••••••••• (unchanged)' : 'Paste API key',
              ),
            ),
            if (_err != null) ...[
              const SizedBox(height: 12),
              Text(
                _err!,
                style: const TextStyle(color: OpticsColors.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
