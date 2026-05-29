import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/theme.dart';

/// A small ⓘ icon that reveals the plain-English role definitions for
/// Viewer / Editor / Admin / Owner.
///
/// Behavior:
///   - Desktop / web:  hover OR click reveals the popover card.
///   - Mobile (iOS / Android):  hover (where present) AND tap both reveal it.
///
/// The popover content is sourced from /spec/ACCESS_RULES.md §7.1.
class RoleInfoTooltip extends StatefulWidget {
  const RoleInfoTooltip({super.key, this.size = 16});

  /// Diameter of the trigger icon, in logical pixels.
  final double size;

  @override
  State<RoleInfoTooltip> createState() => _RoleInfoTooltipState();
}

class _RoleInfoTooltipState extends State<RoleInfoTooltip> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  bool _hovering = false;

  bool get _isMobile {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _showOverlay() {
    if (_entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final renderBox =
        _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final anchorOffset = renderBox.localToGlobal(Offset.zero);
    final anchorSize = renderBox.size;

    _entry = OverlayEntry(
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final screen = mq.size;
        final padding = mq.padding;
        const cardWidth = 380.0;
        const margin = 12.0;
        const gap = 6.0;

        // Available vertical space above vs. below the anchor.
        final spaceBelow =
            screen.height - padding.bottom - (anchorOffset.dy + anchorSize.height) - gap - margin;
        final spaceAbove = anchorOffset.dy - padding.top - gap - margin;
        final placeBelow = spaceBelow >= spaceAbove;
        final maxHeight = (placeBelow ? spaceBelow : spaceAbove).clamp(120.0, double.infinity);

        // Horizontal: align with anchor, clamped inside screen.
        double left = anchorOffset.dx;
        if (left + cardWidth + margin > screen.width) {
          left = screen.width - cardWidth - margin;
        }
        if (left < margin) left = margin;

        final double top = placeBelow
            ? anchorOffset.dy + anchorSize.height + gap
            // Card is bottom-anchored when placed above; we measure from the
            // anchor's top minus the gap and the card's height. Since we don't
            // know height ahead of time, use a Positioned with `bottom`.
            : 0; // unused when placeBelow == false

        final double? bottom = placeBelow
            ? null
            : screen.height - (anchorOffset.dy - gap);

        return Stack(
          children: [
            // Tap-outside dismiss layer.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _removeOverlay,
              ),
            ),
            Positioned(
              left: left,
              top: placeBelow ? top : null,
              bottom: bottom,
              child: MouseRegion(
                onEnter: (_) {
                  _hovering = true;
                },
                onExit: (_) {
                  _hovering = false;
                  Future.delayed(const Duration(milliseconds: 120), () {
                    if (!_hovering) _removeOverlay();
                  });
                },
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: maxHeight,
                    maxWidth: cardWidth,
                  ),
                  child: _RoleInfoCard(width: cardWidth),
                ),
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(_entry!);
  }

  void _removeOverlay() {
    _entry?.remove();
    _entry = null;
  }

  void _toggleOverlay() {
    if (_entry == null) {
      _showOverlay();
    } else {
      _removeOverlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    final trigger = Icon(
      Icons.info_outline,
      size: widget.size,
      color: OpticsColors.textSecondary,
    );

    // On mobile we use tap-to-toggle. On desktop / web we use hover, but
    // we also accept a click so it works regardless of pointer device.
    return Semantics(
      label: 'Role definitions',
      button: true,
      child: MouseRegion(
        onEnter: _isMobile
            ? null
            : (_) {
                _hovering = true;
                _showOverlay();
              },
        onExit: _isMobile
            ? null
            : (_) {
                _hovering = false;
                Future.delayed(const Duration(milliseconds: 120), () {
                  if (!_hovering) _removeOverlay();
                });
              },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleOverlay,
          child: Padding(
            key: _anchorKey,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: trigger,
          ),
        ),
      ),
    );
  }
}

class _RoleInfoCard extends StatelessWidget {
  const _RoleInfoCard({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        decoration: BoxDecoration(
          color: OpticsColors.surfaceElevated,
          borderRadius: BorderRadius.circular(OpticsRadii.md),
          border: Border.all(color: OpticsColors.borderBright, width: 1),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(OpticsSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'TEAM ROLES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: OpticsColors.textSecondary,
                  letterSpacing: 1.2,
                ),
              ),
              SizedBox(height: OpticsSpacing.sm),
              _RoleRow(
                name: 'Viewer',
                blurb:
                    'Read-only. Browse all shared dashboards and reports, and apply '
                    'personal customizations to their own view. Cannot create '
                    'anything shared, invite teammates, or change tenant settings.',
              ),
              SizedBox(height: OpticsSpacing.md),
              _RoleRow(
                name: 'Editor',
                blurb:
                    'Everything a Viewer can do, plus build and share. Can create '
                    'new dashboards, reports, and widgets, and promote them to '
                    'tenant defaults. Can edit the company name and logo. '
                    'Cannot invite teammates.',
              ),
              SizedBox(height: OpticsSpacing.md),
              _RoleRow(
                name: 'Admin',
                blurb:
                    'Everything an Editor can do, plus user management. Can invite '
                    'new teammates as Viewer, Editor, or Admin, and change or '
                    'remove non-Owner members. Cannot grant the Owner role.',
              ),
              SizedBox(height: OpticsSpacing.md),
              _RoleRow(
                name: 'Owner',
                blurb:
                    'Full control of the tenant. Everything an Admin can do, plus '
                    'the exclusive ability to grant the Owner role to other '
                    'members. The last Owner cannot remove themselves.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleRow extends StatelessWidget {
  const _RoleRow({
    required this.name,
    required this.blurb,
  });

  final String name;
  final String blurb;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: OpticsColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          blurb,
          style: const TextStyle(
            fontSize: 12,
            height: 1.35,
            color: OpticsColors.textSecondary,
          ),
        ),
      ],
    );
  }
}
