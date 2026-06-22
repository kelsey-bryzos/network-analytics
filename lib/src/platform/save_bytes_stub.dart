import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<bool> saveBytesToUserFile({
  required Uint8List bytes,
  required String fileName,
  required String extension,
  required String dialogTitle,
}) async {
  final result = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
    bytes: bytes,
  );
  return result != null;
}
