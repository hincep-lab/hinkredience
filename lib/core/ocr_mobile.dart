import 'dart:io' show Platform;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Rozpoznávání textu Google ML Kit běží přímo v telefonu (Android, iPhone),
/// zdarma a bez odesílání fotky na server.
bool get ocrAvailable => Platform.isAndroid || Platform.isIOS;

/// Text z fotky (latinka včetně české diakritiky), řádky v pořadí čtení.
Future<String> readTextFromImage(String path) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return [
      for (final block in result.blocks)
        for (final line in block.lines) line.text,
    ].join('\n');
  } finally {
    await recognizer.close();
  }
}
