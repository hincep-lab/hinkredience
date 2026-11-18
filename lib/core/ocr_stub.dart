import 'ocr_common.dart';

/// Bez prohlížeče i bez Androidu/iOS (např. počítač) čtení není.
bool get ocrAvailable => false;

Future<String> readTextFromImage(String path) =>
    throw const OcrException('Čtení textu z fotky tady není k dispozici.');
