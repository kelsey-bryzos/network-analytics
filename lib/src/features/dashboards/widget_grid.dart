import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../design/theme.dart';
import 'widget_renderer.dart';

/// Free-form widget canvas with ERP-style drag/resize mechanics plus
/// auto-collision resolution so tiles never overlap.
///
/// Mechanics:
/// - Drag: ERP-style absolute-global tracking. Visual offset only during the
///   drag; integer-snap + collision resolution on release.
/// - Resize: absolute-global tracking, **commits live** every cell crossing,
///   each commit running the collision resolver so neighbours shift in real
///   time as the widget grows.
/// - Collision strategy: any widget the moved/resized tile overlaps gets
///   pushed DOWN to sit immediately below it. Cascaded collisions repeat the
///   same rule until the layout is conflict-free (react-grid-layout style).
/// - 10px visual gap: every cell renders inside a 5px inset so adjacent
///   widgets show a clean 10px gutter without changing the cell math.
/// - Active widget renders on top of the Z-stack so the user never loses
///   sight of the tile while dragging or resizing.
class WidgetGrid extends StatefulWidget {
  final List<WidgetModel> widgets;
  final WidgetModel? selectedId;
  final ValueChanged<WidgetModel> onChanged;
  final ValueChanged<WidgetModel> onSelect;
  final ValueChanged<WidgetModel>? onDelete;
  final void Function(List<WidgetModel> updatedList)? onSwap;
  final int columns;
  final double cellHeight;
  final bool canEdit;

  const WidgetGrid({
    super.key,
    required this.widgets,
    required this.onChanged,
    required this.onSelect,
    this.onDelete,
    this.selectedId,
    this.onSwap,
    this.columns = 48,
    this.cellHeight = 24,
    this.canEdit = true,
  });

  @override
  State<WidgetGrid> createState() => _WidgetGridState();
}

class _WidgetGridState extends State<WidgetGrid> {
  // ── Drag state ──────────────────────────────────────────────
  String? _draggingId;
  Offset _dragOffset = Offset.zero;   // visual offset only
  double _dragStartGX = 0;
  double _dragStartGY = 0;
  double _dragOrigX = 0;              // cells
  double _dragOrigY = 0;              // cells

  // ── Resize state ────────────────────────────────────────────
  String? _resizingId;
  double _rzStartGX = 0;
  double _rzStartGY = 0;
  double _rzOrigW = 0;                // cells
  double _rzOrigH = 0;                // cells

