// Platform-aware re-export of DropTarget.
//
// - On desktop/mobile: re-exports the real `desktop_drop` API.
// - On web: exports a no-op widget so `flutter build web` succeeds.
//   Web users still get the "Browse Files" button (file_picker works on web).
//
// Usage:
//   import 'package:optics/src/platform/drop_target.dart';
//   ...
//   DropTarget(
//     onDragDone: (d) async { ... },
//     child: ...,
//   )

export 'drop_target_stub.dart'
    if (dart.library.io) 'drop_target_io.dart';
