import 'package:flutter/material.dart';

import '../../design/theme.dart';
import 'time_range_options.dart';

/// Grouped dropdown matching the design reference (Auto / Today / Yesterday /
/// week group / month group / year group / Maximum date range / Custom).
///
/// Shared between the per-widget settings panel and the dashboard-level
/// Default Time Range control so the two stay consistent.
class TimeRangePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const TimeRangePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = migrateTimeRange(value);
    return PopupMenuButton<String>(
      tooltip: 'Default time range',
      initialValue: current,
      color: OpticsColors.surfaceElevated,
      onSelected: (v) => onChanged(v),
      itemBuilder: (ctx) {
        final items = <PopupMenuEntry<String>>[];
        for (var gi = 0; gi < kTimeRangeGroups.length; gi++) {
          if (gi > 0) items.add(const PopupMenuDivider());
          for (final opt in kTimeRangeGroups[gi].options) {
            items.add(PopupMenuItem<String>(
              value: opt.code,
              enabled: opt.enabled,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      opt.label,
                      style: TextStyle(
                        fontSize: 13,
                        color: opt.enabled
                            ? (opt.code == current
                                ? OpticsColors.accentCyan
                                : OpticsColors.textPrimary)
                            : OpticsColors.textMuted,
                        fontWeight: opt.code == current
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (opt.code == kTimeRangeAuto)
                    const Text(
                      'Last 30 days',
                      style: TextStyle(
                          fontSize: 11, color: OpticsColors.textMuted),
                    ),
                ],
              ),
            ));
          }
        }
        return items;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: OpticsColors.surfaceElevated,
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
          border: Border.all(color: OpticsColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              timeRangeLongLabel(current),
              style: const TextStyle(
                fontSize: 13,
                color: OpticsColors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.keyboard_arrow_down,
                size: 16, color: OpticsColors.textMuted),
          ],
        ),
      ),
    );
  }
}
