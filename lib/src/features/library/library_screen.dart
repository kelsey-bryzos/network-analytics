import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/supabase_repo.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';

// ignore: unused_import

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _scope = 'all';
  String _kind = 'all';
  String _q = '';
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(libraryProvider);
    return Padding(
      padding: const EdgeInsets.all(OpticsSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('LIBRARY', style: OpticsTextStyles.headingXl),
              const SizedBox(width: 16),
              if (_selected.length == 2)
                ElevatedButton.icon(
                  icon: const Icon(Icons.merge_type, size: 16),
                  label: const Text('Combine'),
                  onPressed: _combineSelected,
                ),
              if (_selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: TextButton(
                    onPressed: () => setState(_selected.clear),
                    child: Text('Clear (${_selected.length})'),
                  ),
                ),
              const Spacer(),
              SizedBox(
                width: 280,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search metrics, widgets, dashboards…',
                    prefixIcon: Icon(Icons.search, size: 16),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (v) => setState(() => _q = v.toLowerCase()),
                ),
              ),
            ],
          ),
          const SizedBox(height: OpticsSpacing.lg),
          Row(
            children: [
              _filter('Scope', _scope, const ['all', 'system', 'tenant', 'user'],
                  (v) => setState(() => _scope = v)),
              const SizedBox(width: 16),
              _filter('Kind', _kind, const ['all', 'metric', 'widget', 'dashboard', 'report'],
                  (v) => setState(() => _kind = v)),
            ],
          ),
          const SizedBox(height: OpticsSpacing.lg),
          Expanded(
            child: items.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('$e',
                    style: const TextStyle(color: OpticsColors.danger)),
              ),
              data: (all) {
                final filtered = all.where((it) {
                  if (_scope != 'all' && it.scope != _scope) return false;
                  if (_kind != 'all' && it.kind != _kind) return false;
                  if (_q.isNotEmpty &&
                      !it.name.toLowerCase().contains(_q) &&
                      !it.category.toLowerCase().contains(_q)) {
                    return false;
                  }
                  return true;
                }).toList();
                if (filtered.isEmpty) {
                  return const Center(
                    child: Text('No items match your filters.',
                        style: OpticsTextStyles.bodySm),
                  );
                }
                return GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 280,
                    mainAxisExtent: 180,
                    crossAxisSpacing: OpticsSpacing.lg,
                    mainAxisSpacing: OpticsSpacing.lg,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final it = filtered[i];
                    final isSel = _selected.contains(it.id);
                    return GestureDetector(
                      onTap: () => _onCardTap(it.id, it.kind),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(OpticsRadii.md),
                          border: Border.all(
                            color: isSel
                                ? OpticsColors.accentCyan
                                : Colors.transparent,
                            width: isSel ? 1.5 : 0,
                          ),
                        ),
                        child: OpticsCard(
                          title: it.kind,
                          showGrabHandle: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(it.name.toUpperCase(),
                                  style: OpticsTextStyles.headingMd,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                              if (it.description != null) ...[
                                const SizedBox(height: 4),
                                Flexible(
                                  child: Text(
                                    it.description!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: OpticsTextStyles.bodySm,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              // Pills live on the left, Clone button (when
                              // the item is cloneable) is pinned to the
                              // right so it sits in a consistent place on
                              // every card it appears on.
                              Row(
                                children: [
                                  Expanded(
                                    child: Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      children: [
                                        _pill(it.category),
                                        _pill(it.scope),
                                      ],
                                    ),
                                  ),
                                  if (it.kind == 'report')
                                    OutlinedButton(
                                      onPressed: () => _cloneReport(it.id),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10, vertical: 4),
                                        minimumSize: Size.zero,
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        side: const BorderSide(
                                            color: OpticsColors.border),
                                      ),
                                      child: const Text('Clone',
                                          style: TextStyle(fontSize: 12)),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filter(String label, String value, List<String> opts,
      ValueChanged<String> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: OpticsTextStyles.sectionLabel),
        const SizedBox(width: 8),
        for (final o in opts)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () => onChanged(o),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: value == o
                      ? OpticsColors.accentCyan.withValues(alpha: 0.12)
                      : OpticsColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(OpticsRadii.sm),
                  border: Border.all(
                    color: value == o
                        ? OpticsColors.accentCyan
                        : OpticsColors.border,
                  ),
                ),
                child: Text(
                  o,
                  style: TextStyle(
                    fontSize: 12,
                    color: value == o
                        ? OpticsColors.accentCyan
                        : OpticsColors.textPrimary,
                    fontWeight: value == o ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _onCardTap(String id, String kind) {
    if (kind != 'metric' && kind != 'widget') return;
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else if (_selected.length < 2) {
        _selected.add(id);
      }
    });
  }

  Future<void> _combineSelected() async {
    if (_selected.length != 2) return;
    final ids = _selected.toList();
    final client = ref.read(supabaseProvider);
    final tid =
        client.auth.currentUser?.appMetadata['active_tenant_id'] as String?;
    final res = await client.functions.invoke(
      'combine-widgets',
      body: {'library_item_ids': ids, 'combo_type': 'dual-axis'},
      headers: tid == null ? {} : {'x-optics-tenant': tid},
    );
    if (!mounted) return;
    final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
    setState(_selected.clear);
    // ignore: unused_result
    ref.refresh(libraryProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Combined → ${data['name'] ?? 'new combo widget'}')),
    );
  }

  Future<void> _cloneReport(String libraryItemId) async {
    final client = ref.read(supabaseProvider);
    final tid =
        client.auth.currentUser?.appMetadata['active_tenant_id'] as String?;
    final res = await client.functions.invoke(
      'clone-canned-report',
      body: {'library_item_id': libraryItemId},
      headers: tid == null ? {} : {'x-optics-tenant': tid},
    );
    if (!mounted) return;
    final data = (res.data as Map?)?.cast<String, dynamic>() ?? {};
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cloned report: ${data['name'] ?? data['report_id']}')),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OpticsColors.surfaceElevated,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: OpticsColors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(
            fontSize: 12,
            color: OpticsColors.textSecondary,
            letterSpacing: 0.5),
      ),
    );
  }
}
