/// Srozumitelná chyba při čtení textu z fotky (zobrazí se uživateli).
class OcrException implements Exception {
  const OcrException(this.message, {this.pickAnother = false});

  final String message;

  /// Pomůže vybrat jinou fotku (vadný nebo nečitelný soubor).
  final bool pickAnother;

  @override
  String toString() => message;
}

/// Rozpozná formát obrázku podle prvních bajtů. Null = neznámý formát.
String? imageFormatOf(List<int> head) {
  bool starts(List<int> sig, [int offset = 0]) {
    if (head.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (head[offset + i] != sig[i]) return false;
    }
    return true;
  }

  if (starts([0xFF, 0xD8, 0xFF])) return 'jpeg';
  if (starts([0x89, 0x50, 0x4E, 0x47])) return 'png';
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  if (starts([0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (starts([0x42, 0x4D])) return 'bmp';
  // HEIC/HEIF (fotky z iPhonu): „ftyp“ na 4. bajtu.
  if (starts([0x66, 0x74, 0x79, 0x70], 4)) return 'heic';
  return null;
}
