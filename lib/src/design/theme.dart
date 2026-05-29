import 'package:flutter/material.dart';

/// Optics design system tokens.
///
/// Visual language is defined in /objective/OBJECTIVE.md §0.2:
/// dark near-black canvas, electric cyan/blue primary, rounded cards
/// with thin borders + soft glow, UPPERCASE section labels with
/// letter-spacing, smooth thin-stroke charts.
class OpticsColors {
  // Canvas / surfaces — ERP-aligned 3-tier ladder for sharper depth.
  // Tier 1 (canvas / page + header): #0F0F14
  // Tier 2 (panels, inputs):         #191A20
  // Tier 3 (sidebar, elevated):      #222329
  static const Color canvas = Color(0xFF0F0F14);
  static const Color surface = Color(0xFF191A20);
  static const Color surfaceElevated = Color(0xFF222329);
  // Borders shifted to ERP-style white-alpha so edges read crisper against
  // the darker tiers. Solid fallbacks computed for opaque-only callers.
  static const Color border = Color(0x1AFFFFFF);        // ~10% white
  static const Color borderBright = Color(0x33FFFFFF);  // ~20% white (header)

  // Text
  static const Color textPrimary = Color(0xFFE6E8F0);
  static const Color textSecondary = Color(0xFF9CA3B5);
  static const Color textMuted = Color(0xFF5C627A);

  // Brand accents
  static const Color accentCyan = Color(0xFF3DB8FF);
  static const Color accentViolet = Color(0xFF9B7BFF);
  static const Color accentGreen = Color(0xFF4CD495);
  static const Color accentOrange = Color(0xFFFFA850);
  static const Color accentRed = Color(0xFFFF6B6B);

  // Status
  static const Color success = accentGreen;
  static const Color warning = accentOrange;
  static const Color danger = accentRed;

  // Chart palette (ordered)
  static const List<Color> chartPalette = [
    accentCyan,
    accentViolet,
    accentGreen,
    accentOrange,
    Color(0xFFFF7AC6),
    Color(0xFF7DD3FC),
    Color(0xFFFACC15),
    Color(0xFF34D399),
  ];
}

class OpticsRadii {
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
}

class OpticsSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class OpticsTextStyles {
  // ---------------------------------------------------------------------------
  // Typography system
  // ---------------------------------------------------------------------------
  // Headings & section labels → Syncopate Bold (always UPPERCASE per brand).
  // Body & secondary text → Inter (Light/Regular/Medium/SemiBold/Bold).
  // ---------------------------------------------------------------------------
  static const String headingFamily = 'Syncopate';
  static const String bodyFamily = 'Inter';

  static const TextStyle headingXl = TextStyle(
    fontFamily: headingFamily,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: OpticsColors.textPrimary,
    height: 1.15,
    letterSpacing: 1.2,
  );
  static const TextStyle headingLg = TextStyle(
    fontFamily: headingFamily,
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: OpticsColors.textPrimary,
    height: 1.2,
    letterSpacing: 1.0,
  );
  static const TextStyle headingMd = TextStyle(
    fontFamily: headingFamily,
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: OpticsColors.textPrimary,
    letterSpacing: 1.2,
  );
  static const TextStyle body = TextStyle(
    fontFamily: bodyFamily,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: OpticsColors.textPrimary,
    height: 1.4,
  );
  static const TextStyle bodySm = TextStyle(
    fontFamily: bodyFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: OpticsColors.textSecondary,
    height: 1.4,
  );
  static const TextStyle bodyLight = TextStyle(
    fontFamily: bodyFamily,
    fontSize: 14,
    fontWeight: FontWeight.w300,
    color: OpticsColors.textSecondary,
    height: 1.4,
  );
  static const TextStyle sectionLabel = TextStyle(
    fontFamily: headingFamily,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    color: OpticsColors.textSecondary,
    letterSpacing: 1.6,
  );
  static const TextStyle kpiNumber = TextStyle(
    fontFamily: bodyFamily,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    color: OpticsColors.textPrimary,
    height: 1.0,
    letterSpacing: -0.5,
  );
}

/// Per-widget theme colors — allows individual widgets (or all widgets via
/// global dashboard settings) to render in light or dark mode.
class WidgetThemeColors {
  final Color cardBg;
  final Color headerBg;
  final Color headerBorder;
  final Color titleText;
  final Color bodyText;
  final Color secondaryText;
  final Color mutedText;
  final Color border;
  final Color tooltipBg;
  final Color gridLine;
  final Color kpiText;

