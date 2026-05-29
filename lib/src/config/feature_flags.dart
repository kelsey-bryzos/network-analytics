/// Optics feature flags — compile-time toggles for staged rollouts.
///
/// Use `--dart-define=NAME=true|false` to flip a flag at build time.
class OpticsFlags {
  /// ADR-0013: route "+ Build New Report" to the new explicit-join wizard.
  /// When false, the legacy Explore-based drag/auto-join builder is used.
  static const bool customBuilderV2 = bool.fromEnvironment(
    'OPTICS_CUSTOM_BUILDER_V2',
    defaultValue: true,
  );
}
