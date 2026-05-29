import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Wraps a scrollable canvas with Ctrl/Cmd+scroll zoom and trackpad pinch
/// zoom. Normal scroll events pass through to the child ScrollView.
///
/// Architecture:
///   • Normal scroll → passes through to child ScrollView (vertical scroll)
///   • Ctrl/Cmd+scroll (Windows/Mac) → zoom in/out toward cursor
///   • Trackpad pinch (PointerScaleEvent on macOS) → zoom in/out toward cursor
///   • "RESET VIEW" button appears when zoomed, animates back to 1:1
class CanvasZoom extends StatefulWidget {
  final Widget child;
  final double minScale;
  final double maxScale;

  const CanvasZoom({
    super.key,
    required this.child,
    this.minScale = 0.15,
    this.maxScale = 4.0,
  });

  @override
  State<CanvasZoom> createState() => _CanvasZoomState();
}

class _CanvasZoomState extends State<CanvasZoom>
    with SingleTickerProviderStateMixin {
  double _scale = 1.0;

  late final AnimationController _resetAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _resetFrom = 1.0;

  bool get _isZoomed => (_scale - 1.0).abs() > 0.001;

  @override
  void dispose() {
    _resetAnim.dispose();
    super.dispose();
  }

  void _animateResetView() {
    _resetFrom = _scale;
    _resetAnim
      ..reset()
      ..forward();
  }

  /// Check if Ctrl (Windows/Linux) or Cmd (macOS) is currently held.
  bool get _isZoomModifierHeld {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _isZoomModifierHeld) {
      // Ctrl/Cmd + scroll = ZOOM. Register with the resolver so the child
      // ScrollView does NOT also process this scroll event.
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (PointerSignalEvent resolved) {
          final scrollDy = (resolved as PointerScrollEvent).scrollDelta.dy;
          final zoomDelta = -scrollDy * 0.003;
          final newScale = (_scale + zoomDelta * _scale)
              .clamp(widget.minScale, widget.maxScale);
          if (newScale != _scale) {
            setState(() => _scale = newScale);
          }
        },
      );
    } else if (event is PointerScaleEvent) {
      // Trackpad pinch = ZOOM. Always claim.
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (PointerSignalEvent resolved) {
          final scaleFactor = (resolved as PointerScaleEvent).scale;
          final newScale = (_scale * scaleFactor)
              .clamp(widget.minScale, widget.maxScale);
          if (newScale != _scale) {
            setState(() => _scale = newScale);
          }
        },
      );
    }
    // Normal scroll (no modifier key): don't register — the child
    // ScrollView's own Listener will register and win, giving normal scroll.
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _resetAnim,
      builder: (context, _) {
        // During reset animation, interpolate scale back to 1.0
        double effectiveScale = _scale;
        if (_resetAnim.isAnimating) {
          final t = Curves.easeOutCubic.transform(_resetAnim.value);
          effectiveScale = _resetFrom + (1.0 - _resetFrom) * t;
        }
        if (_resetAnim.isCompleted && _scale != 1.0 && _resetFrom != 1.0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            setState(() {
              _scale = 1.0;
              _resetFrom = 1.0;
            });
          });
          effectiveScale = 1.0;
        }

        return Stack(
          children: [
            // ── Zoom-aware canvas ──
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerSignal: _onPointerSignal,
                child: Transform.scale(
                  scale: effectiveScale,
                  alignment: Alignment.topLeft,
                  child: widget.child,
                ),
              ),
            ),

            // ── Floating Reset View button ──
            if (_isZoomed || _resetAnim.isAnimating)
              Positioned(
                right: 12,
                bottom: 12,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: _isZoomed ? 1.0 : 0.0,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _animateResetView,
                      borderRadius: BorderRadius.circular(OpticsRadii.sm),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: OpticsColors.surfaceElevated
                              .withValues(alpha: 0.85),
                          borderRadius:
                              BorderRadius.circular(OpticsRadii.sm),
                          border:
                              Border.all(color: const Color(0x55FFFFFF)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.center_focus_strong_outlined,
                                size: 14, color: OpticsColors.textPrimary),
                            SizedBox(width: 6),
                            Text(
                              'RESET VIEW',
                              style: TextStyle(
                                fontFamily: 'Syncopate',
                                fontSize: 10,
                                color: OpticsColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
