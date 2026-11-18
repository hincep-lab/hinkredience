/// Čtení textu z fotky bez AI: v telefonu Google ML Kit, v prohlížeči
/// Tesseract (obojí běží přímo v zařízení, fotka se nikam neposílá).
library;

export 'ocr_common.dart';
export 'ocr_stub.dart'
    if (dart.library.io) 'ocr_mobile.dart'
    if (dart.library.js_interop) 'ocr_web.dart';
