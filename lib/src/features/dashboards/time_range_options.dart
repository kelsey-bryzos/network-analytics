// Canonical list of Default Time Range options exposed in the per-widget
// settings panel (and any other "default time range" UI). Authoritative source
// for the strings stored in widget settings / report layouts.
//
// The codes ARE the labels (so JSON dumps read naturally). Back-compat for
// legacy codes (`1 Mo`, `3 Mo`, `6 Mo`, `1 Yr`, `YTD`, `All`) is provided by
// [migrateTimeRange] — callers should run incoming values through it before
// rendering or sending to the backend.

class TimeRangeOption {
  final String code;       // canonical value persisted to settings
  final String label;      // shown in the dropdown
  final bool enabled;      // false → disabled menu entry (Custom… for now)
  const TimeRangeOption(this.code, this.label, {this.enabled = true});
}

class TimeRangeGroup {
  final List<TimeRangeOption> options;
  const TimeRangeGroup(this.options);
}

const kTimeRangeAuto             = 'Auto';
const kTimeRangeToday            = 'Today';
const kTimeRangeYesterday        = 'Yesterday';
const kTimeRangeLast7Days        = 'Last 7 days';
const kTimeRangeThisWeek         = 'This week';
const kTimeRangeLastWeek         = 'Last week';
const kTimeRangeLast30Days       = 'Last 30 days';
const kTimeRangeThisMonth        = 'This month';
const kTimeRangeLastMonth        = 'Last month';
const kTimeRangeMonthToDate      = 'Month to date';
const kTimeRangeLast6Months      = 'Last 6 months';
const kTimeRangeLast12Months     = 'Last 12 months';
const kTimeRangeThisYear         = 'This year';
const kTimeRangeLastYear         = 'Last year';
const kTimeRangeYearToDate       = 'Year to date';
const kTimeRangeMaximum          = 'Maximum date range';
const kTimeRangeCustom           = 'Custom…';

const kDefaultTimeRange = kTimeRangeLast30Days;

/// Grouped, in the same order as the design reference.
const List<TimeRangeGroup> kTimeRangeGroups = [
  TimeRangeGroup([
    TimeRangeOption(kTimeRangeAuto, 'Auto'),
  ]),
  TimeRangeGroup([
    TimeRangeOption(kTimeRangeToday, 'Today'),
    TimeRangeOption(kTimeRangeYesterday, 'Yesterday'),
  ]),
  TimeRangeGroup([
    TimeRangeOption(kTimeRangeLast7Days, 'Last 7 days'),
    TimeRangeOption(kTimeRangeThisWeek, 'This week'),
    TimeRangeOption(kTimeRangeLastWeek, 'Last week'),
  ]),
  TimeRangeGroup([
    TimeRangeOption(kTimeRangeLast30Days, 'Last 30 days'),
    TimeRangeOption(kTimeRangeThisMonth, 'This month'),
    TimeRangeOption(kTimeRangeLastMonth, 'Last month'),
    TimeRangeOption(kTimeRangeMonthToDate, 'Month to date'),
  ]),
  TimeRangeGroup([
    TimeRangeOption(kTimeRangeLast6Months, 'Last 6 months'),
    TimeRangeOption(kTimeRangeLast12Months, 'Last 12 months'),
    TimeRangeOption(kTimeRangeThisYear, 'This year'),
    TimeRangeOption(kTimeRangeLastYear, 'Last year'),
    TimeRangeOption(kTimeRangeYearToDate, 'Year to date'),
  ]),
  TimeRangeGroup([
    TimeRangeOption(kTimeRangeMaximum, 'Maximum date range'),
    TimeRangeOption(kTimeRangeCustom, 'Custom…', enabled: false),
  ]),
];

/// Flat list of all canonical codes.
List<String> get kAllTimeRangeCodes => [
  for (final g in kTimeRangeGroups)
    for (final o in g.options) o.code,
];

/// Maps legacy time-range codes (and other variants) to the canonical code.
/// Returns input unchanged if already canonical or unrecognised.
String migrateTimeRange(String? raw) {
  if (raw == null || raw.isEmpty) return kDefaultTimeRange;
  switch (raw) {
    case '1 Mo':  return kTimeRangeThisMonth;
    case '3 Mo':  return kTimeRangeLast30Days;
    case '6 Mo':  return kTimeRangeLast6Months;
    case '1 Yr':  return kTimeRangeLast12Months;
    case 'YTD':   return kTimeRangeYearToDate;
    case 'All':   return kTimeRangeMaximum;
    default:      return raw;
  }
}

/// Human-readable label shown next to KPI values (e.g. "Last 30 days").
String timeRangeLongLabel(String code) {
  final c = migrateTimeRange(code);
  switch (c) {
    case kTimeRangeAuto:           return 'Last 30 days';
    case kTimeRangeToday:          return 'Today';
    case kTimeRangeYesterday:      return 'Yesterday';
    case kTimeRangeLast7Days:      return 'Last 7 days';
    case kTimeRangeThisWeek:       return 'This week';
    case kTimeRangeLastWeek:       return 'Last week';
    case kTimeRangeLast30Days:     return 'Last 30 days';
    case kTimeRangeThisMonth:      return 'This month';
    case kTimeRangeLastMonth:      return 'Last month';
    case kTimeRangeMonthToDate:    return 'Month to date';
    case kTimeRangeLast6Months:    return 'Last 6 months';
    case kTimeRangeLast12Months:   return 'Last 12 months';
    case kTimeRangeThisYear:       return 'This year';
    case kTimeRangeLastYear:       return 'Last year';
    case kTimeRangeYearToDate:     return 'Year to date';
    case kTimeRangeMaximum:        return 'Maximum date range';
    default:                       return c;
  }
}

/// Phrase shown after "vs " on the KPI delta badge.
/// Returns null when there is no meaningful prior period (e.g. Maximum).
String? priorPeriodPhrase(String code) {
  final c = migrateTimeRange(code);
  switch (c) {
    case kTimeRangeAuto:
    case kTimeRangeLast30Days:     return 'prior 30 days';
    case kTimeRangeToday:          return 'yesterday';
    case kTimeRangeYesterday:      return 'day before';
    case kTimeRangeLast7Days:      return 'prior 7 days';
    case kTimeRangeThisWeek:       return 'last week';
    case kTimeRangeLastWeek:       return 'prior week';
    case kTimeRangeThisMonth:      return 'last month';
    case kTimeRangeLastMonth:      return 'prior month';
    case kTimeRangeMonthToDate:    return 'prior month-to-date';
    case kTimeRangeLast6Months:    return 'prior 6 months';
    case kTimeRangeLast12Months:   return 'prior 12 months';
    case kTimeRangeThisYear:       return 'last year';
    case kTimeRangeLastYear:       return 'prior year';
    case kTimeRangeYearToDate:     return 'prior YTD';
    case kTimeRangeMaximum:        return null;
    default:                       return null;
  }
}
