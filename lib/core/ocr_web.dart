import 'dart:js_interop';

import 'ocr_common.dart';

// Most na window.hinkOcr z web/ocr.js (Tesseract v prohlížeči).

@JS('hinkOcr')
external _HinkOcr? get _ocr;

extension type _HinkOcr._(JSObject _) implements JSObject {
  external JSPromise<JSString> read(String url);
}

/// Ve webové verzi čte text Tesseract přímo v prohlížeči.
bool get ocrAvailable => _ocr != null;

/// Text z fotky. [path] je adresa obrázku z výběru fotky (blob:…).
Future<String> readTextFromImage(String path) async {
  final ocr = _ocr;
  if (ocr == null) {
    throw const OcrException(
      'Čtení textu z fotky se v prohlížeči nenačetlo. Obnovte stránku '
      'a zkuste to znovu.',
    );
  }
  if (path.isEmpty) {
    throw const OcrException(
      'Fotografii se nepodařilo otevřít. Vyberte ji prosím znovu.',
      pickAnother: true,
    );
  }
  try {
    return (await ocr.read(path).toDart).toDart;
  } catch (error) {
    final text = error.toString();
    if (text.contains('HINK_BAD_IMAGE')) {
      throw const OcrException(
        'Tento soubor nejde přečíst jako obrázek. Vyberte fotku ve formátu '
        'JPG nebo PNG.',
        pickAnother: true,
      );
    }
    if (text.contains('HINK_LOAD')) {
      throw const OcrException(
        'Nepodařilo se stáhnout čtečku textu. Zkontrolujte připojení '
        'k internetu a zkuste to znovu.',
      );
    }
    throw const OcrException(
      'Text z fotky se nepodařilo přečíst. Zkuste to znovu nebo vyberte '
      'ostřejší fotku.',
    );
  }
}
