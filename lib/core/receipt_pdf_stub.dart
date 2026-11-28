/// Prohlížeč: PDF účtenky se nečtou (sdílení je jen v aplikaci).
bool get pdfReceiptsAvailable => false;

Future<String> readPdfText(String path) =>
    Future.error(UnsupportedError('PDF účtenky jsou jen v aplikaci.'));
