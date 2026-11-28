/// Text z PDF účtenky (elektronická účtenka z aplikace obchodu). Čte se
/// přímo v telefonu (PDFium), soubor se nikam neposílá. V prohlížeči
/// není k dispozici.
library;

export 'receipt_pdf_stub.dart' if (dart.library.io) 'receipt_pdf_io.dart';
