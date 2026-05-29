// Desktop / mobile implementation — re-exports the real DropTarget from
// the `desktop_drop` package. On platforms where `dart:io` is available,
// `lib/src/platform/drop_target.dart` resolves this file.

export 'package:desktop_drop/desktop_drop.dart' show DropTarget;
