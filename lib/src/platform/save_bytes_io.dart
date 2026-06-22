import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<bool> saveBytesToUserFile({
  required Uint8List bytes,
  required String fileName,
  required String extension,
  required String dialogTitle,
}) async {
  var savePath = await FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: [extension],
  );
  if (savePath == null) return false;
  if (!savePath.toLowerCase().endsWith('.$extension')) {
    savePath = '$savePath.$extension';
  }
  await File(savePath).writeAsBytes(bytes, flush: true);
  return true;
}
