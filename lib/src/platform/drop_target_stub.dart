// Web stub for DropTarget — renders only its `child`, no drag-drop wiring.
// Callbacks are accepted (so call sites compile) but never invoked.
// Web users get the "Browse Files" path via file_picker.

import 'package:cross_file/cross_file.dart';
import 'package:flutter/widgets.dart';

class DropEventDetails {
  final List<XFile> files;
  const DropEventDetails({this.files = const []});
}

class DropDoneDetails {
  final List<XFile> files;
  const DropDoneDetails({this.files = const []});
}

class DropTarget extends StatelessWidget {
  const DropTarget({
    super.key,
    required this.child,
    this.onDragEntered,
    this.onDragExited,
    this.onDragDone,
  });

  final Widget child;
  final void Function(DropEventDetails)? onDragEntered;
  final void Function(DropEventDetails)? onDragExited;
  final void Function(DropDoneDetails)? onDragDone;

  @override
  Widget build(BuildContext context) => child;
}
