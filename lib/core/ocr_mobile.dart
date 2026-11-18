import 'dart:io' show File, Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'ocr_common.dart';

/// Rozpoznávání textu Google ML Kit běží přímo v telefonu (Android, iPhone),
/// zdarma a bez odesílání fotky na server.
bool get ocrAvailable => Platform.isAndroid || Platform.isIOS;

/// Text z fotky (latinka včetně české diakritiky), řádky v pořadí čtení.
/// Chyby hlásí jako [OcrException] se srozumitelnou zprávou.
Future<String> readTextFromImage(String path) async {
  await _checkFile(path);
  TextRecognizer? recognizer;
  try {
    recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return [
      for (final block in result.blocks)
        for (final line in block.lines) line.text,
    ].join('\n');
  } on PlatformException catch (error) {
    if (error.code == 'InputImageConverterError') {
      throw const OcrException(
        'Fotku se nepodařilo otevřít. Vyberte ji prosím znovu, případně '
        'jinou fotku (JPG nebo PNG).',
        pickAnother: true,
      );
    }
    throw const OcrException(
      'Čtečka textu v telefonu teď nefunguje. Zkuste to znovu; když to '
      'nepomůže, vložte text receptu ručně (záložka Text).',
    );
  } catch (_) {
    throw const OcrException(
      'Text z fotky se nepodařilo přečíst. Zkuste to znovu nebo vyberte '
      'ostřejší fotku.',
    );
  } finally {
    try {
      await recognizer?.close();
    } catch (_) {
      // zavření nesmí přepsat původní chybu
    }
  }
}

/// Ověří, že fotka existuje, není prázdná a je to obrázek.
Future<void> _checkFile(String path) async {
  if (path.trim().isEmpty) {
    throw const OcrException(
      'Fotografie chybí. Vyberte ji prosím znovu.',
      pickAnother: true,
    );
  }
  final file = File(path);
  try {
    if (!await file.exists() || await file.length() == 0) {
      throw const OcrException(
        'Fotografie už není k dispozici. Vyberte ji prosím znovu.',
        pickAnother: true,
      );
    }
    final head = await file.openRead(0, 16).expand((b) => b).toList();
    if (imageFormatOf(head) == null) {
      throw const OcrException(
        'Tento soubor nejde přečíst jako obrázek. Vyberte fotku ve formátu '
        'JPG nebo PNG.',
        pickAnother: true,
      );
    }
  } on OcrException {
    rethrow;
  } catch (_) {
    throw const OcrException(
      'Fotku se nepodařilo otevřít (možná chybí oprávnění). Vyberte ji '
      'prosím znovu.',
      pickAnother: true,
    );
  }
}
