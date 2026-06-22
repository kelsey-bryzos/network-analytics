import 'dart:html' as html;
import 'dart:typed_data';

Future<bool> saveBytesToUserFile({
  required Uint8List bytes,
  required String fileName,
  required String extension,
  required String dialogTitle,
}) async {
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}
