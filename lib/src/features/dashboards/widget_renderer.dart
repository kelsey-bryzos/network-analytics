import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../data/supabase_repo.dart';
import '../../design/optics_card.dart';
import '../../design/theme.dart';
import 'time_range_options.dart';

/// Number formatter for compact display (1.2K, 3.4M, etc.)
String _fmtNum(double v) {
  if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (v.abs() >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(1);
}

/// Full number format with commas
String _fmtFull(double v) {
  if (v == v.roundToDouble()) {
    return NumberFormat('#,##0').format(v.toInt());
  }
  return NumberFormat('#,##0.0').format(v);
}

/// Smart dollar formatter — picks the right unit scale, never shows $0.0M for sub-million values.
String _fmtSmartMoney(double v) {
  if (v.abs() >= 1e6) return '\$${(v / 1e6).toStringAsFixed(2)}M';
  if (v.abs() >= 1e3) return '\$${(v / 1e3).toStringAsFixed(1)}K';
  return '\$${v.toStringAsFixed(2)}';
}

/// Exact dollar format with commas and 2 decimals
String _fmtExactMoney(double v) {
  return NumberFormat('\$#,##0.00').format(v);
}

/// Smart value formatter: dollar-prefixed with correct scale if unit contains $, else compact number.
/// Applies unit multiplier ($K → ×1000, $M → ×1e6) so axis labels show correct scale.
String _fmtSmartValue(double v, String unit) {
  final mult = unit == r'$M' ? 1e6 : unit == r'$K' ? 1e3 : 1.0;
  final scaled = v * mult;
  if (unit.contains(r'$')) return _fmtSmartMoney(scaled);
  return _fmtNum(scaled);
}

List<Color> _paletteFor(String? scheme) {
  switch (scheme?.toLowerCase()) {
    case 'cool':
      return const [
        Color(0xFF3DB8FF), Color(0xFF7DD3FC), Color(0xFF9B7BFF),
        Color(0xFF818CF8), Color(0xFF34D399), Color(0xFF6EE7B7),
        Color(0xFF67E8F9), Color(0xFFA5F3FC), Color(0xFFE879F9),
      ];
    case 'warm':
      return const [
        Color(0xFFFFA850), Color(0xFFFBBF24), Color(0xFFFF7AC6),
        Color(0xFFFF6B6B), Color(0xFFFCA5A5), Color(0xFFFDE68A),
        Color(0xFFF9A8D4), Color(0xFFFB923C), Color(0xFFEF4444),
      ];
    case 'mono':
      return const [
        Color(0xFFE6E8F0), Color(0xFF9CA3B5), Color(0xFF6B7280),
        Color(0xFF4B5563), Color(0xFF374151), Color(0xFF1F2937),
        Color(0xFFD1D5DB), Color(0xFF9CA3AF), Color(0xFF111827),
      ];
    case 'neon':
      return const [
        Color(0xFF00FF87), Color(0xFF00D4FF), Color(0xFFFF00FF),
        Color(0xFFFFFF00), Color(0xFFFF4500), Color(0xFF7B68EE),
        Color(0xFF00FFFF), Color(0xFFFF1493), Color(0xFF39FF14),
      ];
    default:
      return OpticsColors.chartPalette;
  }
}

/// Human-readable time range label. Delegates to the canonical helper.
String _timeRangeLabel(String? raw) =>
    timeRangeLongLabel(raw ?? kDefaultTimeRange);

/// The "vs prior X" phrase that appears under a KPI's delta.
/// Returns null when no comparison applies (e.g. "Maximum date range").
String? _priorPeriodPhrase(String? raw) =>
    priorPeriodPhrase(raw ?? kDefaultTimeRange);

// ─── Multi-Series Data Model ──────────────────────────────────────

class _SeriesData {
  final String name;
  final List<double> data;
  const _SeriesData(this.name, this.data);
  double get total => data.fold(0.0, (a, b) => a + b);
  double get last => data.isEmpty ? 0 : data.last;
}

/// Public renderer. If the widget has a `data_binding.brz` block, this fetches
/// live data from the `widget-data-bryzos` Edge Function and merges the
/// chart-ready payload into the model's binding before rendering. Otherwise
/// it renders the model as-is (demo / static data).
///
/// When [chromeless] is true the renderer draws *only* the chart body — the
/// grid cell wrapper is expected to supply the title bar, border, and drag /
/// resize affordances. This is how the dashboard grid uses it. Standalone
/// callers (e.g. the report viewer) leave [chromeless] off so the renderer
/// produces a fully-styled OpticsCard.
class WidgetRenderer extends ConsumerStatefulWidget {
  final WidgetModel model;
  final bool selected;
  final bool chromeless;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onDeleteTap;

  const WidgetRenderer({
    super.key,
    required this.model,
    this.selected = false,
    this.chromeless = false,
    this.onSettingsTap,
    this.onDeleteTap,
  });

  @override
  ConsumerState<WidgetRenderer> createState() => _WidgetRendererState();
}

class _WidgetRendererState extends ConsumerState<WidgetRenderer> {
  Map<String, dynamic>? _liveData;
  bool _loading = false;
  String? _error;
  String? _lastFetchKey;

  Map<String, dynamic>? get _brz {
    final b = widget.model.binding['brz'];
    if (b is Map) return b.cast<String, dynamic>();
    return null;
  }

  /// Time-range resolution order:
  ///   1. user-set settings.timeRange (overrides everything)
  ///   2. authored binding.brz.time_range (the report author's default)
  ///   3. [kDefaultTimeRange] fallback
  /// Legacy codes are normalised to the canonical vocabulary.
  String get _timeRange {
    final s = widget.model.settings['timeRange'] as String?;
    if (s != null && s.isNotEmpty) return migrateTimeRange(s);
    final b = _brz?['time_range'] as String?;
    if (b != null && b.isNotEmpty) return migrateTimeRange(b);
    return kDefaultTimeRange;
  }

  int get _maxItems {
    final s = (widget.model.settings['maxItems'] as num?)?.toInt();
    if (s != null && s > 0) return s;
    final b = (_brz?['max_items'] as num?)?.toInt();
    if (b != null && b > 0) return b;
    return 10;
  }

  String get _fetchKey {
    final brz = _brz;
    if (brz == null) return '';
    return '${brz['data_source_id']}|${brz['metric']}|$_timeRange|$_maxItems';
  }

  @override
  void initState() {
    super.initState();
    _maybeFetch();
  }

  @override
  void didUpdateWidget(covariant WidgetRenderer old) {
    super.didUpdateWidget(old);
    _maybeFetch();
  }

  Future<void> _maybeFetch() async {
    final brz = _brz;
    if (brz == null) return;
    final key = _fetchKey;
    if (key == _lastFetchKey) return;
    _lastFetchKey = key;

    final dataSourceId = brz['data_source_id'] as String?;
    final metric = brz['metric'] as String?;
    if (dataSourceId == null || metric == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final res = await ref.read(repoProvider).widgetDataBryzos(
            dataSourceId: dataSourceId,
            metric: metric,
            timeRange: _timeRange,
            maxItems: _maxItems > 0 ? _maxItems : 10,
          );
      if (!mounted) return;
      if (res['error'] != null) {
        setState(() {
          _loading = false;
          _error = res['error'].toString();
        });
        return;
      }
      setState(() {
        _loading = false;
        _liveData = res;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  WidgetModel get _effectiveModel {
    final live = _liveData;
    if (live == null) return widget.model;
    // Merge live chart-ready fields into the existing binding map so
    // downstream renderer accessors (_data, _labels, _unit, _yLabel,
    // _multiSeries, _rows, _col1, _col2) just work.
    final merged = Map<String, dynamic>.from(widget.model.binding);
    for (final k in const [
      '_data', '_labels', '_multiSeries', '_unit', '_yLabel',
      '_col1', '_col2', '_rows', '_meta', '_timeRange',
    ]) {
      if (live.containsKey(k)) merged[k] = live[k];
    }
    return widget.model.copyWith(binding: merged);
  }

  @override
  Widget build(BuildContext context) {
    final hasBrz = _brz != null;
    // While first-fetching a Bryzos widget, show a lightweight loading shell.
    if (hasBrz && _liveData == null && _loading) {
      return _shell(
        const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (hasBrz && _error != null && _liveData == null) {
      return _shell(
        Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Data unavailable\n$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFFF6B6B),
              ),
            ),
          ),
        ),
      );
    }
    return _WidgetRendererCore(
      model: _effectiveModel,
      selected: widget.selected,
      chromeless: widget.chromeless,
      onSettingsTap: widget.onSettingsTap,
      onDeleteTap: widget.onDeleteTap,
    );
  }

  Widget _shell(Widget child) {
    if (widget.chromeless) {
      return Padding(
        padding: const EdgeInsets.all(OpticsSpacing.md),
        child: child,
      );
    }
    return OpticsCard(
      title: widget.model.title,
      showGrabHandle: true,
      selected: widget.selected,
      expandChild: true,
      padding: const EdgeInsets.all(OpticsSpacing.md),
      child: child,
    );
  }
}

/// Internal stateless renderer that draws the model's binding as-is.
/// All chart-rendering logic lives here. The public [WidgetRenderer] above
/// is responsible for fetching live data and merging it into the binding.
class _WidgetRendererCore extends StatelessWidget {
  final WidgetModel model;
  final bool selected;
  final bool chromeless;
  final VoidCallback? onSettingsTap;
  final VoidCallback? onDeleteTap;

  const _WidgetRendererCore({
    required this.model,
    this.selected = false,
    this.chromeless = false,
    this.onSettingsTap,
    this.onDeleteTap,
  });

  @override
  Widget build(BuildContext context) {
    if (chromeless) {
      // Grid cell already supplies the title bar + chrome. Just paint the
      // chart body with consistent padding.
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          OpticsSpacing.md, OpticsSpacing.sm,
          OpticsSpacing.md, OpticsSpacing.md,
        ),
        child: _autoScaled(_content()),
      );
    }
    Widget? trailing;
    if (onSettingsTap != null || onDeleteTap != null) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onSettingsTap != null) _SettingsGear(onTap: onSettingsTap!),
          if (onDeleteTap != null) ...[
            const SizedBox(width: 2),
            _DeleteButton(onTap: onDeleteTap!),
          ],
        ],
      );
    }
    return OpticsCard(
      title: model.title,
      showGrabHandle: true,
      selected: selected,
      expandChild: true,
      padding: const EdgeInsets.all(OpticsSpacing.md),
      trailing: trailing,
      child: _autoScaled(_content()),
    );
  }

  /// Scales text inside the widget body up gently as the widget grows.
  Widget _autoScaled(Widget child) {
    return LayoutBuilder(
      builder: (ctx, c) {
        const baseArea = 420.0 * 300.0;
        final area = c.maxWidth * c.maxHeight;
        final raw = area <= 0 ? 1.0 : math.sqrt(area / baseArea);
        final scale = raw.clamp(1.0, 1.25);
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: child,
        );
      },
    );
  }

  // ── Settings accessors ─────────────────────────────────────────

  String get _timeRange =>
      migrateTimeRange(model.settings['timeRange'] as String?);
  String get _sortBy => model.settings['sortBy'] as String? ?? 'Value ↓';
  String get _groupByKey => model.settings['groupBy'] as String? ?? 'Category';
  int get _maxItems => (model.settings['maxItems'] as num?)?.toInt() ?? 0;

  List<Color> get _palette =>
      _paletteFor(model.settings['colorScheme'] as String?);

  bool get _showGridLines => model.settings['gridLines'] != false;
  bool get _showLegend => model.settings['legend'] != false;
  bool get _showDataLabels => model.settings['dataLabels'] == true;

  /// Theme-aware colors for this widget (light vs dark).
  WidgetThemeColors get _wt => WidgetThemeColors.fromSettings(model.settings);

  // ── Raw data accessors ─────────────────────────────────────────

  List<double> get _rawSeries =>
      ((model.binding['_data'] as List?)
          ?.cast<num>()
          .map((n) => n.toDouble())
          .toList()) ??
      const [];

  List<_SeriesData>? get _rawMultiSeries {
    final raw = model.binding['_multiSeries'] as List?;
    if (raw == null) return null;
    return raw.map((s) {
      final m = s as Map<String, dynamic>;
      return _SeriesData(
        m['name'] as String? ?? '',
        (m['data'] as List).cast<num>().map((n) => n.toDouble()).toList(),
      );
    }).toList();
  }

  List<String> get _rawLabels =>
      ((model.binding['_labels'] as List?)?.cast<String>()) ??
      const [];

  String get _unit => (model.binding['_unit'] as String?) ?? '';
  String get _yLabel => (model.binding['_yLabel'] as String?) ?? '';

  // ── Data accessors ─────────────────────────────────────────────

  List<double> get _series => _rawSeries;
  List<String> get _labels => _rawLabels;

  bool get _hasMulti => _rawMultiSeries != null && _rawMultiSeries!.isNotEmpty;

  List<_SeriesData>? get _multiSeries => _rawMultiSeries;

  // ── Flatten multi-series ───────────────────────────────────────

  List<String> get _multiLabels =>
      _hasMulti ? _multiSeries!.map((s) => s.name).toList() : _labels;

  List<double> get _multiTotals =>
      _hasMulti ? _multiSeries!.map((s) => s.total).toList() : _series;

  // ── Sorting ────────────────────────────────────────────────────

  List<int> _sortedIndices(List<String> labels, List<double> values) {
    final indices = List.generate(labels.length, (i) => i);
    switch (_sortBy) {
      case 'Value ↓':
        indices.sort((a, b) => values[b].compareTo(values[a]));
        break;
      case 'Value ↑':
        indices.sort((a, b) => values[a].compareTo(values[b]));
        break;
      case 'Qty ↓':
        indices.sort((a, b) => values[b].compareTo(values[a]));
        break;
      case 'Qty ↑':
        indices.sort((a, b) => values[a].compareTo(values[b]));
        break;
      case 'A–Z':
        indices.sort((a, b) => labels[a].compareTo(labels[b]));
        break;
    }
    return indices;
  }

  List<int> _limitIndices(List<int> indices) {
    if (_maxItems > 0 && indices.length > _maxItems) {
      return indices.sublist(0, _maxItems);
    }
    return indices;
  }

  // ── Content router ─────────────────────────────────────────────

  Widget _content() {
    switch (model.kind) {
      case WidgetKind.kpi:
        return _kpi();
      case WidgetKind.line:
        return _hasMulti ? _multiLine() : _singleLine();
      case WidgetKind.barVertical:
      case WidgetKind.barGrouped:
        return _shouldRenderHorizontal()
            ? _barHorizontal()
            : (_hasMulti ? _groupedBar() : _singleBar());
      case WidgetKind.barStacked:
        return _shouldRenderHorizontal()
            ? _barHorizontal()
            : (_hasMulti ? _groupedBar(stacked: true) : _singleBar());
      case WidgetKind.barHorizontal:
        return _shouldRenderVerticalOverride()
            ? (_hasMulti ? _groupedBar() : _singleBar())
            : _barHorizontal();
      case WidgetKind.combo:
        return _combo();
      case WidgetKind.pie:
      case WidgetKind.donut:
        return _pie(donut: model.kind == WidgetKind.donut);
      case WidgetKind.table:
        return _table();
      case WidgetKind.map:
        return const Center(
          child: Text('Map widget — coming soon', style: OpticsTextStyles.bodySm),
        );
      case WidgetKind.markdown:
        return SingleChildScrollView(
          child: Text(
            (model.settings['markdown'] as String?) ?? 'Add some text…',
            style: OpticsTextStyles.body,
          ),
        );
    }
  }

  // ── Time range badge ───────────────────────────────────────────

  String _effectiveTimeRangeLabel() => _timeRangeLabel(_timeRange);

  Widget _timeRangeBadge() {
    final label = _effectiveTimeRangeLabel();
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: OpticsColors.accentCyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
              color: OpticsColors.accentCyan.withValues(alpha: 0.2)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: OpticsColors.accentCyan,
            height: 1.2,
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── KPI ─────────────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════

  Widget _kpi() {
    double v, prev;
    final meta = model.binding['_meta'];
    if (meta is Map && meta['total'] != null) {
      v = (meta['total'] as num).toDouble();
      final p = meta['prior'];
      prev = p is num ? p.toDouble() : v;
    } else if (_hasMulti) {
      final ms = _multiSeries!;
      v = ms.fold(0.0, (a, s) => a + s.last);
      prev = ms.fold(0.0, (a, s) => a + (s.data.length >= 2 ? s.data[s.data.length - 2] : s.last));
    } else {
      v = _series.isEmpty ? 0.0 : _series.last;
      prev = _series.length >= 2 ? _series[_series.length - 2] : v;
    }
    final delta = prev == 0 ? 0.0 : (v - prev) / prev * 100;
    final bool isFlat = delta.abs() < 0.05;
    final bool isUp = delta > 0;
    final Color deltaColor = isFlat
        ? _wt.mutedText
        : (isUp ? OpticsColors.success : OpticsColors.danger);
    final IconData deltaIcon = isFlat
        ? Icons.trending_flat
        : (isUp ? Icons.trending_up : Icons.trending_down);

    String display;
    if (_unit.contains(r'$')) {
      final unitMult = _unit == r'$M' ? 1e6 : _unit == r'$K' ? 1e3 : 1.0;
      display = _fmtSmartMoney(v * unitMult);
    } else if (_unit == '%') {
      display = '${v.toStringAsFixed(1)}%';
    } else if (_unit.isNotEmpty) {
      display = '${_fmtFull(v)}$_unit';
    } else {
      display = _fmtFull(v);
    }
    final priorPhrase = _priorPeriodPhrase(_timeRange);
    final periodLabel = priorPhrase == null ? '' : 'vs $priorPhrase';
    final showDelta = priorPhrase != null;

    List<double> sparkData;
    if (_hasMulti) {
      final ms = _multiSeries!;
      final numPeriods = ms.map((s) => s.data.length).reduce(math.max);
      sparkData = List.generate(numPeriods, (i) =>
          ms.fold(0.0, (a, s) => a + (i < s.data.length ? s.data[i] : 0)));
    } else {
      sparkData = _series;
    }

    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxHeight;
      final compact = available < 80;
      final showSparkline = available > 110 && sparkData.length > 2;

      return ClipRect(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact) _timeRangeBadge(),
            Text(
              display,
              style: compact
                  ? OpticsTextStyles.headingMd.copyWith(fontWeight: FontWeight.w700, color: _wt.kpiText)
                  : OpticsTextStyles.kpiNumber.copyWith(color: _wt.kpiText),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (showDelta) ...[
              SizedBox(height: compact ? 2 : 6),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: deltaColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(deltaIcon, size: 12, color: deltaColor),
                        const SizedBox(width: 3),
                        Text(
                          '${delta.abs().toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: deltaColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      periodLabel,
                      style: TextStyle(fontSize: 12, color: _wt.mutedText),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            if (showSparkline) ...[
              const SizedBox(height: 6),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 28, minHeight: 16),
                  child: _miniSparkline(sparkData),
                ),
              ),
            ],
          ],
        ),
      );
    });
  }

  Widget _miniSparkline(List<double> data) {
    final maxV = data.reduce(math.max);
    final minV = data.reduce(math.min);
    final range = maxV - minV;
    return CustomPaint(
      painter: _SparklinePainter(data: data, minV: minV, maxV: maxV, range: range, color: _palette.first),
      size: const Size(double.infinity, 28),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── LINE CHARTS ─────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════

  Widget _singleLine() {
    // Clamp values to 0 — revenue/order data cannot be negative.
    final data = _series.map((v) => v < 0 ? 0.0 : v).toList();
    final labels = _labels;
    final spots = [
      for (int i = 0; i < data.length; i++) FlSpot(i.toDouble(), data[i]),
    ];
    if (data.isEmpty) return _noData();
    final maxV = data.reduce(math.max);
    // Never let minY go below 0 — negative values on revenue/order charts make no sense
    final effectiveMin = math.max(0.0, data.reduce(math.min));
    final range = maxV - effectiveMin;
    final interval = _niceInterval(range == 0 ? math.max(maxV, 1) : range);
    final roundedMax = (maxV / interval).ceil() * interval;
    final color = _palette.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(
          legendWidget: _showLegend
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 12, height: 2,
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
                    ),
                    const SizedBox(width: 5),
                    Text(model.title,
                        style: TextStyle(fontSize: 11, color: _wt.mutedText),
                        overflow: TextOverflow.ellipsis),
                  ],
                )
              : null,
        ),
        Expanded(
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: roundedMax.toDouble(),
              clipData: const FlClipData.all(),
              gridData: FlGridData(
                show: _showGridLines,
                drawVerticalLine: false,
                horizontalInterval: interval.toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: _wt.gridLine.withValues(alpha: 0.5), strokeWidth: 0.5),
              ),
              titlesData: _titlesData(interval, labels),
              borderData: _borderData(),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => _wt.tooltipBg,
                  tooltipRoundedRadius: 6,
                  getTooltipItems: (spots) => spots.map((s) {
                    final idx = s.x.toInt();
                    final lbl = idx < labels.length ? labels[idx] : '';
                    return LineTooltipItem(
                      '$lbl\n${_fmtSmartValue(s.y, _unit)}',
                      TextStyle(fontSize: 10, color: _wt.bodyText, fontWeight: FontWeight.w500),
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true, curveSmoothness: 0.25, preventCurveOverShooting: true,
                  color: color, barWidth: 2.5,
                  dotData: FlDotData(show: _showDataLabels || data.length <= 12,
                    getDotPainter: (_, __, ___, ____) =>
                        FlDotCirclePainter(radius: 2.5, color: color, strokeWidth: 0)),
                  belowBarData: BarAreaData(show: true,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [color.withValues(alpha: 0.20), color.withValues(alpha: 0.02)],
                    )),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _multiLine() {
    final ms = _multiSeries!;
    final labels = _labels;
    double maxV = 0, minV = double.infinity;
    for (final s in ms) {
      for (final v in s.data) {
        if (v > maxV) maxV = v;
        if (v < minV) minV = v;
      }
    }
    if (minV == double.infinity) minV = 0;
    // Never go below 0
    final effectiveMin = math.max(0.0, minV);
    final range = maxV - effectiveMin;
    final interval = _niceInterval(range == 0 ? math.max(maxV, 1) : range);
    final roundedMax = (maxV / interval).ceil() * interval;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(
          legendWidget: _showLegend ? _multiSeriesLegend(ms) : null,
        ),
        Expanded(
          child: LineChart(
            LineChartData(
              minY: 0,
              maxY: roundedMax.toDouble(),
              clipData: const FlClipData.all(),
              gridData: FlGridData(
                show: _showGridLines, drawVerticalLine: false,
                horizontalInterval: interval.toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: _wt.gridLine.withValues(alpha: 0.5), strokeWidth: 0.5),
              ),
              titlesData: _titlesData(interval, labels),
              borderData: _borderData(),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => _wt.tooltipBg,
                  tooltipRoundedRadius: 6,
                  getTooltipItems: (spots) => spots.map((s) {
                    final sIdx = s.barIndex;
                    final name = sIdx < ms.length ? ms[sIdx].name : '';
                    return LineTooltipItem(
                      '$name: ${_fmtSmartValue(s.y, _unit)}',
                      TextStyle(fontSize: 10, color: _palette[sIdx % _palette.length], fontWeight: FontWeight.w500),
                    );
                  }).toList(),
                ),
              ),
              lineBarsData: [
                for (int si = 0; si < ms.length; si++)
                  LineChartBarData(
                    spots: [for (int i = 0; i < ms[si].data.length; i++) FlSpot(i.toDouble(), ms[si].data[i] < 0 ? 0.0 : ms[si].data[i])],
                    isCurved: true, curveSmoothness: 0.25, preventCurveOverShooting: true,
                    color: _palette[si % _palette.length], barWidth: 2,
                    dotData: FlDotData(show: _showDataLabels,
                      getDotPainter: (_, __, ___, ____) =>
                          FlDotCirclePainter(radius: 2, color: _palette[si % _palette.length], strokeWidth: 0)),
                    belowBarData: BarAreaData(show: false),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── BAR CHARTS ──────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════

  /// User-selected bar orientation: 'Auto' | 'Vertical' | 'Horizontal'.
  /// Defaults to 'Auto' for any widget that hasn't been touched since
  /// this feature shipped — backwards compatible with existing widgets.
  String get _barOrientation =>
      (model.settings['barOrientation'] as String?) ?? 'Auto';

  /// Heuristic — decides whether a *vertical-by-default* bar widget
  /// should flip to horizontal. Triggers on any of:
  ///  • >8 categories (too many vertical bars cramp labels)
  ///  • Longest label >12 chars (won't fit under vertical bars)
  ///  • Label contains a space or '@' (names, emails, multi-word values)
  bool _autoPreferHorizontal() {
    final labels = _hasMulti ? _multiLabels : _labels;
    if (labels.isEmpty) return false;
    if (labels.length > 8) return true;
    var maxLen = 0;
    var hasMultiWord = false;
    for (final l in labels) {
      if (l.length > maxLen) maxLen = l.length;
      if (l.contains(' ') || l.contains('@')) hasMultiWord = true;
    }
    if (maxLen > 12) return true;
    if (hasMultiWord) return true;
    return false;
  }

  /// True iff a normally-vertical bar widget should render horizontally,
  /// based on the user's setting (or the auto-heuristic).
  bool _shouldRenderHorizontal() {
    switch (_barOrientation) {
      case 'Horizontal':
        return true;
      case 'Vertical':
        return false;
      case 'Auto':
      default:
        return _autoPreferHorizontal();
    }
  }

  /// True iff a normally-horizontal bar widget should render vertically
  /// because the user explicitly chose Vertical. (Auto keeps horizontal
  /// because the kind was authored as horizontal on purpose.)
  bool _shouldRenderVerticalOverride() {
    return _barOrientation == 'Vertical';
  }

  Widget _singleBar() {
    var labels = _hasMulti ? _multiLabels : _labels;
    var data = _hasMulti ? _multiTotals : _series;

    var indices = _sortedIndices(labels, data);
    indices = _limitIndices(indices);
    labels = [for (final i in indices) labels[i]];
    data = [for (final i in indices) data[i]];

    if (data.isEmpty) return _noData();
    final maxV = data.reduce(math.max);
    final interval = _niceInterval(maxV);
    final roundedMax = (maxV / interval).ceil() * interval;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(),
        Expanded(
          child: BarChart(
            BarChartData(
              maxY: roundedMax.toDouble(),
              groupsSpace: 12,
              gridData: FlGridData(
                show: _showGridLines, drawVerticalLine: false,
                horizontalInterval: interval.toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: _wt.gridLine.withValues(alpha: 0.5), strokeWidth: 0.5),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true, reservedSize: 30,
                    getTitlesWidget: (value, meta) {
                      final idx = value.toInt();
                      if (idx < 0 || idx >= labels.length) return const SizedBox.shrink();
                      final lbl = labels[idx];
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          lbl.length > 10 ? '${lbl.substring(0, 9)}…' : lbl,
                          style: TextStyle(fontSize: 12, color: _wt.mutedText),
                          textAlign: TextAlign.center,
                        ),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true, reservedSize: 44,
                    interval: interval.toDouble(),
                    getTitlesWidget: (value, meta) {
                      return Text(_fmtSmartValue(value, _unit),
                          style: TextStyle(fontSize: 10, color: _wt.mutedText));
                    },
                  ),
                ),
              ),
              borderData: _borderData(),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => _wt.tooltipBg,
                  tooltipRoundedRadius: 6,
                  getTooltipItem: (group, groupIdx, rod, rodIdx) {
                    final lbl = groupIdx < labels.length ? labels[groupIdx] : '';
                    return BarTooltipItem(
                      '$lbl\n${_fmtSmartValue(rod.toY, _unit)}',
                      TextStyle(fontSize: 10, color: _wt.bodyText, fontWeight: FontWeight.w500),
                    );
                  },
                ),
              ),
              barGroups: [
                for (int i = 0; i < data.length; i++)
                  BarChartGroupData(x: i, barRods: [
                    BarChartRodData(
                      toY: data[i],
                      color: _palette[i % _palette.length],
                      width: _barWidth(data.length),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                  ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _groupedBar({bool stacked = false}) {
    final ms = _multiSeries!;
    final labels = _labels;
    double maxV = 0;
    final numGroups = labels.length;
    for (int g = 0; g < numGroups; g++) {
      if (stacked) {
        double sum = 0;
        for (final s in ms) {
          if (g < s.data.length) sum += s.data[g];
        }
        if (sum > maxV) maxV = sum;
      } else {
        for (final s in ms) {
          if (g < s.data.length && s.data[g] > maxV) maxV = s.data[g];
        }
      }
    }
    final interval = _niceInterval(maxV);
    final roundedMax = (maxV / interval).ceil() * interval;
    final seriesCount = ms.length;
    final groupBarWidth = math.max(3.0, math.min(10.0, 80.0 / (numGroups * seriesCount)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(
          legendWidget: _showLegend ? _multiSeriesLegend(ms) : null,
        ),
        Expanded(
          child: BarChart(
            BarChartData(
              maxY: roundedMax.toDouble(),
              gridData: FlGridData(
                show: _showGridLines, drawVerticalLine: false,
                horizontalInterval: interval.toDouble(),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: _wt.gridLine.withValues(alpha: 0.5), strokeWidth: 0.5),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true, reservedSize: 24,
                    getTitlesWidget: (value, meta) {
                      final idx = value.toInt();
                      if (idx < 0 || idx >= labels.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          labels[idx].length > 5 ? '${labels[idx].substring(0, 4)}…' : labels[idx],
                          style: TextStyle(fontSize: 9, color: _wt.mutedText),
                          textAlign: TextAlign.center,
                        ),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true, reservedSize: 40,
                    interval: interval.toDouble(),
                    getTitlesWidget: (value, meta) =>
                        Text(_fmtSmartValue(value, _unit), style: TextStyle(fontSize: 9, color: _wt.mutedText)),
                  ),
                ),
              ),
              borderData: _borderData(),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => _wt.tooltipBg,
                  tooltipRoundedRadius: 6,
                  getTooltipItem: (group, groupIdx, rod, rodIdx) {
                    final monthLabel = groupIdx < labels.length ? labels[groupIdx] : '';
                    final seriesName = rodIdx < ms.length ? ms[rodIdx].name : '';
                    return BarTooltipItem(
                      '$monthLabel — $seriesName\n${_fmtSmartValue(rod.toY, _unit)}',
                      TextStyle(fontSize: 10, color: _wt.bodyText, fontWeight: FontWeight.w500),
                    );
                  },
                ),
              ),
              barGroups: [
                for (int g = 0; g < numGroups; g++)
                  BarChartGroupData(
                    x: g,
                    barRods: [
                      for (int s = 0; s < seriesCount; s++)
                        BarChartRodData(
                          toY: (g < ms[s].data.length) ? ms[s].data[g] : 0,
                          color: _palette[s % _palette.length],
                          width: groupBarWidth,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── HORIZONTAL BAR ──────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════

  Widget _barHorizontal() {
    var labels = _hasMulti ? _multiLabels : _labels;
    var data = _hasMulti ? _multiTotals : _series;

    var indices = _sortedIndices(labels, data);
    indices = _limitIndices(indices);
    labels = [for (final i in indices) labels[i]];
    data = [for (final i in indices) data[i]];

    if (data.isEmpty) return _noData();
    final maxV = data.reduce(math.max);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            final barH = math.min(24.0,
                (constraints.maxHeight - 20) / math.max(data.length, 1) - 4);

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < data.length && i < labels.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text(labels[i],
                                style: TextStyle(fontSize: 9, color: _wt.secondaryText),
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: LayoutBuilder(builder: (ctx, c) {
                              final fraction = maxV > 0 ? data[i] / maxV : 0.0;
                              return Stack(
                                children: [
                                  Container(
                                    height: barH,
                                    decoration: BoxDecoration(
                                      color: _wt.border.withValues(alpha: 0.3),
                                      borderRadius: BorderRadius.circular(3)),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 400),
                                    curve: Curves.easeOut,
                                    height: barH,
                                    width: c.maxWidth * fraction,
                                    decoration: BoxDecoration(
                                      color: _palette[i % _palette.length],
                                      borderRadius: BorderRadius.circular(3)),
                                  ),
                                  if (_showDataLabels)
                                    Positioned(
                                      left: c.maxWidth * fraction + 4,
                                      top: 0, bottom: 0,
                                      child: Center(
                                        child: Text(
                                          _fmtNum(data[i]),
                                          style: TextStyle(fontSize: 9, color: _wt.mutedText),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 52,
                            child: Text(
                              _fmtSmartValue(data[i], _unit),
                              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: _wt.bodyText),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── COMBO CHART ─────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════

  Widget _combo() {
    List<double> barData, lineData;
    String barLabel, lineLabel;
    final labels = _labels;

    if (_hasMulti && _multiSeries!.length >= 2) {
      barData = _multiSeries![0].data;
      lineData = _multiSeries![1].data;
      barLabel = _multiSeries![0].name;
      lineLabel = _multiSeries![1].name;
    } else {
      barData = _series;
      lineData = [];
      for (int i = 0; i < barData.length; i++) {
        if (i == 0) {
          lineData.add(barData[i]);
        } else {
          lineData.add((barData[i] + barData[i - 1]) / 2);
        }
      }
      barLabel = (model.binding['_comboLabel1'] as String?) ?? 'Value';
      lineLabel = (model.binding['_comboLabel2'] as String?) ?? 'Avg';
    }

    final allVals = [...barData, ...lineData];
    if (allVals.isEmpty) return _noData();
    final maxV = allVals.reduce(math.max);
    final interval = _niceInterval(maxV);
    final roundedMax = (maxV / interval).ceil() * interval;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(
          legendWidget: _showLegend
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _legendDot(_palette[1], barLabel),
                    const SizedBox(width: 10),
                    Container(
                      width: 10, height: 2,
                      decoration: BoxDecoration(color: _palette[0], borderRadius: BorderRadius.circular(1)),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(lineLabel,
                          style: TextStyle(fontSize: 9, color: _wt.mutedText),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                )
              : null,
        ),
        Expanded(
          child: Stack(
            children: [
              BarChart(
                BarChartData(
                  maxY: roundedMax.toDouble(),
                  gridData: FlGridData(
                    show: _showGridLines, drawVerticalLine: false,
                    horizontalInterval: interval.toDouble(),
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: _wt.gridLine.withValues(alpha: 0.5), strokeWidth: 0.5),
                  ),
                  titlesData: _titlesData(interval, labels),
                  borderData: _borderData(),
                  barTouchData: BarTouchData(enabled: false),
                  barGroups: [
                    for (int i = 0; i < barData.length; i++)
                      BarChartGroupData(x: i, barRods: [
                        BarChartRodData(
                          toY: barData[i],
                          color: _palette[1].withValues(alpha: 0.5),
                          width: _barWidth(barData.length),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        ),
                      ]),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 40, bottom: 24),
                child: LineChart(
                  LineChartData(
                    minY: 0, maxY: roundedMax.toDouble(),
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: [for (int i = 0; i < lineData.length; i++) FlSpot(i.toDouble(), lineData[i])],
                        color: _palette[0], barWidth: 2.5,
                        isCurved: true, curveSmoothness: 0.25, preventCurveOverShooting: true,
                        dotData: FlDotData(show: _showDataLabels,
                          getDotPainter: (_, __, ___, ____) =>
                              FlDotCirclePainter(radius: 2, color: _palette[0], strokeWidth: 0)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── PIE / DONUT ─────────────────────────────────────────────────
  // ══════════════════════════════════════════════════════════════════

  Widget _pie({required bool donut}) {
    var labels = _hasMulti ? _multiLabels : _labels;
    var data = _hasMulti ? _multiTotals : _series;

    var indices = _sortedIndices(labels, data);
    indices = _limitIndices(indices);
    labels = [for (final i in indices) labels[i]];
    data = [for (final i in indices) data[i]];

    if (data.isEmpty) return _noData();
    final total = data.fold<double>(0, (a, b) => a + b);

    final isMonetary =
        _unit == '\$M' || _unit == '\$K' || _unit == '\$';

    final unitMult = _unit == r'$M' ? 1e6 : _unit == r'$K' ? 1e3 : 1.0;

    String fmtMoney(double v) {
      return _fmtSmartMoney(v * unitMult);
    }

    String fmtValue(double v) {
      if (isMonetary) return fmtMoney(v);
      if (_unit == '%') return '${v.toStringAsFixed(1)}%';
      if (_unit.isNotEmpty) return '${_fmtFull(v)}$_unit';
      return _fmtFull(v);
    }

    String fmtPct(double v) =>
        '${(v / total * 100).toStringAsFixed(total >= 100 ? 0 : 1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: donut ? 30 : 0,
                    pieTouchData: PieTouchData(enabled: true),
                    sections: [
                      for (int i = 0; i < data.length; i++)
                        PieChartSectionData(
                          color: _palette[i % _palette.length],
                          value: data[i],
                          title: _showDataLabels
                              ? (isMonetary ? fmtMoney(data[i]) : fmtPct(data[i]))
                              : '',
                          titleStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                          radius: donut ? 42 : 62,
                          showTitle: _showDataLabels,
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (int i = 0; i < data.length && i < labels.length; i++)
                        Tooltip(
                          message: isMonetary
                              ? '${labels[i]}\n${fmtMoney(data[i])}  ·  ${fmtPct(data[i])}'
                              : '${labels[i]}\n${fmtValue(data[i])}  ·  ${fmtPct(data[i])}',
                          waitDuration: const Duration(milliseconds: 150),
                          textStyle: TextStyle(
                              fontSize: 11,
                              color: _wt.bodyText,
                              height: 1.4),
                          decoration: BoxDecoration(
                            color: _wt.cardBg,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: OpticsColors.accentCyan
                                    .withValues(alpha: 0.3)),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Container(
                                  width: 8, height: 8,
                                  decoration: BoxDecoration(
                                    color: _palette[i % _palette.length],
                                    borderRadius: BorderRadius.circular(2)),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(labels[i],
                                      style: TextStyle(fontSize: 12, color: _wt.secondaryText),
                                      overflow: TextOverflow.ellipsis),
                                ),
                                Text(
                                  isMonetary ? fmtMoney(data[i]) : fmtPct(data[i]),
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _wt.bodyText)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // ── TABLE (sticky header + smart money formatting) ───────────────
  // ══════════════════════════════════════════════════════════════════

  Widget _table() {
    // Detail-list metrics (e.g. orders_recent_list, users_recent_list,
    // quotes_detail_list, expired_lost_quotes, cancelled_orders_list,
    // bpns_full_list, bom_upload_detail) return arbitrary-shape rows in
    // `_rows` rather than the labels/values pair used by ranked tables.
    // When present, render those as a generic multi-column detail table.
    final rawRows = model.binding['_rows'];
    if (rawRows is List && rawRows.isNotEmpty) {
      return _rowsDetailTable(rawRows);
    }
    if (_hasMulti) return _multiSeriesTable();
    return _singleSeriesTable();
  }

  /// Renders an arbitrary-shape detail list returned by the server as
  /// `_rows: [{col1: ..., col2: ...}, ...]`. Column order, headers, and
  /// alignment are inferred from the first row's key set; numeric values
  /// are right-aligned and money-formatted when the unit is monetary, and
  /// date-like ISO strings are formatted human-readably.
  Widget _rowsDetailTable(List rawRows) {
    final rows = rawRows
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    if (rows.isEmpty) return _noData();
    // Column order = first row's key insertion order.
    final cols = rows.first.keys.toList();
    final headers = [for (final c in cols) _humanizeKey(c)];
    final aligns = <TextAlign>[
      for (final c in cols) TextAlign.left,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(),
        // Frozen header
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: _wt.headerBg,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(6)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 32,
                child: Text('#',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _wt.mutedText)),
              ),
              for (int c = 0; c < cols.length; c++)
                Expanded(
                  flex: _flexForCol(cols[c]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      headers[c],
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _wt.mutedText),
                      textAlign: aligns[c],
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
        // Scrollable body
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (int i = 0; i < rows.length; i++)
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
                    color: i.isOdd
                        ? _wt.headerBg.withValues(alpha: 0.3)
                        : Colors.transparent,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text('${i + 1}',
                              style: TextStyle(
                                  fontSize: 11, color: _wt.mutedText)),
                        ),
                        for (int c = 0; c < cols.length; c++)
                          Expanded(
                            flex: _flexForCol(cols[c]),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Text(
                                _formatCell(cols[c], rows[i][cols[c]]),
                                style: TextStyle(
                                    fontSize: 11, color: _wt.bodyText),
                                textAlign: aligns[c],
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// "buyer_company_name" → "Buyer Company Name", "po" → "PO".
  String _humanizeKey(String key) {
    if (key.length <= 3 && key == key.toLowerCase()) return key.toUpperCase();
    return key
        .split('_')
        .map((w) =>
            w.isEmpty ? w : (w[0].toUpperCase() + w.substring(1)))
        .join(' ');
  }

  /// A column is treated as numeric if >50% of its non-null values are nums.
  bool _isNumericColumn(String key, List<Map<String, dynamic>> rows) {
    int total = 0, nums = 0;
    for (final r in rows) {
      final v = r[key];
      if (v == null) continue;
      total++;
      if (v is num) nums++;
    }
    return total > 0 && nums * 2 > total;
  }

  int _flexForCol(String key) {
    const m = {
      // Orders in Dispute (Edge Function returns aliased keys)
      'Order#':          3,
      'Dispute Type':    5,
      'Buyer':           4,
      'Seller':          4,
      'Status':          9,
      // Monthly Financial Summary
      'Month':           5,
      'Transactions':    4,
      'Revenue':         4,
      'COGS':            4,
      'GP (\$)':         4,
      'GP (%)':          3,
      // Orders Previewed by Sellers
      'Preview Screen':  6,
      'Claim Screen':    6,
      // Shared across Orders in Dispute + All Buyers + All Sellers
      'Buyer Company':   6,
      'Seller Company':  6,
      // All Buyers / All Sellers
      'Buyer Email':     8,
      'Seller Email':    8,
      'Purchases':       3,
      'AOV':             4,
      'Total Purchases': 5,
      'Sales':           3,
      'Total Sales':     5,
    };
    return m[key] ?? 5;
  }

  String _formatCell(String key, dynamic v) {
    if (v == null) return '';
    // Dispute Type event codes → friendly labels
    if (key == 'event' || key == 'Dispute Type') {
      const labels = {
        'edit_line':    'Qty Change',
        'cancel_order': 'Order Cancel',
        'cancel_line':  'Line Cancel',
        'add_line':     'Line Added',
        'deliver_by':   'Delivery Date Change',
        'deliver_to':   'Destination Change',
        'destination':  'Destination Change',
      };
      return labels[v?.toString()] ?? v?.toString() ?? '';
    }
    if (v is bool) return v ? 'Yes' : 'No';
    // GP (%) → show as percentage
    if (key == 'GP (%)') {
      final n = v is num ? v.toDouble() : double.tryParse(v.toString());
      if (n != null) return '${n.toStringAsFixed(2)}%';
    }
    final s = v.toString();
    // ISO timestamp → short date
    if (_looksLikeIsoDate(s)) {
      final d = DateTime.tryParse(s);
      if (d != null) return DateFormat('M-d-yy').format(d.toLocal());
    }
    // Numeric (num or parseable string) — apply money or plain formatting
    final isMoney = _looksLikeMoneyKey(key);
    if (v is num) {
      if (isMoney) return _fmtExactMoney(v.toDouble());
      return _fmtFull(v.toDouble());
    }
    final parsed = double.tryParse(s);
    if (parsed != null && isMoney) return _fmtExactMoney(parsed);
    return s;
  }

  bool _looksLikeMoneyKey(String key) {
    final k = key.toLowerCase();
    if (k == 'gp (%)') return false; // percentage, not money
    return k == 'aov' ||
        k == 'cogs' ||
        k == 'gp (\$)' ||
        k.contains('price') ||
        k.contains('revenue') ||
        k.contains('total') ||
        k.contains('value') ||
        k.contains('amount') ||
        k.contains('cost') ||
        k.contains('spread');
  }

  bool _looksLikeIsoDate(String s) {
    if (s.length < 10) return false;
    return RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s);
  }

  Widget _singleSeriesTable() {
    if (_series.length != _labels.length) {
      return _noData();
    }

    final col1Header = (model.binding['_col1'] as String?) ?? 'Name';
    final col2Header = (model.binding['_col2'] as String?) ?? 'Value';
    final total = _series.fold<double>(0, (a, b) => a + b);

    var indices = _sortedIndices(_labels, _series);
    indices = _limitIndices(indices);

    // Sticky header: frozen header row + scrollable body rows
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(),
        // Frozen header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _wt.headerBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
          child: Row(
            children: [
              SizedBox(width: 32,
                  child: Text('#', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText))),
              Expanded(flex: 3,
                  child: Text(col1Header, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText))),
              Expanded(flex: 2,
                  child: Text(col2Header, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText), textAlign: TextAlign.right)),
              SizedBox(width: 50,
                  child: Text('Share', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText), textAlign: TextAlign.right)),
            ],
          ),
        ),
        // Scrollable body
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (int rank = 0; rank < indices.length; rank++)
                  _singleTableRow(rank, indices[rank], total),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _singleTableRow(int rank, int dataIdx, double total) {
    final pct = total > 0 ? _series[dataIdx] / total * 100 : 0.0;
    final isOdd = rank % 2 == 1;
    // Smart dollar formatting: never show $0.0M for sub-million values
    final valueStr = _fmtSmartValue(_series[dataIdx], _unit);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      color: isOdd ? _wt.headerBg.withValues(alpha: 0.3) : Colors.transparent,
      child: Row(
        children: [
          SizedBox(width: 32,
              child: Text('${rank + 1}', style: TextStyle(fontSize: 11, color: _wt.mutedText))),
          Expanded(flex: 3,
              child: Row(
                children: [
                  Container(
                    width: 6, height: 6,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _palette[dataIdx % _palette.length],
                      borderRadius: BorderRadius.circular(1)),
                  ),
                  Expanded(
                    child: Text(_labels[dataIdx],
                        style: TextStyle(fontSize: 11, color: _wt.bodyText), overflow: TextOverflow.ellipsis)),
                ],
              )),
          Expanded(flex: 2,
              child: Text(
                valueStr,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _palette[dataIdx % _palette.length]),
                textAlign: TextAlign.right)),
          SizedBox(width: 50,
              child: Text('${pct.toStringAsFixed(1)}%',
                  style: TextStyle(fontSize: 11, color: _wt.secondaryText), textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _multiSeriesTable() {
    final ms = _multiSeries!;
    final grandTotal = ms.fold(0.0, (double a, _SeriesData s) => a + s.total);

    final names = ms.map((s) => s.name).toList();
    final totals = ms.map((s) => s.total).toList();
    var indices = _sortedIndices(names, totals);
    indices = _limitIndices(indices);

    final rawPrices = model.binding['_unitPrices'];
    final Map<String, double> unitPrices = rawPrices is Map
        ? rawPrices.map((k, v) => MapEntry('$k', (v as num).toDouble()))
        : const {};
    final hasPricing = unitPrices.isNotEmpty;

    final isMoneyUnit = _unit.contains('\$');
    final primaryHeader = isMoneyUnit ? 'Total \$' : 'Total #';
    final grandRevenue = hasPricing
        ? ms.fold<double>(
            0, (a, s) => a + s.total * (unitPrices[s.name] ?? 0))
        : 0.0;

    // Sticky header: frozen header row + scrollable body
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chartHeader(),
        // Frozen header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _wt.headerBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6))),
          child: Row(
            children: [
              SizedBox(width: 32,
                  child: Text('#', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText))),
              Expanded(flex: 3,
                  child: Text('Name', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText))),
              Expanded(flex: 2,
                  child: Text(primaryHeader, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText), textAlign: TextAlign.right)),
              if (hasPricing)
                Expanded(flex: 2,
                    child: Text('Total Revenue', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText), textAlign: TextAlign.right)),
              SizedBox(width: 50,
                  child: Text('Share', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.mutedText), textAlign: TextAlign.right)),
            ],
          ),
        ),
        // Scrollable body
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (int rank = 0; rank < indices.length; rank++)
                  _multiTableRow(rank, indices[rank], ms, grandTotal,
                      unitPrices: unitPrices,
                      grandRevenue: grandRevenue,
                      hasPricing: hasPricing,
                      isMoneyUnit: isMoneyUnit),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _multiTableRow(
    int rank,
    int idx,
    List<_SeriesData> ms,
    double grandTotal, {
    required Map<String, double> unitPrices,
    required double grandRevenue,
    required bool hasPricing,
    required bool isMoneyUnit,
  }) {
    final s = ms[idx];
    final revenue =
        hasPricing ? s.total * (unitPrices[s.name] ?? 0) : 0.0;

    final shareBasis = hasPricing ? grandRevenue : grandTotal;
    final shareValue = hasPricing ? revenue : s.total;
    final sharePct = shareBasis > 0
        ? '${(shareValue / shareBasis * 100).toStringAsFixed(1)}%'
        : '0%';

    // Smart primary formatting — scale by unit multiplier so $K values
    // display as e.g. "$1.3M" not "$1.3K".
    final unitMult = _unit == r'$M' ? 1e6 : _unit == r'$K' ? 1e3 : 1.0;
    final primaryStr = isMoneyUnit
        ? _fmtSmartMoney(s.total * unitMult)
        : _fmtFull(s.total);
    final revenueStr = _fmtSmartMoney(revenue);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      color: rank % 2 == 1 ? _wt.headerBg.withValues(alpha: 0.3) : Colors.transparent,
      child: Row(
        children: [
          SizedBox(width: 32,
              child: Text('${rank + 1}', style: TextStyle(fontSize: 11, color: _wt.mutedText))),
          Expanded(flex: 3,
              child: Row(
                children: [
                  Container(
                    width: 6, height: 6,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _palette[idx % _palette.length],
                      borderRadius: BorderRadius.circular(1)),
                  ),
                  Expanded(
                    child: Text(s.name,
                        style: TextStyle(fontSize: 11, color: _wt.bodyText),
                        overflow: TextOverflow.ellipsis)),
                ],
              )),
          Expanded(flex: 2,
              child: Text(
                primaryStr,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _palette[idx % _palette.length]),
                textAlign: TextAlign.right)),
          if (hasPricing)
            Expanded(flex: 2,
                child: Text(
                  revenueStr,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _wt.bodyText),
                  textAlign: TextAlign.right)),
          SizedBox(width: 50,
              child: Text(
                sharePct,
                style: TextStyle(fontSize: 11, color: _wt.secondaryText),
                textAlign: TextAlign.right)),
        ],
      ),
    );
  }


  /// Standard chart header: time range badge + legend (inline) + Y-label at far right.
  /// Legend appears between the badge and the Y-label so it never overlaps the chart.
  Widget _chartHeader({Widget? legendWidget}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _timeRangeBadge(),
          const SizedBox(width: 8),
          if (legendWidget != null) ...[
            Expanded(child: legendWidget),
          ] else
            const Spacer(),
          if (_yLabel.isNotEmpty)
            Text(
              'Y: $_yLabel',
              style: TextStyle(fontSize: 9, color: _wt.mutedText),
            ),
        ],
      ),
    );
  }

  Widget _noData() {
    return Center(
      child: Text('No data for this range',
          style: TextStyle(fontSize: 11, color: _wt.mutedText)),
    );
  }

  Widget _multiSeriesLegend(List<_SeriesData> ms) {
    return SizedBox(
      height: 18,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (int i = 0; i < ms.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            _legendDot(_palette[i % _palette.length], ms[i].name),
          ],
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12, height: 2,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1)),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(fontSize: 11, color: _wt.mutedText),
            overflow: TextOverflow.ellipsis),
      ],
    );
  }

  FlTitlesData _titlesData(double interval, List<String> labels) {
    return FlTitlesData(
      topTitles: const AxisTitles(
        sideTitles: SideTitles(showTitles: false, reservedSize: 4),
      ),
      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true, reservedSize: 22,
          interval: _labelInterval(labels.length),
          getTitlesWidget: (value, meta) {
            final idx = value.toInt();
            if (idx < 0 || idx >= labels.length) return const SizedBox.shrink();
            return SideTitleWidget(
              axisSide: meta.axisSide,
              space: 4,
              child: Text(
                labels[idx],
                style: TextStyle(fontSize: 9, color: _wt.mutedText),
              ),
            );
          },
        ),
      ),
      leftTitles: AxisTitles(
        // Y-label now shown in _chartHeader row — no axisNameWidget here
        sideTitles: SideTitles(
          showTitles: true, reservedSize: 40,
          interval: interval.toDouble(),
          getTitlesWidget: (value, meta) => SideTitleWidget(
            axisSide: meta.axisSide,
            space: 4,
            child: Text(
              _fmtNum(value),
              style: TextStyle(fontSize: 9, color: _wt.mutedText),
            ),
          ),
        ),
      ),
    );
  }

  FlBorderData _borderData() {
    return FlBorderData(
      show: true,
      border: Border(
        bottom: BorderSide(color: _wt.border, width: 0.5),
        left: BorderSide(color: _wt.border, width: 0.5),
      ),
    );
  }

  double _barWidth(int count) {
    // Responsive bar width — 12px gap between bars (set via groupsSpace).
    // Bars fill as much width as possible; narrows as data points increase.
    if (count <= 2) return 80;
    if (count <= 4) return 60;
    if (count <= 6) return 44;
    if (count <= 8) return 32;
    if (count <= 12) return 22;
    if (count <= 20) return 16;
    return 10;
  }

  double _labelInterval(int count) {
    if (count <= 6) return 1;
    if (count <= 12) return 2;
    return 3;
  }

  double _niceInterval(double range) {
    if (range <= 0) return 1;
    final order = math.pow(10, (math.log(range) / math.ln10).floor());
    final fraction = range / order;
    double nice;
    if (fraction <= 1.5) { nice = 1; }
    else if (fraction <= 3) { nice = 2; }
    else if (fraction <= 7) { nice = 5; }
    else { nice = 10; }
    return nice * order;
  }
}
// ── Settings Gear Button ──────────────────────────────────────────

class _SettingsGear extends StatefulWidget {
  final VoidCallback onTap;
  const _SettingsGear({required this.onTap});
  @override
  State<_SettingsGear> createState() => _SettingsGearState();
}

class _SettingsGearState extends State<_SettingsGear> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: 'Widget settings',
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _hovered ? OpticsColors.accentCyan.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(4)),
            child: Icon(Icons.tune_rounded, size: 14,
                color: _hovered ? OpticsColors.accentCyan : OpticsColors.textMuted),
          ),
        ),
      ),
    );
  }
}

// ── Delete (×) Button ─────────────────────────────────────────────

class _DeleteButton extends StatefulWidget {
  final VoidCallback onTap;
  const _DeleteButton({required this.onTap});
  @override
  State<_DeleteButton> createState() => _DeleteButtonState();
}

class _DeleteButtonState extends State<_DeleteButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: 'Remove widget',
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _hovered
                  ? OpticsColors.danger.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 14,
              color: _hovered ? OpticsColors.danger : OpticsColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Mini Sparkline Painter ────────────────────────────────────────

class _SparklinePainter extends CustomPainter {
  final List<double> data;
  final double minV, maxV, range;
  final Color color;

  _SparklinePainter({required this.data, required this.minV, required this.maxV, required this.range, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final paint = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;

    final path = Path();
    for (int i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = range > 0 ? size.height - (data[i] - minV) / range * size.height : size.height / 2;
      if (i == 0) { path.moveTo(x, y); } else { path.lineTo(x, y); }
    }
    canvas.drawPath(path, paint);

    final fillPath = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) => old.data != data || old.color != color;
}
