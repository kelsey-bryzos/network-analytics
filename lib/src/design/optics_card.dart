import 'package:flutter/material.dart';
import 'theme.dart';

/// The standard Optics surface card.
///
/// Dark fill, 1px thin border, rounded corners ~12-16px, generous internal
/// padding, optional grab-handle and UPPERCASE title at top-left.
class OpticsCard extends StatelessWidget {
  final String? title;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool showGrabHandle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;

  /// When true, the child is wrapped in Expanded so it fills available space.
  /// Use this when the card is inside a bounded-height container (e.g., the
  /// widget grid). When false (default), the card sizes to fit its content.
  final bool expandChild;

  const OpticsCard({
    super.key,
    this.title,
    required this.child,
    this.padding = const EdgeInsets.all(OpticsSpacing.lg),
    this.showGrabHandle = false,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.expandChild = false,
  });

  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: OpticsColors.surface,
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        border: Border.all(
          color: selected ? OpticsColors.accentCyan : OpticsColors.border,
          width: 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: OpticsColors.accentCyan.withValues(alpha: 0.15),
                  blurRadius: 24,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (title != null || showGrabHandle || trailing != null)
            Padding(
              padding: const EdgeInsets.only(bottom: OpticsSpacing.md),
              child: Row(
                children: [
                  if (showGrabHandle) ...[
                    const _GrabHandle(),
                    const SizedBox(width: OpticsSpacing.sm),
                  ],
                  if (title != null)
                    Expanded(
                      child: Text(
                        title!.toUpperCase(),
                        style: const TextStyle(
                          fontFamily: 'Syncopate',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: OpticsColors.textPrimary,
                          letterSpacing: 1.4,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          if (expandChild) Expanded(child: child) else child,
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(OpticsRadii.md),
        onTap: onTap,
        child: card,
      ),
    );
  }
}

class _GrabHandle extends StatelessWidget {
  const _GrabHandle();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 10,
      height: 14,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(
          3,
          (_) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(
              2,
              (_) => Container(
                width: 2,
                height: 2,
                decoration: const BoxDecoration(
                  color: OpticsColors.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
