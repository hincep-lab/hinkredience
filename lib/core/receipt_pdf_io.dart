import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

bool get pdfReceiptsAvailable => Platform.isAndroid;

var _initialized = false;

/// Celý text PDF (všechny strany za sebou, řádky oddělené novým řádkem).
Future<String> readPdfText(String path) async {
  if (!_initialized) {
    await pdfrxFlutterInitialize();
    _initialized = true;
  }
  final document = await PdfDocument.openFile(path);
  try {
    final buffer = StringBuffer();
    for (final page in document.pages) {
      final text = await page.loadStructuredText(ensureLoaded: true);
      buffer.writeln(text.fullText);
    }
    return buffer.toString();
  } finally {
    await document.dispose();
  }
}