  @override
  Widget build(BuildContext context) {
    if (widget.widgets.isEmpty) {
      return const Center(
        child: Text('No widgets',
            style: TextStyle(color: OpticsColors.textMuted)),
      );
    }

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final cellW = constraints.maxWidth / widget.columns;
        final cellH = widget.cellHeight;

        // Canvas auto-grows so widgets can be dragged below the current
        // footprint. Add 400px headroom so the user has somewhere to drop.
        double maxBottom = 0;
        for (final w in widget.widgets) {
          final bottom = (w.y + w.h) * cellH;
          if (bottom > maxBottom) maxBottom = bottom;
        }
        final contentHeight = maxBottom + 400;
        final canvasHeight = contentHeight < constraints.maxHeight
            ? constraints.maxHeight
            : contentHeight;

        // Render order: active (dragging/resizing) widget LAST so it sits on
        // top of the Z-stack and is never hidden behind others.
        final ordered = [...widget.widgets];
        ordered.sort((a, b) {
          final aActive = a.id == _draggingId || a.id == _resizingId;
          final bActive = b.id == _draggingId || b.id == _resizingId;
          if (aActive == bActive) return 0;
          return aActive ? 1 : -1;
        });

        // Reserve a right-side gutter so the canvas content and widget
        // resize handles never sit under the page scrollbar.  The scrollbar
        // on most platforms is 12–16 px wide; 16 px gives a comfortable gap
        // regardless of OS/browser.
        const double _scrollbarGutter = 16.0;
        final canvasWidth = constraints.maxWidth - _scrollbarGutter;
        // Recompute cellW against the safe canvas width so column math stays
        // consistent (widgets do not drift right as the gutter is applied).
        final safeCellW = canvasWidth / widget.columns;

        return SingleChildScrollView(
          child: SizedBox(
            width: constraints.maxWidth,
            height: canvasHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Safe canvas area (widgets + resize handles live here) ──
                SizedBox(
                  width: canvasWidth,
                  height: canvasHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final w in ordered)
                        _buildWidget(w, safeCellW, cellH, canvasHeight),
                    ],
                  ),
                ),
                // ── Scrollbar gutter — empty, touch/click falls through to
                //    the native page scrollbar without hitting any widget ──
                const SizedBox(width: _scrollbarGutter),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildWidget(
      WidgetModel w, double cellW, double cellH, double canvasH) {
    final isDragging = _draggingId == w.id;
    final isResizing = _resizingId == w.id;

    final left = w.x * cellW + (isDragging ? _dragOffset.dx : 0);
    final top = w.y * cellH + (isDragging ? _dragOffset.dy : 0);
    final width = w.w * cellW;
    final height = w.h * cellH;

    return Positioned(
      key: ValueKey(w.id),
      left: left,
      top: top,
      width: width,
      height: height,
      // 5px inset on each side = 10px gutter between adjacent cells.
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: GridCell(
          model: w,
          selected: widget.selectedId?.id == w.id,
          isDragging: isDragging,
          isResizing: isResizing,
          canEdit: widget.canEdit,
          onTap: widget.canEdit ? () => widget.onSelect(w) : null,
          onSettingsTap:
              widget.canEdit ? () => widget.onSelect(w) : null,
          onDeleteTap: (widget.canEdit && widget.onDelete != null)
              ? () => widget.onDelete!(w)
              : null,
          // ── Drag (header bar) — absolute-global tracking ────
          onDragStart: !widget.canEdit
              ? null
              : (globalPos) {
                  setState(() {
                    _draggingId = w.id;
                    _dragOffset = Offset.zero;
                    _dragStartGX = globalPos.dx;
                    _dragStartGY = globalPos.dy;
                    _dragOrigX = w.x;
                    _dragOrigY = w.y;
                  });
                },
          onDragUpdate: !widget.canEdit
              ? null
              : (globalPos) {
                  setState(() {
                    _dragOffset = Offset(
                      globalPos.dx - _dragStartGX,
                      globalPos.dy - _dragStartGY,
                    );
                  });
                },
          onDragEnd: !widget.canEdit
              ? null
              : () {
                  final colDelta = (_dragOffset.dx / cellW).round();
                  final rowDelta = (_dragOffset.dy / cellH).round();
                  final maxX = (widget.columns - w.w).toDouble();
                  final newX =
                      (_dragOrigX + colDelta).clamp(0.0, maxX);
                  final newY = (_dragOrigY + rowDelta)
                      .clamp(0.0, double.infinity);
                  final moved = w.copyWith(x: newX, y: newY);
                  _commitChange(moved);
                  setState(() {
                    _draggingId = null;
                    _dragOffset = Offset.zero;
                  });
                },
          // ── Resize (corner grip) — absolute-global, commits live ──
          onResizeStart: !widget.canEdit
              ? null
              : (globalPos) {
                  setState(() {
                    _resizingId = w.id;
                    _rzStartGX = globalPos.dx;
                    _rzStartGY = globalPos.dy;
                    _rzOrigW = w.w;
                    _rzOrigH = w.h;
                  });
                },
          onResizeUpdate: !widget.canEdit
              ? null
              : (globalPos) {
                  final dx = globalPos.dx - _rzStartGX;
                  final dy = globalPos.dy - _rzStartGY;
                  final colDelta = (dx / cellW).round();
                  final rowDelta = (dy / cellH).round();
                  const minW = 4.0;
                  const minH = 3.0;
                  final maxAvailW =
                      (widget.columns - w.x).toDouble();
                  final newW =
                      (_rzOrigW + colDelta).clamp(minW, maxAvailW);
                  final newH = (_rzOrigH + rowDelta).clamp(minH, 1000.0);
                  if (newW != w.w || newH != w.h) {
                    _commitChange(w.copyWith(w: newW, h: newH));
                  }
                },
          onResizeEnd: !widget.canEdit
              ? null
              : () {
                  setState(() {
                    _resizingId = null;
                  });
                },
        ),
      ),
    );
  }

  /// Commits a moved/resized widget AND resolves any resulting collisions by
  /// pushing other widgets downward until the layout is conflict-free.
  void _commitChange(WidgetModel moved) {
    final resolved = _resolveCollisions(moved, widget.widgets);
    if (widget.onSwap != null) {
      widget.onSwap!(resolved);
    } else {
      // No bulk callback wired — fall back to single-widget update.
      widget.onChanged(moved);
    }
  }

  /// Push-down collision resolver (react-grid-layout style).
  /// The moved widget is treated as fixed; every widget it (transitively)
  /// overlaps gets bumped down so its top edge sits at the bottom of the
  /// thing that pushed it. Cascades naturally until stable.
  List<WidgetModel> _resolveCollisions(
      WidgetModel moved, List<WidgetModel> all) {
    final result = <WidgetModel>[];
    for (final w in all) {
      result.add(w.id == moved.id ? moved : w);
    }

    final queue = <String>[moved.id];
    var safety = 0;
    while (queue.isNotEmpty && safety++ < 500) {
      final currentId = queue.removeAt(0);
      final cIdx = result.indexWhere((x) => x.id == currentId);
      if (cIdx < 0) continue;
      final c = result[cIdx];
      for (int i = 0; i < result.length; i++) {
        if (result[i].id == currentId) continue;
        final other = result[i];
        if (_overlaps(c, other)) {
          final newY = c.y + c.h;
          if (newY != other.y) {
            result[i] = other.copyWith(y: newY);
            queue.add(other.id);
          }
        }
      }
    }
    return result;
  }

  bool _overlaps(WidgetModel a, WidgetModel b) {
    return a.x < b.x + b.w &&
        a.x + a.w > b.x &&
        a.y < b.y + b.h &&
        a.y + a.h > b.y;
  }
}

