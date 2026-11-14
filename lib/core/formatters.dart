/// Formátování čísel, množství a časů po česku.
library;

/// Množství suroviny: nejvýše 2 desetinná místa, desetinná čárka, bez zbytečných nul.
/// `2.0 → "2"`, `0.5 → "0,5"`, `1.333 → "1,33"`.
String formatQuantity(double value) {
  final rounded = (value * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) {
    return rounded.round().toString();
  }
  var text = rounded.toStringAsFixed(2);
  if (text.endsWith('0')) text = text.substring(0, text.length - 1);
  return text.replaceAll('.', ',');
}

/// Převede text z formuláře na číslo. Přijímá desetinnou čárku i tečku
/// a jednoduché zlomky ("1/2"). Prázdný nebo neplatný vstup vrací `null`.
double? parseQuantity(String input) {
  final text = input.trim().replaceAll(',', '.').replaceAll(' ', '');
  if (text.isEmpty) return null;
  if (text.contains('/')) {
    final parts = text.split('/');
    if (parts.length != 2) return null;
    final numerator = double.tryParse(parts[0]);
    final denominator = double.tryParse(parts[1]);
    if (numerator == null || denominator == null || denominator == 0) {
      return null;
    }
    return numerator / denominator;
  }
  final value = double.tryParse(text);
  if (value == null || value.isNaN || value.isInfinite) return null;
  return value;
}

/// Přepočet množství na jiný počet porcí.
double? scaleQuantity(
  double? quantity, {
  required double fromServings,
  required double toServings,
}) {
  if (quantity == null) return null;
  if (fromServings <= 0) return quantity;
  return quantity * toServings / fromServings;
}

/// Délka v minutách: `45 → "45 min"`, `60 → "1 h"`, `90 → "1 h 30 min"`.
String formatMinutes(int minutes) {
  if (minutes <= 0) return '0 min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return '$rest min';
  if (rest == 0) return '$hours h';
  return '$hours h $rest min';
}

/// Datum ve tvaru `14. 11. 2026`.
String formatDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day}. ${local.month}. ${local.year}';
}

/// Odstraní diakritiku a převede na malá písmena – pro vyhledávání,
/// aby „svickova“ našla „Svíčková“.
String foldForSearch(String input) {
  const from = 'áäčďéěíĺľňóôöŕřšťúůüýž';
  const to = 'aacdeeillnooorrstuuuyz';
  final lower = input.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final index = from.indexOf(char);
    buffer.write(index >= 0 ? to[index] : char);
  }
  return buffer.toString();
}
