import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/theme.dart';
import '../../platform/update_checker.dart';
import '../dashboards/dashboards_list_screen.dart' show activeDashboardIdProvider;

class _NavItem {
  final IconData icon;
  final String label;
  final String path;
  const _NavItem(this.icon, this.label, this.path);
}

const _navItems = [
  _NavItem(Icons.dashboard_outlined, 'Dashboards', '/dashboards'),
  _NavItem(Icons.description_outlined, 'Reports Library', '/reports'),
  _NavItem(Icons.travel_explore_outlined, 'Report Builder', '/reports/new'),
  _NavItem(Icons.settings_outlined, 'Settings', '/settings'),
];

class AppShell extends ConsumerStatefulWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _updateChecked = false;

  @override
  Widget build(BuildContext context) {
    // Run once per app lifetime, after the first authenticated frame.
    // No-op on web/macOS/iOS/Android; on Windows it polls latest.json and
    // prompts if a newer build is available.
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) UpdateChecker.checkOnStartup(context);
      });
    }
    final loc = GoRouterState.of(context).matchedLocation;
    return Scaffold(
      backgroundColor: OpticsColors.canvas,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const double topBarHeight = 66;
            const double sidebarWidth = 64;
            return Stack(
              children: [
                // Page content occupies the area below the topbar and to the
                // right of the sidebar. Painted FIRST so shadows from the
                // topbar and sidebar render on top of it.
                //
                // NOTE: The shell does NOT zoom/pan. Zoom is applied only
                // around the actual canvas inside each screen via
                // CanvasZoom — so header, sidebar, side panels, and toolbar
                // buttons stay at default position and scale.
                Positioned(
                  left: sidebarWidth,
                  top: topBarHeight,
                  right: 0,
                  bottom: 0,
                  child: widget.child,
                ),
                // Left sidebar — painted after content so its right-edge
                // shadow is visible.
                Positioned(
                  left: 0,
                  top: topBarHeight,
                  bottom: 0,
                  width: sidebarWidth,
                  child: _Sidebar(activePath: loc),
                ),
                // Top bar — painted last so its bottom drop-shadow is visible
                // over both the sidebar and the content beneath it.
                const Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  height: topBarHeight,
                  child: _TopBar(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final String activePath;
  const _Sidebar({required this.activePath});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      decoration: const BoxDecoration(
        // ERP sidebar tier (#222329) — distinctly lifted off the canvas
        // for sharp visual separation.
        color: OpticsColors.surfaceElevated,
        border: Border(
          right: BorderSide(color: Color(0x1AFFFFFF)), // ERP borderSidebar
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0xE8000000),
            offset: Offset(5.5, 0),
            blurRadius: 4.4,
            spreadRadius: -3,
          ),
        ],
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          for (final item in _navItems) _NavButton(item, activePath),
          const Spacer(),
          IconButton(
            tooltip: 'Help',
            icon: const Icon(Icons.help_outline),
            onPressed: () => context.go('/help'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final _NavItem item;
  final String activePath;
  const _NavButton(this.item, this.activePath);

  /// `startsWith` alone is ambiguous when multiple nav items share a prefix
  /// (e.g. `/reports` vs `/reports/new`). Pick the most-specific nav item:
  /// only treat this button as active if no *other* nav item has a longer
  /// prefix that also matches the current path.
  ///
  /// Special case: report-edit routes like `/reports/<id>/edit` are part of
  /// the Report Builder flow, so they should highlight Report Builder
  /// rather than Reports Library even though they share the `/reports`
  /// prefix.
  bool _isActive() {
    // /reports/:id/edit → Report Builder.
    final editRe = RegExp('^/reports/[^/]+/edit/?\u0024');
    if (editRe.hasMatch(activePath)) {
      return item.path == '/reports/new';
    }

    final candidates = _navItems
        .where((n) =>
            activePath == n.path || activePath.startsWith('${n.path}/'))
        .toList();
    if (candidates.isEmpty) return false;
    candidates.sort((a, b) => b.path.length.compareTo(a.path.length));
    return candidates.first.path == item.path;
  }

  @override
  Widget build(BuildContext context) {
    final active = _isActive();
    return Tooltip(
      message: item.label,
      child: GestureDetector(
        onTap: () => context.go(item.path),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: active
                ? OpticsColors.accentCyan.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(OpticsRadii.sm),
            border: Border.all(
              color: active ? OpticsColors.accentCyan : Colors.transparent,
              width: 1,
            ),
          ),
          child: Icon(
            item.icon,
            size: 20,
            color:
                active ? OpticsColors.accentCyan : OpticsColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    final tenantAsync = ref.watch(activeTenantObjectProvider);

    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: OpticsSpacing.xl),
      decoration: const BoxDecoration(
        // ERP header sits on canvas (#0F0F14); depth comes from the
        // bright white-alpha bottom border + drop shadow.
        color: OpticsColors.canvas,
        border: Border(
          bottom: BorderSide(color: Color(0x33FFFFFF)), // ERP borderHeader
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0xE8000000),
            offset: Offset(0, 5.5),
            blurRadius: 4.4,
            spreadRadius: -3,
          ),
        ],
      ),
      child: Row(
        children: [
          // Logo area (far left) — image at 58px tall, centered in 66px header
          SizedBox(
            width: 200, // reserved for logo / company name
            child: tenantAsync.when(
              data: (tenant) {
                // Consistent text fallback style — Inter 13px bold, no Syncopate
                const fallbackStyle = TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: OpticsColors.textPrimary,
                  letterSpacing: 0.3,
                  overflow: TextOverflow.ellipsis,
                );
                if (tenant?.logoUrl != null && tenant!.logoUrl!.isNotEmpty) {
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: tenant.logoUrl!.startsWith('http')
                      ? Image.network(
                          tenant.logoUrl!,
                          height: 58,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              Text(tenant.name, style: fallbackStyle, maxLines: 1),
                        )
                      : Image.asset(
                          tenant.logoUrl!,
                          height: 58,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              Text(tenant.name, style: fallbackStyle, maxLines: 1),
                        ),
                  );
                }
                return Text(
                  tenant?.name ?? '',
                  style: fallbackStyle,
                  maxLines: 1,
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),
          
          const Spacer(),
          
          // Centered Search Bar
          const SizedBox(width: 380, child: _GlobalSearch()),
          
          const Spacer(),
          
          // Right actions
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_outlined),
            onPressed: () {},
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: 'Account',
            position: PopupMenuPosition.under,
            color: OpticsColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
              side: const BorderSide(color: OpticsColors.border),
            ),
            onSelected: (value) {
              if (value == 'signout') {
                Supabase.instance.client.auth.signOut();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Signed in as',
                        style: TextStyle(
                            fontSize: 12,
                            color: OpticsColors.textSecondary)),
                    const SizedBox(height: 2),
                    Text(email,
                        style: const TextStyle(
                            fontSize: 13,
                            color: OpticsColors.textPrimary,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'signout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 16, color: OpticsColors.danger),
                    SizedBox(width: 8),
                    Text('Sign out',
                        style: TextStyle(
                            fontSize: 13, color: OpticsColors.danger)),
                  ],
                ),
              ),
            ],
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: OpticsColors.surface,
                borderRadius: BorderRadius.circular(OpticsRadii.sm),
                border: Border.all(color: OpticsColors.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: OpticsColors.accentViolet,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      email.isNotEmpty ? email[0].toUpperCase() : '?',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    email,
                    style: const TextStyle(
                      fontSize: 12,
                      color: OpticsColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_arrow_down,
                      size: 14, color: OpticsColors.textSecondary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Global Search (header)
// Pulls from dashboards / reports / library and shows an overlay dropdown of
// matches. Selecting a result navigates to the right destination.
// ─────────────────────────────────────────────────────────────────────────────

class _SearchHit {
  final String kind; // 'dashboard' | 'report' | 'library'
  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color iconColor;
  final void Function(BuildContext, WidgetRef) onSelect;
  const _SearchHit({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.onSelect,
  });
}

class _GlobalSearch extends ConsumerStatefulWidget {
  const _GlobalSearch();
  @override
  ConsumerState<_GlobalSearch> createState() => _GlobalSearchState();
}

class _GlobalSearchState extends ConsumerState<_GlobalSearch> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _layerLink = LayerLink();
  OverlayEntry? _overlay;
  String _q = '';
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _q.isNotEmpty) {
        _showOverlay();
      } else if (!_focusNode.hasFocus) {
        // Delay so a tap on a result can fire before we tear the overlay down.
        Future.delayed(const Duration(milliseconds: 150), _hideOverlay);
      }
    });
  }

  @override
  void dispose() {
    _hideOverlay();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _showOverlay() {
    _hideOverlay();
    final overlay = Overlay.of(context);
    _overlay = OverlayEntry(builder: (_) => _buildOverlay());
    overlay.insert(_overlay!);
  }

  void _hideOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _onChanged(String v) {
    setState(() {
      _q = v.trim();
      _highlight = 0;
    });
    if (_q.isEmpty) {
      _hideOverlay();
    } else if (_overlay == null) {
      _showOverlay();
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  List<_SearchHit> _compute(
    List<Dashboard> dashboards,
    List<Report> reports,
    List<LibraryItem> library,
  ) {
    final q = _q.toLowerCase();
    if (q.isEmpty) return const [];
    bool match(String? s) => s != null && s.toLowerCase().contains(q);

    final hits = <_SearchHit>[];

    for (final d in dashboards) {
      if (match(d.name) || match(d.description)) {
        hits.add(_SearchHit(
          kind: 'dashboard',
          id: d.id,
          title: d.name,
          subtitle: d.description ?? 'Dashboard',
          icon: Icons.dashboard_outlined,
          iconColor: OpticsColors.accentCyan,
          onSelect: (ctx, ref) {
            ref.read(activeDashboardIdProvider.notifier).state = d.id;
            ctx.go('/dashboards');
          },
        ));
      }
    }
    for (final r in reports) {
      if (match(r.name) || match(r.description) || match(r.category)) {
        hits.add(_SearchHit(
          kind: 'report',
          id: r.id,
          title: r.name,
          subtitle: [
            if (r.category.isNotEmpty) r.category,
            r.isCanned ? 'Canned report' : 'Custom report',
          ].join(' · '),
          icon: Icons.description_outlined,
          iconColor: OpticsColors.accentViolet,
          onSelect: (ctx, _) =>
              ctx.go('/reports/${Uri.encodeComponent(r.id)}'),
        ));
      }
    }
    for (final it in library) {
      if (match(it.name) ||
          match(it.description) ||
          match(it.category) ||
          it.tags.any((t) => t.toLowerCase().contains(q))) {
        IconData icon;
        Color color;
        switch (it.kind) {
          case 'metric':
            icon = Icons.insights_outlined;
            color = OpticsColors.accentGreen;
            break;
          case 'widget':
            icon = Icons.widgets_outlined;
            color = OpticsColors.accentOrange;
            break;
          case 'dashboard':
            icon = Icons.dashboard_outlined;
            color = OpticsColors.accentCyan;
            break;
          case 'report':
            icon = Icons.description_outlined;
            color = OpticsColors.accentViolet;
            break;
          default:
            icon = Icons.bookmark_outline;
            color = OpticsColors.textSecondary;
        }
        hits.add(_SearchHit(
          kind: 'library',
          id: it.id,
          title: it.name,
          subtitle: [
            it.kind[0].toUpperCase() + it.kind.substring(1),
            if (it.category.isNotEmpty) it.category,
          ].join(' · '),
          icon: icon,
          iconColor: color,
          onSelect: (ctx, _) => ctx.go('/library'),
        ));
      }
    }

    // Rank: prefix match on title first, then contains.
    hits.sort((a, b) {
      final ap = a.title.toLowerCase().startsWith(q) ? 0 : 1;
      final bp = b.title.toLowerCase().startsWith(q) ? 0 : 1;
      if (ap != bp) return ap - bp;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return hits.take(20).toList();
  }

  void _pick(_SearchHit hit) {
    hit.onSelect(context, ref);
    _controller.clear();
    setState(() => _q = '');
    _focusNode.unfocus();
    _hideOverlay();
  }

  Widget _buildOverlay() {
    final dashboards =
        ref.read(dashboardsListProvider).valueOrNull ?? const <Dashboard>[];
    final reports =
        ref.read(reportsProvider).valueOrNull ?? const <Report>[];
    final library =
        ref.read(libraryProvider).valueOrNull ?? const <LibraryItem>[];
    final hits = _compute(dashboards, reports, library);

    return Positioned(
      width: 380,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: const Offset(0, 38),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxHeight: 420),
            decoration: BoxDecoration(
              color: OpticsColors.surfaceElevated,
              borderRadius: BorderRadius.circular(OpticsRadii.md),
              border: Border.all(color: OpticsColors.border),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 16,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: hits.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      _q.isEmpty
                          ? 'Start typing to search…'
                          : 'No matches for "$_q".',
                      style: const TextStyle(
                        fontSize: 12,
                        color: OpticsColors.textSecondary,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    shrinkWrap: true,
                    itemCount: hits.length,
                    itemBuilder: (ctx, i) {
                      final h = hits[i];
                      final selected = i == _highlight;
                      return InkWell(
                        onTap: () => _pick(h),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          color: selected
                              ? OpticsColors.accentCyan.withValues(alpha: 0.08)
                              : Colors.transparent,
                          child: Row(
                            children: [
                              Icon(h.icon, size: 16, color: h.iconColor),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      h.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: OpticsColors.textPrimary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    if (h.subtitle != null &&
                                        h.subtitle!.isNotEmpty)
                                      Text(
                                        h.subtitle!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: OpticsColors.textSecondary,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: OpticsColors.surface,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: OpticsColors.border),
                                ),
                                child: Text(
                                  h.kind,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: OpticsColors.textSecondary,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final dashboards =
        ref.read(dashboardsListProvider).valueOrNull ?? const <Dashboard>[];
    final reports = ref.read(reportsProvider).valueOrNull ?? const <Report>[];
    final library =
        ref.read(libraryProvider).valueOrNull ?? const <LibraryItem>[];
    final hits = _compute(dashboards, reports, library);
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _controller.clear();
      setState(() => _q = '');
      _focusNode.unfocus();
      _hideOverlay();
      return KeyEventResult.handled;
    }
    if (hits.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % hits.length);
      _overlay?.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() =>
          _highlight = (_highlight - 1 + hits.length) % hits.length);
      _overlay?.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _pick(hits[_highlight]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Focus(
        onKeyEvent: _handleKey,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: 'Search dashboards, reports, widgets…',
            prefixIcon: const Icon(Icons.search, size: 16),
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close, size: 14),
                    splashRadius: 14,
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(OpticsRadii.sm),
              borderSide: const BorderSide(color: OpticsColors.border),
            ),
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }
}