// ─── Grid Cell ─────────────────────────────────────────────────────

class GridCell extends StatefulWidget {
  final WidgetModel model;
  final bool selected;
  final bool isDragging;
  final bool isResizing;
  final bool canEdit;
  final VoidCallback? onTap;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onDeleteTap;
  final void Function(Offset globalPos)? onDragStart;
  final void Function(Offset globalPos)? onDragUpdate;
  final VoidCallback? onDragEnd;
  final void Function(Offset globalPos)? onResizeStart;
  final void Function(Offset globalPos)? onResizeUpdate;
  final VoidCallback? onResizeEnd;

  const GridCell({
    super.key,
    required this.model,
    required this.selected,
    required this.isDragging,
    required this.isResizing,
    this.canEdit = true,
    this.onTap,
    this.onSettingsTap,
    this.onDeleteTap,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onResizeStart,
    this.onResizeUpdate,
    this.onResizeEnd,
  });

  @override
  State<GridCell> createState() => _GridCellState();
}

class _GridCellState extends State<GridCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final wt = WidgetThemeColors.fromSettings(widget.model.settings);
    final showChrome =
        _hovered || widget.isDragging || widget.isResizing || widget.selected;

    final borderColor = widget.isDragging
        ? OpticsColors.accentCyan.withValues(alpha: 0.55)
        : showChrome
            ? OpticsColors.accentCyan.withValues(alpha: 0.25)
            : wt.border;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) {
        if (!widget.isResizing) setState(() => _hovered = false);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: wt.cardBg,
          borderRadius: BorderRadius.circular(OpticsRadii.md),
          border: Border.all(
            color: borderColor,
            width: widget.isDragging ? 1.2 : 0.8,
          ),
          boxShadow: widget.isDragging
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                    spreadRadius: 1,
                    offset: const Offset(0, 8),
                  ),
                ]
              : showChrome
                  ? [
                      BoxShadow(
                        color:
                            OpticsColors.accentCyan.withValues(alpha: 0.08),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(OpticsRadii.md),
              child: Column(
                children: [
                  _WidgetHeader(
                    title: widget.model.title,
                    showActions: showChrome && widget.canEdit,
                    widgetSettings: widget.model.settings,
                    onSettingsTap: widget.onSettingsTap,
                    onDeleteTap: widget.onDeleteTap,
                    onDragStart: widget.onDragStart,
                    onDragUpdate: widget.onDragUpdate,
                    onDragEnd: widget.onDragEnd,
                  ),
                  Expanded(
                    child: widget.canEdit
                        ? GestureDetector(
                            onTap: widget.onTap,
                            behavior: HitTestBehavior.translucent,
                            child: WidgetRenderer(
                              model: widget.model,
                              selected: widget.selected,
                              chromeless: true,
                            ),
                          )
                        : IgnorePointer(
                            child: WidgetRenderer(
                              model: widget.model,
                              selected: widget.selected,
                              chromeless: true,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            if (showChrome &&
                widget.canEdit &&
                widget.onResizeStart != null &&
                widget.onResizeUpdate != null &&
                widget.onResizeEnd != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: _CornerHandle(
                  active: widget.isResizing,
                  onPanStart: widget.onResizeStart!,
                  onPanUpdate: widget.onResizeUpdate!,
                  onPanEnd: widget.onResizeEnd!,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Top Drag Header (UPPERCASE title + ⋮⋮ grip + actions) ────────

class _WidgetHeader extends StatefulWidget {
  final String title;
  final bool showActions;
  final Map<String, dynamic> widgetSettings;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onDeleteTap;
  final void Function(Offset globalPos)? onDragStart;
  final void Function(Offset globalPos)? onDragUpdate;
  final VoidCallback? onDragEnd;

  const _WidgetHeader({
    required this.title,
    required this.showActions,
    required this.widgetSettings,
    required this.onSettingsTap,
    required this.onDeleteTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_WidgetHeader> createState() => _WidgetHeaderState();
}

class _WidgetHeaderState extends State<_WidgetHeader> {
  bool _dragging = false;
  int? _dragPointer; // track which pointer started the drag

  @override
  Widget build(BuildContext context) {
    // Use a raw Listener so we only respond to primary-button pointer events
    // (click-and-drag). GestureDetector's onPan* can be triggered by trackpad
    // scroll momentum on macOS, which causes widgets to drift when the user
    // is just scrolling the page.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (widget.onDragStart == null) return;
        if (event.kind == PointerDeviceKind.touch ||
            event.buttons == kPrimaryButton) {
          _dragging = true;
          _dragPointer = event.pointer;
          widget.onDragStart!(event.position);
        }
      },
      onPointerMove: (event) {
        if (_dragging && event.pointer == _dragPointer) {
          widget.onDragUpdate?.call(event.position);
        }
      },
      onPointerUp: (event) {
        if (_dragging && event.pointer == _dragPointer) {
          _dragging = false;
          _dragPointer = null;
          widget.onDragEnd?.call();
        }
      },
      onPointerCancel: (event) {
        if (_dragging && event.pointer == _dragPointer) {
          _dragging = false;
          _dragPointer = null;
          widget.onDragEnd?.call();
        }
      },
      child: MouseRegion(
        cursor: widget.onDragStart == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.grab,
        child: Builder(builder: (context) {
          final wt = WidgetThemeColors.fromSettings(widget.widgetSettings);
          return Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: wt.headerBg,
            border: Border(
              bottom: BorderSide(color: wt.headerBorder, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              if (widget.onDragStart != null) ...[
                Tooltip(
                  message: 'Drag to move widget',
                  child: Icon(Icons.drag_indicator_rounded,
                      size: 14, color: wt.mutedText),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  widget.title.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'Syncopate',
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: wt.titleText,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: widget.showActions ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !widget.showActions,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onSettingsTap != null)
                        _HdrBtn(
                          icon: Icons.tune_rounded,
                          tooltip: 'Settings',
                          onTap: widget.onSettingsTap!,
                        ),
                      if (widget.onDeleteTap != null)
                        _HdrBtn(
                          icon: Icons.close_rounded,
                          tooltip: 'Remove',
                          onTap: widget.onDeleteTap!,
                          danger: true,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        }),
      ),
    );
  }
}

class _HdrBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;
  const _HdrBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });
  @override
  State<_HdrBtn> createState() => _HdrBtnState();
}

class _HdrBtnState extends State<_HdrBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final activeColor =
        widget.danger ? OpticsColors.danger : OpticsColors.accentCyan;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hover
                  ? activeColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 12,
              color: _hover ? activeColor : OpticsColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Bottom-right corner resize grip ──────────────────────────────

class _CornerHandle extends StatelessWidget {
  final bool active;
  final void Function(Offset globalPos) onPanStart;
  final void Function(Offset globalPos) onPanUpdate;
  final VoidCallback onPanEnd;

  const _CornerHandle({
    required this.active,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeDownRight,
      child: Tooltip(
        message: 'Drag to resize',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => onPanStart(d.globalPosition),
          onPanUpdate: (d) => onPanUpdate(d.globalPosition),
          onPanEnd: (_) => onPanEnd(),
          onPanCancel: onPanEnd,
          child: SizedBox(
            width: 20,
            height: 20,
            child: CustomPaint(
              painter: _CornerGripPainter(
                color: active
                    ? OpticsColors.accentCyan.withValues(alpha: 0.85)
                    : OpticsColors.accentCyan.withValues(alpha: 0.35),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CornerGripPainter extends CustomPainter {
  final Color color;
  _CornerGripPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const m = 4.0;
    // Three short diagonal strokes — the classic corner-grip mark.
    canvas.drawLine(
        Offset(size.width - m, size.height - m - 10),
        Offset(size.width - m, size.height - m), paint);
    canvas.drawLine(
        Offset(size.width - m - 10, size.height - m),
        Offset(size.width - m, size.height - m), paint);
    canvas.drawLine(
        Offset(size.width - m - 8, size.height - m - 8),
        Offset(size.width - m - 2, size.height - m - 2), paint);
    canvas.drawLine(
        Offset(size.width - m - 4, size.height - m - 4),
        Offset(size.width - m, size.height - m), paint);
  }

  @override
  bool shouldRepaint(_CornerGripPainter old) => old.color != color;
}