  const WidgetThemeColors._({
    required this.cardBg,
    required this.headerBg,
    required this.headerBorder,
    required this.titleText,
    required this.bodyText,
    required this.secondaryText,
    required this.mutedText,
    required this.border,
    required this.tooltipBg,
    required this.gridLine,
    required this.kpiText,
  });

  static const dark = WidgetThemeColors._(
    cardBg: OpticsColors.surface,
    headerBg: OpticsColors.surfaceElevated,
    headerBorder: OpticsColors.border,
    titleText: OpticsColors.textPrimary,
    bodyText: OpticsColors.textPrimary,
    secondaryText: OpticsColors.textSecondary,
    mutedText: OpticsColors.textMuted,
    border: OpticsColors.border,
    tooltipBg: OpticsColors.surfaceElevated,
    gridLine: OpticsColors.border,
    kpiText: OpticsColors.textPrimary,
  );

  static const light = WidgetThemeColors._(
    cardBg: Color(0xFFF8F9FB),
    headerBg: Color(0xFFC3C4CA),
    headerBorder: Color(0xFFD8DBE3),
    titleText: Color(0xFF1A1C24),
    bodyText: Color(0xFF1A1C24),
    secondaryText: Color(0xFF4A4F60),
    mutedText: Color(0xFF6B7186),
    border: Color(0xFFD8DBE3),
    tooltipBg: Color(0xFFFFFFFF),
    gridLine: Color(0xFFE2E4EA),
    kpiText: Color(0xFF1A1C24),
  );

  /// Light-mode dashboard chrome background — matches the "vs prior"
  /// text gray from dark mode so the canvas is a soft neutral.
  static const Color lightCanvasBg = Color(0xFFEAECF0);

  /// Resolve from a widget's `settings['theme']` value.
  static WidgetThemeColors fromSettings(Map<String, dynamic>? settings) {
    final theme = settings?['theme'] as String?;
    return theme == 'light' ? light : dark;
  }
}

ThemeData buildOpticsTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    // Inter is the global default font; Syncopate is opted-into per style
    // (headings, section labels) via OpticsTextStyles.
    scaffoldBackgroundColor: OpticsColors.canvas,
    canvasColor: OpticsColors.canvas,
    colorScheme: const ColorScheme.dark(
      surface: OpticsColors.surface,
      primary: OpticsColors.accentCyan,
      onPrimary: Colors.black,
      secondary: OpticsColors.accentViolet,
      error: OpticsColors.accentRed,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: OpticsTextStyles.bodyFamily,
      bodyColor: OpticsColors.textPrimary,
      displayColor: OpticsColors.textPrimary,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: OpticsTextStyles.bodyFamily,
    ),
    dividerColor: OpticsColors.border,
    iconTheme: const IconThemeData(color: OpticsColors.textSecondary, size: 18),
    appBarTheme: const AppBarTheme(
      backgroundColor: OpticsColors.canvas,
      foregroundColor: OpticsColors.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: OpticsColors.surface,
      hintStyle: const TextStyle(color: OpticsColors.textMuted, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        borderSide: const BorderSide(color: OpticsColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        borderSide: const BorderSide(color: OpticsColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(OpticsRadii.sm),
        borderSide: const BorderSide(color: OpticsColors.accentCyan, width: 1),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: OpticsColors.accentCyan,
        foregroundColor: Colors.black,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: OpticsColors.textPrimary,
        side: const BorderSide(color: OpticsColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(OpticsRadii.sm),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: OpticsColors.textSecondary),
    ),
    // Banner notifications styled to match the app header:
    // - Canvas background (#0F0F14) — same color as the header.
    // - No stroke/border.
    // - Drop shadow visible above the bar (header has a downward-cast
    //   shadow off its bottom edge; the SnackBar sits at the bottom of
    //   the screen, so Material's elevation shadow above it mirrors that
    //   look on the top edge).
    // - Gray (textSecondary) body text — same gray used by the header
    //   search bar's hint/typed text.
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: OpticsColors.canvas,
      contentTextStyle: TextStyle(
        color: OpticsColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      elevation: 12,
      behavior: SnackBarBehavior.fixed,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide.none,
      ),
    ),
  );
}
